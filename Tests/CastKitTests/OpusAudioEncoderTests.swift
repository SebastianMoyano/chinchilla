import Foundation
import AVFoundation
import CoreMedia
import DiskScanKit
import Testing
@testable import CastKit

/// The audio RTP timeline used to be a bare sample counter — feed it capture
/// with a gap (silence the tap skipped) and every later packet carried a
/// timestamp from a parallel universe, which the receiver dutifully turned
/// into lip-sync error. These pin the counter to the capture clock.

/// Silent 48 kHz stereo float PCM at an exact capture time.
private func audioBuffer(at seconds: Double, frames: Int) -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
    )
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format
    ) == noErr, let format else { return nil }

    let dataSize = frames * 8
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: dataSize,
        blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
        dataLength: dataSize, flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block
    ) == noErr, let block else { return nil }
    CMBlockBufferFillDataBytes(
        with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataSize
    )

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000),
        decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreate(
        allocator: nil, dataBuffer: block, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
        sampleCount: frames, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &sample
    ) == noErr else { return nil }
    return sample
}

@Test func aCaptureGapMovesTheRtpTimelineWithIt() throws {
    let encoder = OpusAudioEncoder()
    let collected = Locked<[OpusAudioEncoder.Packet]>([])
    encoder.onPacket = { packet in collected.withLock { $0.append(packet) } }

    // 200 ms of continuous capture starting at t=100 s…
    for i in 0..<10 {
        let buffer = try #require(audioBuffer(at: 100.0 + Double(i) * 0.02, frames: 960))
        encoder.encode(buffer)
    }
    let before = collected.withLock { $0 }
    try #require(!before.isEmpty)

    // …then two seconds of silence the tap never delivered, then more audio.
    for i in 0..<10 {
        let buffer = try #require(audioBuffer(at: 102.2 + Double(i) * 0.02, frames: 960))
        encoder.encode(buffer)
    }
    let after = collected.withLock { $0 }
    let firstAfterGap = try #require(
        after.dropFirst(before.count).first, "the gap must not stall the encoder"
    )

    // The RTP clock jumped with the capture clock: the packet after the gap
    // sits ~2 s of samples ahead, not one packet-length ahead.
    let jump = firstAfterGap.sampleTime - before[before.count - 1].sampleTime
    #expect(jump > Int64(1.5 * 48_000))

    // And every packet's capture time is its RTP time on the host clock —
    // one straight line, before and after the gap.
    for packet in after {
        let expected = 100.0 + Double(packet.sampleTime) / 48_000
        #expect(abs(packet.captureHostSeconds - expected) < 0.001)
    }
}

@Test func continuousCaptureKeepsAContinuousTimeline() throws {
    let encoder = OpusAudioEncoder()
    let collected = Locked<[OpusAudioEncoder.Packet]>([])
    encoder.onPacket = { packet in collected.withLock { $0.append(packet) } }

    for i in 0..<25 {
        let buffer = try #require(audioBuffer(at: 7.0 + Double(i) * 0.02, frames: 960))
        encoder.encode(buffer)
    }
    let packets = collected.withLock { $0 }
    try #require(packets.count >= 2)
    // No false resyncs: adjacent packets are exactly one packet apart.
    for (previous, next) in zip(packets, packets.dropFirst()) {
        #expect(next.sampleTime - previous.sampleTime == 960)
    }
}
