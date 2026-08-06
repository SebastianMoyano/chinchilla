import Foundation
import Testing
@testable import SystemKit

/// The audit log rotates, so it cannot answer "how much space, ever" — that
/// is this counter's whole job. These pin the three things it must get
/// right: it accumulates, it inherits what the log already knew, and it
/// keeps the true total after the log forgets.

private func scratch(_ name: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chinchilla-totals-\(UUID().uuidString)-\(name)")
}

private func historyLine(date: Date, freed: Int64) -> Data {
    let stamp = ISO8601DateFormatter().string(from: date)
    return Data("""
    {"date":"\(stamp)","freedBytes":\(freed),"deleted":[],"failures":[]}
    """.utf8)
}

@Test func recordsAccumulateAcrossCleans() throws {
    let url = scratch("totals.json")
    let history = scratch("history.jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    let start = Date(timeIntervalSince1970: 1_700_000_000)
    CleanTotalsStore.record(freedBytes: 1_000, at: start, url: url, historyURL: history)
    CleanTotalsStore.record(freedBytes: 2_500, at: start.addingTimeInterval(60), url: url, historyURL: history)
    let totals = try #require(CleanTotalsStore.load(from: url, historyURL: history))

    #expect(totals.freedBytes == 3_500)
    #expect(totals.cleanCount == 2)
    #expect(abs(totals.since.timeIntervalSince(start)) < 1)
}

@Test func firstLoadInheritsTheExistingHistory() throws {
    let url = scratch("totals.json")
    let history = scratch("history.jsonl")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: history)
    }

    // A Mac that has been cleaning for months before this counter existed.
    let first = Date(timeIntervalSince1970: 1_690_000_000)
    var log = Data()
    for i in 0..<3 {
        log.append(historyLine(date: first.addingTimeInterval(Double(i) * 86_400), freed: 1_000_000))
        log.append(0x0A)
    }
    try log.write(to: history)

    let totals = try #require(CleanTotalsStore.load(from: url, historyURL: history))
    #expect(totals.freedBytes == 3_000_000)
    #expect(totals.cleanCount == 3)
    #expect(abs(totals.since.timeIntervalSince(first)) < 1)
}

@Test func theTotalSurvivesTheLogForgetting() throws {
    let url = scratch("totals.json")
    let history = scratch("history.jsonl")
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: history)
    }

    let start = Date(timeIntervalSince1970: 1_700_000_000)
    CleanTotalsStore.record(freedBytes: 5_000_000, at: start, url: url, historyURL: history)
    // The rolling log trims its old lines; the counter must not care.
    try? FileManager.default.removeItem(at: history)
    CleanTotalsStore.record(freedBytes: 1_000_000, at: start.addingTimeInterval(60), url: url, historyURL: history)

    let totals = try #require(CleanTotalsStore.load(from: url, historyURL: history))
    #expect(totals.freedBytes == 6_000_000)
    #expect(totals.cleanCount == 2)

    // And a Mac with no counter file and no log has no story to tell.
    #expect(CleanTotalsStore.load(from: scratch("missing.json"), historyURL: scratch("missing.jsonl")) == nil)
}
