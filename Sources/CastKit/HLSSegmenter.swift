import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Encodes captured frames to H.264 and emits CMAF segments, using
/// AVAssetWriter's HLS profile — Apple's own segmenter, so we never
/// hand-write fMP4 boxes and keyframes always align with segment
/// boundaries. VideoToolbox hardware encoding happens inside the writer.
final class HLSSegmenter: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let store: HLSSegmentStore
    private let lock = NSLock()
    private var sessionStarted = false
    private var finished = false

    init(width: Int, height: Int, bitrate: Int, includeAudio: Bool, store: HLSSegmentStore) throws {
        self.store = store
        writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // One sync frame per segment: mandatory for clean HLS parts.
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            audioInput = input
        } else {
            audioInput = nil
        }

        super.init()
        writer.delegate = self
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "CastKit", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Video input rejected"])
        }
        writer.add(videoInput)
        if let audioInput, writer.canAdd(audioInput) {
            writer.add(audioInput)
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "CastKit", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "Writer refused to start"])
        }
    }

    func append(video sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, writer.status == .writing else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else { return }  // realtime: drop, never queue
        videoInput.append(sampleBuffer)
    }

    func append(audio sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, sessionStarted, writer.status == .writing,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    func finish() async {
        // Flip the flag and mark inputs under the lock, then await outside
        // it (NSLock can't be held across a suspension point).
        let shouldFinish: Bool = lock.withLock {
            guard !finished, writer.status == .writing else { return false }
            finished = true
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            return true
        }
        guard shouldFinish else { return }
        await writer.finishWriting()
    }

    // MARK: AVAssetWriterDelegate

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        switch segmentType {
        case .initialization:
            store.setInitSegment(segmentData)
        case .separable:
            let duration = segmentReport?.trackReports.first?.duration.seconds ?? 1
            store.appendSegment(segmentData, duration: duration)
        @unknown default:
            break
        }
    }
}
