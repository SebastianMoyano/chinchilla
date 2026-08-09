import Foundation
import AVFoundation
import CoreMedia

/// System audio to AAC-LC in ADTS frames — what MPEG-TS carries. The Cast
/// RTP path speaks Opus; a television's broadcast pipeline speaks AAC.
/// Same shape as `OpusAudioEncoder`, including the capture-clock anchoring
/// that keeps the timeline honest across capture gaps.
public final class AACAudioEncoder: @unchecked Sendable {
    public struct Packet: Sendable {
        /// A complete ADTS frame, header included.
        public let adts: Data
        public let captureHostSeconds: Double
    }

    public var onPacket: (@Sendable (Packet) -> Void)?

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var queue: [AVAudioPCMBuffer] = []
    private var samplesEncoded: Int64 = 0
    private var framesPerPacket = 1024
    private var firstPTSSeconds: Double?
    private var inputSamples: Int64 = 0

    public init() {}

    public func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = OpusAudioEncoder.pcmBuffer(from: sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        lock.lock()
        if converter == nil { setUpConverter(inputFormat: pcm.format) }
        guard let converter, let outputFormat else { lock.unlock(); return }
        if firstPTSSeconds == nil, pts.isFinite { firstPTSSeconds = pts }
        if let first = firstPTSSeconds, pts.isFinite {
            let expected = Int64(((pts - first) * 48_000).rounded())
            let drift = expected - inputSamples
            if abs(drift) > 4_800 {
                inputSamples += drift
                samplesEncoded += drift
                queue.removeAll()
                converter.reset()
            }
        }
        inputSamples += Int64(pcm.frameLength)
        queue.append(pcm)
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
            guard status == .haveData, compressed.packetCount > 0 else { break }
            let raw = Data(bytes: compressed.data, count: Int(compressed.byteLength))
            packets.append(Packet(
                adts: Self.adtsFrame(raw),
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

    /// Caller must hold the lock.
    private func setUpConverter(inputFormat: AVAudioFormat) {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        guard let output = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { return }
        converter.bitRate = 160_000
        if output.streamDescription.pointee.mFramesPerPacket > 0 {
            framesPerPacket = Int(output.streamDescription.pointee.mFramesPerPacket)
        }
        self.converter = converter
        self.outputFormat = output
    }

    /// AAC-LC, 48 kHz, stereo, no CRC — the 7-byte header every TS demuxer
    /// reads before the frame.
    static func adtsFrame(_ aac: Data) -> Data {
        let length = aac.count + 7
        var frame = Data([
            0xFF, 0xF1,
            0x40 | (3 << 2),                     // AAC-LC, 48 kHz index 3
            0x80 | UInt8((length >> 11) & 0x03), // stereo (2 → 0b10 << 6)
            UInt8((length >> 3) & 0xFF),
            UInt8((length & 0x07) << 5) | 0x1F,
            0xFC,
        ])
        frame.append(aac)
        return frame
    }
}
