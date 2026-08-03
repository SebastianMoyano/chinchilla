import Foundation

/// In-memory rolling window of CMAF segments plus the live playlist.
/// Nothing ever touches disk: the TV pulls straight from RAM.
public final class HLSSegmentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var initSegment: Data?
    private var segments: [(index: Int, data: Data, duration: Double)] = []
    private var nextIndex = 0
    /// Eight half-second parts ≈ four seconds of rewind. Small windows
    /// keep the player close to the live edge; too small and it stalls.
    private let windowSize = 8

    public init() {}

    public func setInitSegment(_ data: Data) {
        lock.withLock { initSegment = data }
    }

    public func appendSegment(_ data: Data, duration: Double) {
        let listeners: [@Sendable (Data) -> Void] = lock.withLock {
            segments.append((nextIndex, data, duration > 0 ? duration : 1))
            nextIndex += 1
            if segments.count > windowSize { segments.removeFirst() }
            return Array(subscribers.values)
        }
        // Progressive clients get every new fragment pushed to them.
        for listener in listeners { listener(data) }
    }

    private var subscribers: [Int: @Sendable (Data) -> Void] = [:]
    private var nextSubscriberID = 0

    public func subscribe(_ handler: @escaping @Sendable (Data) -> Void) -> Int {
        lock.withLock {
            nextSubscriberID += 1
            subscribers[nextSubscriberID] = handler
            return nextSubscriberID
        }
    }

    public func unsubscribe(_ id: Int) {
        lock.withLock { subscribers.removeValue(forKey: id) }
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
            let longest = segments.map(\.duration).max() ?? 1
            let target = max(1, Int(ceil(longest)))
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
