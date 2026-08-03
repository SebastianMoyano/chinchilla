import Foundation
import Testing
@testable import CleanCore

@Test func unreadableContentsOnlyDirIsFailureNotFreedBytes() async throws {
    let fm = FileManager.default
    let root = NSHomeDirectory() + "/Library/Caches/chinchilla-test-\(UUID().uuidString)"
    let locked = root + "/com.example.locked"
    try fm.createDirectory(atPath: locked, withIntermediateDirectories: true)
    try Data(count: 4096).write(to: URL(fileURLWithPath: locked + "/blob.bin"))
    // Make the directory unreadable (000).
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
    defer {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
        try? fm.removeItem(atPath: root)
    }

    let rule = CleanRule(
        id: "test.locked", category: .userCaches, title: "t",
        patterns: [root + "/*"], safety: .safe, contentsOnly: true
    )
    let item = CleanItem(
        ruleID: rule.id, category: .userCaches, path: locked,
        size: 4096, modified: .distantPast, safety: .safe,
        deleteMode: .unlink, contentsOnly: true
    )
    let outcome = await Cleaner.clean(items: [item], dryRun: false, rules: [rule])

    // The old bug: freedBytes == 4096 and deletedPaths non-empty with zero
    // actual deletions. Now it must be an explicit failure.
    #expect(outcome.freedBytes == 0)
    #expect(outcome.deletedPaths.isEmpty)
    #expect(outcome.failures.count == 1)
}

@Test func emptyContentsOnlyDirCountsNothing() async throws {
    let fm = FileManager.default
    let root = NSHomeDirectory() + "/Library/Caches/chinchilla-test-\(UUID().uuidString)"
    let empty = root + "/com.example.empty"
    try fm.createDirectory(atPath: empty, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }

    let rule = CleanRule(
        id: "test.empty", category: .userCaches, title: "t",
        patterns: [root + "/*"], safety: .safe, contentsOnly: true
    )
    let item = CleanItem(
        ruleID: rule.id, category: .userCaches, path: empty,
        size: 4096, modified: .distantPast, safety: .safe,
        deleteMode: .unlink, contentsOnly: true
    )
    let outcome = await Cleaner.clean(items: [item], dryRun: false, rules: [rule])
    #expect(outcome.freedBytes == 0)
    #expect(outcome.failures.isEmpty)
}

@Test func auditLogDirectoryIsNeverACleanTarget() {
    let logsRule = RuleCatalog.rules.first { $0.id == "logs.user" }!
    #expect(logsRule.skipNames.contains("Chinchilla"))
}
