import Foundation

/// Append-only JSON-lines logs that don't grow forever.
///
/// Both of this app's line logs were written with a plain seek-to-end append
/// and read back with "load the whole file and parse every line". That is fine
/// for a week and wrong for a year: the tab-guard event log is re-read by every
/// browser host every couple of seconds, and the clean history is re-read by
/// the dashboard on each refresh. Neither had an upper bound, so the cost of
/// using the app grew with how long you had used it.
///
/// Rotation triggers on file size — checked cheaply on every append — and
/// trims to whichever of the two caps is tighter, so the trim is rare and the
/// common path stays a single append.
public enum RollingLog {
    /// Trim when the file passes this, keeping `keepLines` most recent lines.
    public struct Limit: Sendable {
        public let maxBytes: Int
        public let keepLines: Int

        public init(maxBytes: Int, keepLines: Int) {
            self.maxBytes = maxBytes
            self.keepLines = keepLines
        }

        /// Tab-guard events: high frequency, only the tail is ever interesting.
        public static let events = Limit(maxBytes: 512 * 1024, keepLines: 2000)
        /// Clean history: one line per clean, but kept for years.
        public static let cleanHistory = Limit(maxBytes: 1024 * 1024, keepLines: 5000)
    }

    /// Appends one line (a newline is added) and trims if the file got big.
    public static func append(_ line: Data, to url: URL, limit: Limit) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var data = line
        if data.last != 0x0A { data.append(0x0A) }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        trimIfNeeded(url, limit: limit)
    }

    /// Rewrites the file with only its most recent lines, if it outgrew the
    /// limit. Writes atomically: a crash mid-trim must not lose the log.
    public static func trimIfNeeded(_ url: URL, limit: Limit) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        guard let size, size.intValue > limit.maxBytes else { return }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        // Both caps are enforced. Trimming only on the line count meant a log
        // whose lines were bigger than budgeted sat permanently above
        // maxBytes — and this guard fired on *every* append from then on,
        // re-reading the whole file each time without ever shrinking it.
        var kept = lines.suffix(limit.keepLines)
        var bytes = kept.reduce(0) { $0 + $1.utf8.count + 1 }
        while bytes > limit.maxBytes, kept.count > 1 {
            bytes -= (kept.first?.utf8.count ?? 0) + 1
            kept = kept.dropFirst()
        }
        let out = kept.joined(separator: "\n") + "\n"
        try? Data(out.utf8).write(to: url, options: .atomic)
    }

    /// The last `count` lines, without parsing the rest. Reads the whole file
    /// — bounded, because rotation keeps it small — and returns the tail.
    public static func tail(_ url: URL, lines count: Int) -> [Substring] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count))
    }
}
