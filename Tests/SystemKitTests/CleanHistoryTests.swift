import Foundation
import Testing
@testable import SystemKit

private func temporaryLog(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clean-history-\(UUID().uuidString).jsonl")
    try Data(contents.utf8).write(to: url)
    return url
}

private let twoRuns = """
{"date":"2026-01-01T10:00:00Z","freedBytes":1048576,"deleted":["/a","/b"],"failures":[]}
{"date":"2026-02-02T11:30:00Z","freedBytes":2097152,"deleted":["/c"],"failures":["/d: busy"]}
"""

@Test func parsesEntriesInFileOrder() {
    let entries = CleanHistory.parse(twoRuns)
    #expect(entries.count == 2)
    #expect(entries[0].freedBytes == 1_048_576)
    #expect(entries[0].deleted == ["/a", "/b"])
    #expect(entries[1].failures == ["/d: busy"])
}

@Test func loadReturnsNewestFirstAndHonorsLimit() throws {
    let url = try temporaryLog(twoRuns + "\n")
    defer { try? FileManager.default.removeItem(at: url) }

    let all = CleanHistory.load(from: url, limit: 20)
    #expect(all.count == 2)
    #expect(all[0].freedBytes == 2_097_152, "newest run must come first")

    let one = CleanHistory.load(from: url, limit: 1)
    #expect(one.count == 1)
    #expect(one[0].freedBytes == 2_097_152)
    #expect(CleanHistory.load(from: url, limit: 0).isEmpty)
}

/// A JSONL file can end mid-write if the app was killed while appending; one
/// torn line must not cost the reader the rest of the history.
@Test func skipsCorruptAndBlankLinesWithoutCrashing() throws {
    let text = """
    {"date":"2026-01-01T10:00:00Z","freedBytes":10,"deleted":[],"failures":[]}
    not json at all

    {"date":"2026-01-02T10:00:00Z","freedBytes":2
    {"freedBytes":30,"deleted":[],"failures":[]}
    {"date":"2026-01-03T10:00:00Z","freedBytes":40,"deleted":["/x"],"failures":[]}
    """
    let url = try temporaryLog(text)
    defer { try? FileManager.default.removeItem(at: url) }

    let entries = CleanHistory.load(from: url)
    #expect(entries.count == 2)
    #expect(entries.map(\.freedBytes) == [40, 10])
}

@Test func missingAndEmptyLogsAreEmptyHistories() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("does-not-exist-\(UUID().uuidString).jsonl")
    #expect(CleanHistory.load(from: missing).isEmpty)

    let empty = try temporaryLog("")
    defer { try? FileManager.default.removeItem(at: empty) }
    #expect(CleanHistory.load(from: empty).isEmpty)
    #expect(CleanHistory.json(CleanHistory.load(from: empty)) == "[\n\n]")
}

@Test func jsonRoundTripsThroughTheSameISO8601Shape() throws {
    let entries = CleanHistory.parse(twoRuns)
    let text = CleanHistory.json(entries)
    #expect(text.contains("\"freedBytes\""))
    #expect(text.contains("2026-02-02T11:30:00Z"))

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let reparsed = try decoder.decode([CleanHistoryEntry].self, from: Data(text.utf8))
    #expect(reparsed.count == 2)
    #expect(reparsed[0].date == entries[0].date)
}

@Test func humanLineCarriesDateCountsAndFailures() {
    let entries = CleanHistory.parse(twoRuns)
    let line = CleanHistory.line(entries[1])
    #expect(line.hasPrefix(CleanHistory.timestamp(entries[1].date)))
    #expect(line.contains("1 item"))
    #expect(line.contains("1 failed"))
    #expect(CleanHistory.line(entries[0]).contains("2 items"))
    #expect(!CleanHistory.line(entries[0]).contains("failed"), "clean runs stay quiet")
}

@Test func timestampIsLocaleIndependentAndSortable() {
    let date = Date(timeIntervalSince1970: 1_767_265_200)
    let stamp = CleanHistory.timestamp(date)
    #expect(stamp.count == 16)
    #expect(stamp.wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/) != nil)
}
