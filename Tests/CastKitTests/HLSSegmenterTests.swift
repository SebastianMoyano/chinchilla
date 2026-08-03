import Foundation
import AVFoundation
import CoreVideo
import Testing
@testable import CastKit

/// Builds a synthetic video frame so the HLS pipeline can be tested
/// without Screen Recording permission.
private func makeFrame(at time: CMTime, size: (width: Int, height: Int)) -> CMSampleBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height,
                              kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
          let pixelBuffer else { return nil }

    // Fill luma with a moving gradient so frames actually differ.
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let value = UInt8(truncatingIfNeeded: Int(time.value) * 12 + 40)
        memset(base, Int32(value), bytesPerRow * height)
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    var formatDescription: CMFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    ) == noErr, let formatDescription else { return nil }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: time,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
        formatDescription: formatDescription, sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    ) == noErr else { return nil }
    return sampleBuffer
}

@Test(.timeLimit(.minutes(1))) func segmenterProducesPlayableHLS() async throws {
    let store = HLSSegmentStore()
    let segmenter = try HLSSegmenter(
        width: 640, height: 360, bitrate: 2_000_000, includeAudio: false, store: store
    )

    // ~3 seconds at 30 fps → at least two 1-second segments.
    for frame in 0..<90 {
        let time = CMTime(value: CMTimeValue(frame), timescale: 30)
        guard let sample = makeFrame(at: time, size: (640, 360)) else {
            Issue.record("couldn't synthesize frame \(frame)")
            return
        }
        segmenter.append(video: sample)
        // Give the writer a moment every few frames (realtime pipeline).
        if frame % 15 == 0 { try await Task.sleep(for: .milliseconds(40)) }
    }
    await segmenter.finish()

    #expect(store.initSegmentData() != nil, "no initialization segment")
    #expect(store.hasContent)

    let playlist = store.playlist()
    print("PLAYLIST:\n\(playlist)")
    #expect(playlist.contains("#EXT-X-VERSION:7"))
    #expect(playlist.contains("#EXT-X-MAP:URI=\"init.mp4\""))
    #expect(playlist.contains("#EXTINF:"))
    #expect(!playlist.contains("#EXT-X-ENDLIST"), "live playlist must stay open")
    #expect(store.segmentData(index: 0) != nil, "no media segments were produced")

    // The init segment must be a real fMP4 header.
    if let initData = store.initSegmentData() {
        let header = String(decoding: initData.prefix(12), as: UTF8.self)
        #expect(header.contains("ftyp"), "init segment isn't fMP4: \(header)")
        print("INIT bytes=\(initData.count) header=\(header)")
    }
}
