import Foundation
import AVFoundation
import CoreVideo
import Testing
@testable import CastKit

private func frame(at time: CMTime) -> CMSampleBuffer? {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 640, 360,
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary, &pb)
    guard let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
        memset(base, Int32(UInt8(truncatingIfNeeded: Int(time.value) * 7 + 30)),
               CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * CVPixelBufferGetHeightOfPlane(pb, 0))
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    var fd: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fd)
    guard let fd else { return nil }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                    presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                             formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
    return sb
}

/// Reads the first tfdt box's baseMediaDecodeTime — the segment's start
/// time as the TV's player sees it.
private func baseMediaDecodeTime(in segment: Data) -> UInt64? {
    let marker = Data("tfdt".utf8)
    guard let range = segment.range(of: marker) else { return nil }
    let versionIndex = range.upperBound
    guard versionIndex < segment.endIndex else { return nil }
    let version = segment[versionIndex]
    let valueStart = segment.index(versionIndex, offsetBy: 4)  // version + flags
    if version == 1 {
        guard segment.index(valueStart, offsetBy: 8, limitedBy: segment.endIndex) != nil else { return nil }
        return segment[valueStart..<segment.index(valueStart, offsetBy: 8)]
            .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    } else {
        guard segment.index(valueStart, offsetBy: 4, limitedBy: segment.endIndex) != nil else { return nil }
        return segment[valueStart..<segment.index(valueStart, offsetBy: 4)]
            .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

@Test(.timeLimit(.minutes(1))) func hostTimeStampsProduceUsableSegments() async throws {
    // Simulate ScreenCaptureKit on a Mac with long uptime: PTS starts at
    // ~2.4 million seconds (28 days), not zero.
    let hostStart = CMTime(value: 2_400_000 * 30, timescale: 30)
    let store = HLSSegmentStore()
    let segmenter = try HLSSegmenter(width: 640, height: 360, bitrate: 1_500_000,
                                     includeAudio: false, store: store)
    for i in 0..<90 {
        guard let sample = frame(at: CMTimeAdd(hostStart, CMTime(value: CMTimeValue(i), timescale: 30))) else { return }
        segmenter.append(video: sample)
        if i % 15 == 0 { try await Task.sleep(for: .milliseconds(40)) }
    }
    await segmenter.finish()

    guard let first = store.segmentData(index: 0) else {
        Issue.record("no segments produced with host-time PTS")
        return
    }
    let base = baseMediaDecodeTime(in: first) ?? 0
    print("TIMING first segment baseMediaDecodeTime=\(base)")
    print("TIMING playlist:\n\(store.playlist())")
    // A player starting a live stream expects the first segment near zero.
    #expect(base < 100_000, "segment starts at \(base) — the player sees a huge offset and renders nothing")
}
