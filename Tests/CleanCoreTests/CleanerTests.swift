import Foundation
import Testing
@testable import CleanCore

/// Fixture inside ~/Library/Caches so SafetyPolicy's real rules apply.
private func makeFixture() throws -> (root: String, rule: CleanRule) {
    let root = NSHomeDirectory() + "/Library/Caches/chinchilla-test-\(UUID().uuidString)"
    let fm = FileManager.default
    try fm.createDirectory(atPath: root + "/com.example.app", withIntermediateDirectories: true)
    try Data(count: 8192).write(to: URL(fileURLWithPath: root + "/com.example.app/blob.bin"))
    let rule = CleanRule(
        id: "test.fixture",
        category: .userCaches,
        title: "Test",
        patterns: [root + "/*"],
        safety: .safe,
        contentsOnly: true
    )
    return (root, rule)
}

@Test func dryRunDeletesNothing() async throws {
    let (root, rule) = try makeFixture()
    defer { try? FileManager.default.removeItem(atPath: root) }

    let item = CleanItem(
        ruleID: rule.id, category: .userCaches, path: root + "/com.example.app",
        size: 8192, modified: .distantPast, safety: .safe,
        deleteMode: .unlink, contentsOnly: true
    )
    let outcome = await Cleaner.clean(items: [item], dryRun: true, rules: [rule])

    #expect(outcome.dryRun)
    #expect(outcome.freedBytes == 8192)
    #expect(outcome.failures.isEmpty)
    // The file must still exist.
    #expect(FileManager.default.fileExists(atPath: root + "/com.example.app/blob.bin"))
}

@Test func realCleanRemovesContentsButKeepsContainer() async throws {
    let (root, rule) = try makeFixture()
    defer { try? FileManager.default.removeItem(atPath: root) }

    let item = CleanItem(
        ruleID: rule.id, category: .userCaches, path: root + "/com.example.app",
        size: 8192, modified: .distantPast, safety: .safe,
        deleteMode: .unlink, contentsOnly: true
    )
    let outcome = await Cleaner.clean(items: [item], dryRun: false, rules: [rule])

    #expect(outcome.failures.isEmpty)
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: root + "/com.example.app"))          // container kept
    #expect(!fm.fileExists(atPath: root + "/com.example.app/blob.bin")) // contents gone
}

@Test func cleanerRefusesItemOutsideDeclaredRoots() async throws {
    let (root, rule) = try makeFixture()
    defer { try? FileManager.default.removeItem(atPath: root) }

    // A malicious/buggy item pointing at user documents must be rejected
    // even if a scanner produced it.
    let evil = CleanItem(
        ruleID: rule.id, category: .userCaches,
        path: NSHomeDirectory() + "/Documents/importante.pdf",
        size: 1, modified: .distantPast, safety: .safe,
        deleteMode: .unlink, contentsOnly: false
    )
    let outcome = await Cleaner.clean(items: [evil], dryRun: false, rules: [rule])
    #expect(outcome.deletedPaths.isEmpty)
    #expect(outcome.failures.count == 1)
}
