import Foundation

/// One line of `~/Library/Logs/Chinchilla/clean-history.jsonl`, as written by
/// CleanCore's audit log. Kept structurally identical to the writer's record —
/// if the two ever drift, the reader skips the lines it can't understand
/// rather than pretending the history is empty.
public struct CleanHistoryEntry: Codable, Sendable {
    public let date: Date
    public let freedBytes: Int64
    public let deleted: [String]
    public let failures: [String]

    public init(date: Date, freedBytes: Int64, deleted: [String], failures: [String]) {
        self.date = date
        self.freedBytes = freedBytes
        self.deleted = deleted
        self.failures = failures
    }
}

/// Reads the audit log the app has always written but nobody could read.
/// Every entry point is synchronous and pure so callers can push it onto a
/// blocking queue; nothing here touches the cooperative pool.
public enum CleanHistory {
    public static var logURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Chinchilla/clean-history.jsonl")
    }

    /// Newest first, at most `limit` entries. A missing log is an empty
    /// history, not an error: a Mac that was never cleaned is a normal Mac.
    public static func load(from url: URL = logURL, limit: Int = 20) -> [CleanHistoryEntry] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return Array(parse(text).reversed().prefix(max(0, limit)))
    }

    /// File order (oldest first). Unparseable lines are dropped — a JSONL file
    /// can end mid-write if the app was killed while appending, and one torn
    /// tail must not cost the reader the other 200 runs.
    public static func parse(_ text: String) -> [CleanHistoryEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return try? decoder.decode(CleanHistoryEntry.self, from: Data(trimmed.utf8))
        }
    }

    public static func json(_ entries: [CleanHistoryEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries),
              let text = String(data: data, encoding: .utf8)
        else { return "[]" }
        return text
    }

    /// Sortable, locale-independent timestamp: this output gets grepped and
    /// piped across a fleet, so it must not change shape with the language.
    public static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    public static func line(_ entry: CleanHistoryEntry) -> String {
        // A dry run or a fully-blocked run freed nothing; "0 bytes" says that
        // plainly, where the formatter's default "Zero KB" reads like a bug.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        let freed = formatter.string(fromByteCount: entry.freedBytes)
        let size = freed.padding(toLength: max(10, freed.count), withPad: " ", startingAt: 0)
        let count = entry.deleted.count
        var line = "\(timestamp(entry.date))  \(size)  \(count) item\(count == 1 ? "" : "s")"
        if !entry.failures.isEmpty { line += "  \(entry.failures.count) failed" }
        return line
    }
}
