import Foundation
import AVFoundation
import CoreMedia

/// Encodes captured system audio to Opus — the codec every Cast receiver is
/// required to implement, and the one Chrome's own mirroring uses.
///
/// macOS ships an Opus encoder (it shows up in `kAudioFormatProperty_EncodeFormatIDs`),
/// so this is a plain `AVAudioConverter` rather than a bundled library.
public final class OpusAudioEncoder: @unchecked Sendable {
    public struct Packet: Sendable {
        public let data: Data
        /// Cumulative position in 48 kHz samples — the RTP timestamp.
        public let sampleTime: Int64
        /// The host-clock moment this packet's audio was captured — the same
        /// clock video frames carry in their presentation time. The sender
        /// reports pair RTP time with this, which is what lets the receiver
        /// lip-sync the two streams for real.
        public let captureHostSeconds: Double
    }

    public var onPacket: (@Sendable (Packet) -> Void)?

    private let bitrate: Int
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var queue: [AVAudioPCMBuffer] = []
    private var samplesEncoded: Int64 = 0
    private var framesPerPacket = 960          // 20 ms at 48 kHz
    /// Where sample 0 sits on the host clock. The sample counter alone is a
    /// lie waiting to happen: it assumes the capture never skips, and every
    /// skipped stretch of silence would shift the audio timeline off the
    /// video's — permanently. The capture clock is the truth; the counter is
    /// resynced against it whenever they disagree by more than jitter.
    private var firstPTSSeconds: Double?
    private var inputSamples: Int64 = 0

    public init(bitrate: Int = 128_000) {
        self.bitrate = bitrate
    }

    public func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        lock.lock()
        if converter == nil { setUpConverter(inputFormat: pcm.format) }
        guard let converter, let outputFormat else { lock.unlock(); return }
        if firstPTSSeconds == nil, pts.isFinite { firstPTSSeconds = pts }
        if let first = firstPTSSeconds, pts.isFinite {
            // The capture is configured at 48 kHz, so input frames and RTP
            // ticks share a rate and can be compared directly.
            let expected = Int64(((pts - first) * 48_000).rounded())
            let drift = expected - inputSamples
            if abs(drift) > 4_800 {    // >100 ms: a capture gap, not jitter
                inputSamples += drift
                samplesEncoded += drift
                queue.removeAll()
                converter.reset()
            }
        }
        inputSamples += Int64(pcm.frameLength)
        queue.append(pcm)
        // Don't let a stalled encoder grow without bound.
        if queue.count > 100 { queue.removeFirst(queue.count - 100) }

        var packets: [Packet] = []
        while true {
            let compressed = AVAudioCompressedBuffer(
                format: outputFormat, packetCapacity: 1,
                maximumPacketSize: converter.maximumOutputPacketSize
            )
            var ranOut = false
            var error: NSError?
            let status = converter.convert(to: compressed, error: &error) { _, outStatus in
                guard !self.queue.isEmpty else {
                    outStatus.pointee = .noDataNow
                    ranOut = true
                    return nil
                }
                outStatus.pointee = .haveData
                return self.queue.removeFirst()
            }
            guard status == .haveData, compressed.packetCount > 0 else {
                if status == .error || !ranOut { break }
                break
            }
            let byteCount = Int(compressed.byteLength)
            let data = Data(bytes: compressed.data, count: byteCount)
            packets.append(Packet(
                data: data, sampleTime: samplesEncoded,
                captureHostSeconds: (firstPTSSeconds ?? 0)
                    + Double(samplesEncoded) / 48_000
            ))
            samplesEncoded += Int64(framesPerPacket)
            if ranOut { break }
        }
        let handler = onPacket
        lock.unlock()

        for packet in packets { handler?(packet) }
    }

    public func reset() {
        lock.lock()
        queue.removeAll()
        samplesEncoded = 0
        inputSamples = 0
        firstPTSSeconds = nil
        converter?.reset()
        lock.unlock()
    }

    /// Caller must hold the lock.
    private func setUpConverter(inputFormat: AVAudioFormat) {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket),
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        guard let output = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { return }
        converter.bitRate = bitrate
        if output.streamDescription.pointee.mFramesPerPacket > 0 {
            framesPerPacket = Int(output.streamDescription.pointee.mFramesPerPacket)
        }
        self.converter = converter
        self.outputFormat = output
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }
        var description = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &description) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
              ) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
