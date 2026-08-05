import Foundation
import Testing
@testable import SystemKit

/// Both line logs used to grow forever while being re-read in full — the tab
/// guard's every couple of seconds, the clean history on every dashboard
/// refresh. These check the file stays bounded and keeps the *recent* end.

private func scratchURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chinchilla-rolling-\(UUID().uuidString).jsonl")
}

@Test func appendWritesOneLinePerCallAndAddsTheNewline() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let limit = RollingLog.Limit(maxBytes: 1 << 20, keepLines: 100)

    RollingLog.append(Data("first".utf8), to: url, limit: limit)
    RollingLog.append(Data("second\n".utf8), to: url, limit: limit)  // already ends in \n

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text == "first\nsecond\n")
}

@Test func aLogThatOutgrowsItsLimitKeepsTheMostRecentLines() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    // Small enough that a few hundred lines trip it.
    let limit = RollingLog.Limit(maxBytes: 1024, keepLines: 10)

    for i in 0..<500 {
        RollingLog.append(Data("line-\(i)".utf8), to: url, limit: limit)
    }

    let lines = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    // The file refills to the byte cap between trims, so the bound that holds
    // is on size, not on line count — that's the one that matters, because the
    // cost being bounded is the whole point.
    let size = try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
    ).intValue
    #expect(size <= 1024 + 16)
    // Whatever survived is the recent end. 500 lines went in; far fewer remain.
    #expect(lines.last == "line-499")
    #expect(lines.count < 200)
}

@Test func theByteCapHoldsEvenWhenLinesAreBiggerThanBudgeted() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    // keepLines is generous and the lines are fat — the memory history's
    // exact shape. The old trim only fired on line count, so a file like
    // this sat above maxBytes forever while every append re-read all of it.
    let limit = RollingLog.Limit(maxBytes: 1024, keepLines: 5000)

    let fatLine = String(repeating: "x", count: 100)
    for i in 0..<50 {
        RollingLog.append(Data("\(i)-\(fatLine)".utf8), to: url, limit: limit)
    }

    let size = try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
    ).intValue
    // One appended line of headroom: the trim runs after the append.
    #expect(size <= 1024 + 128)
    let lines = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.last?.hasPrefix("49-") == true)
}

@Test func aLogUnderTheLimitIsLeftAlone() throws {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let limit = RollingLog.Limit(maxBytes: 1 << 20, keepLines: 5)

    for i in 0..<50 {
        RollingLog.append(Data("line-\(i)".utf8), to: url, limit: limit)
    }

    let lines = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    // keepLines is the trim target, not a running cap — no trim, no loss.
    #expect(lines.count == 50)
}

@Test func tailReturnsTheLastLinesAndCopesWithAMissingFile() {
    let url = scratchURL()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(RollingLog.tail(url, lines: 1).isEmpty)

    let limit = RollingLog.Limit(maxBytes: 1 << 20, keepLines: 100)
    for i in 0..<5 { RollingLog.append(Data("line-\(i)".utf8), to: url, limit: limit) }

    #expect(RollingLog.tail(url, lines: 1) == ["line-4"])
    #expect(RollingLog.tail(url, lines: 2) == ["line-3", "line-4"])
    // Asking for more than exists returns what exists.
    #expect(RollingLog.tail(url, lines: 99).count == 5)
}

@Test func appendCreatesTheDirectoryItNeeds() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chinchilla-rolling-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("nested/events.jsonl")
    defer { try? FileManager.default.removeItem(at: directory) }

    RollingLog.append(Data("hello".utf8), to: url, limit: .events)

    #expect(FileManager.default.fileExists(atPath: url.path))
}
