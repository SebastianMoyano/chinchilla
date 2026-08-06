import Foundation

/// Lifetime cleaning totals: bytes freed and cleans run since the first one.
///
/// The audit log can't answer "how much, ever" — it rotates, so summing it
/// undercounts as soon as old lines are trimmed. This is a separate running
/// counter, updated on every real clean and seeded once from whatever the
/// log still holds, so existing installs don't restart at zero.
public struct CleanTotals: Codable, Sendable, Equatable {
    public var freedBytes: Int64
    public var cleanCount: Int
    /// When the counting started — the earliest clean this Mac remembers.
    public var since: Date

    public init(freedBytes: Int64, cleanCount: Int, since: Date) {
        self.freedBytes = freedBytes
        self.cleanCount = cleanCount
        self.since = since
    }
}

public enum CleanTotalsStore {
    public static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Chinchilla/clean-totals.json")
    }

    /// The totals so far, or nil when this Mac has never cleaned (and its
    /// history log is empty too). Reading seeds from the log when the file
    /// doesn't exist yet, so the number is right from the first launch of a
    /// build that has it.
    public static func load(
        from url: URL = url, historyURL: URL = CleanHistory.logURL
    ) -> CleanTotals? {
        if let data = try? Data(contentsOf: url),
           let totals = try? decoder.decode(CleanTotals.self, from: data) {
            return totals
        }
        guard let seeded = seed(fromHistoryAt: historyURL) else { return nil }
        write(seeded, to: url)
        return seeded
    }

    /// Adds one clean's result. Called exactly where the audit log is
    /// appended, so the two can't drift apart about what counts as a clean.
    @discardableResult
    public static func record(
        freedBytes: Int64, at date: Date = Date(),
        url: URL = url, historyURL: URL = CleanHistory.logURL
    ) -> CleanTotals {
        var totals = load(from: url, historyURL: historyURL)
            ?? CleanTotals(freedBytes: 0, cleanCount: 0, since: date)
        totals.freedBytes += max(0, freedBytes)
        totals.cleanCount += 1
        write(totals, to: url)
        return totals
    }

    private static func seed(fromHistoryAt historyURL: URL) -> CleanTotals? {
        guard let data = try? Data(contentsOf: historyURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let entries = CleanHistory.parse(text)
        guard let first = entries.first else { return nil }
        return CleanTotals(
            freedBytes: entries.reduce(0) { $0 + max(0, $1.freedBytes) },
            cleanCount: entries.count,
            since: first.date
        )
    }

    private static func write(_ totals: CleanTotals, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? encoder.encode(totals) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
