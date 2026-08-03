import Foundation

/// In-memory rolling window of CMAF segments plus the live playlist.
/// Nothing ever touches disk: the TV pulls straight from RAM.
public final class HLSSegmentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var initSegment: Data?
    private var segments: [(index: Int, data: Data, duration: Double)] = []
    private var nextIndex = 0
    /// Six one-second parts ≈ six seconds of rewind buffer, which is all a
    /// live mirror needs (and keeps memory tiny).
    private let windowSize = 6

    public init() {}

    public func setInitSegment(_ data: Data) {
        lock.withLock { initSegment = data }
    }

    public func appendSegment(_ data: Data, duration: Double) {
        lock.withLock {
            segments.append((nextIndex, data, duration > 0 ? duration : 1))
            nextIndex += 1
            if segments.count > windowSize { segments.removeFirst() }
        }
    }

    public func initSegmentData() -> Data? {
        lock.withLock { initSegment }
    }

    public func segmentData(index: Int) -> Data? {
        lock.withLock { segments.first { $0.index == index }?.data }
    }

    public var hasContent: Bool {
        lock.withLock { initSegment != nil && !segments.isEmpty }
    }

    /// Players buffer a few parts before showing anything; handing them a
    /// one-segment playlist is a reliable way to get a black screen.
    public func hasAtLeast(_ count: Int) -> Bool {
        lock.withLock { initSegment != nil && segments.count >= count }
    }

    /// Live playlist (no ENDLIST). VERSION 7 + EXT-X-MAP are required for
    /// fragmented MP4 segments.
    public func playlist() -> String {
        lock.withLock {
            let target = Int(ceil(segments.map(\.duration).max() ?? 1))
            var lines = [
                "#EXTM3U",
                "#EXT-X-VERSION:7",
                "#EXT-X-TARGETDURATION:\(max(1, target))",
                "#EXT-X-MEDIA-SEQUENCE:\(segments.first?.index ?? 0)",
                "#EXT-X-INDEPENDENT-SEGMENTS",
                "#EXT-X-MAP:URI=\"init.mp4\"",
            ]
            for segment in segments {
                lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
                lines.append("seg-\(segment.index).m4s")
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    public func reset() {
        lock.withLock {
            initSegment = nil
            segments.removeAll()
            nextIndex = 0
        }
    }
}
