import Foundation
import Testing
@testable import CleanCore

/// `UserExclusions` redirects a process-global file path, so these must not
/// interleave with each other or with anything else that calls `validate`.
@Suite(.serialized)
struct UserExclusionsSuite {
    private let home = NSHomeDirectory()

    /// Runs `body` with the exclusions store pointed at a scratch file
    /// containing `contents` (nil = the file doesn't exist at all).
    private func withStore(_ contents: String?, _ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("chinchilla-excl-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("exclusions.txt")
        if let contents { try contents.write(to: file, atomically: true, encoding: .utf8) }
        UserExclusions.useFile(file)
        defer {
            UserExclusions.useFile(nil)
            try? fm.removeItem(at: dir)
        }
        try body(file)
    }

    /// A real directory under ~/Library/Caches — the only place a clean rule
    /// would legitimately reach, so validate() gets past every other check.
    private func makeCacheDir(_ name: String) throws -> String {
        let path = home + "/Library/Caches/" + name
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true
        )
        return path
    }

    @Test func excludedPathAndChildrenAreRefused() throws {
        let mine = try makeCacheDir("chinchilla-test-mine-\(UUID().uuidString)")
        let theirs = try makeCacheDir("chinchilla-test-theirs-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(atPath: mine)
            try? FileManager.default.removeItem(atPath: theirs)
        }
        let roots = [home + "/Library/Caches"]

        try withStore(mine + "\n") { _ in
            #expect(throws: PolicyViolation.self) {
                try SafetyPolicy.validate(path: mine, declaredRoots: roots)
            }
            #expect(throws: PolicyViolation.self) {
                try SafetyPolicy.validate(path: mine + "/deep/file.bin", declaredRoots: roots)
            }
            // A sibling with no relation to the exclusion is still cleanable.
            try SafetyPolicy.validate(path: theirs, declaredRoots: roots)
            try SafetyPolicy.validate(path: theirs + "/file.bin", declaredRoots: roots)
        }
    }

    @Test func siblingWithSharedPrefixIsNotExcluded() throws {
        // "…/Data" must not protect "…/DataBackup" — prefix matching has to be
        // path-component aware.
        let base = try makeCacheDir("chinchilla-test-prefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let protected = base + "/Data"
        let other = base + "/DataBackup"
        try FileManager.default.createDirectory(atPath: protected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)

        try withStore(protected + "\n") { _ in
            #expect(throws: PolicyViolation.self) {
                try SafetyPolicy.validate(path: protected, declaredRoots: [base])
            }
            try SafetyPolicy.validate(path: other, declaredRoots: [base])
        }
    }

    @Test func symlinkedRouteIntoExcludedDirIsRefused() throws {
        let base = try makeCacheDir("chinchilla-test-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let real = base + "/real"
        try FileManager.default.createDirectory(atPath: real + "/inner", withIntermediateDirectories: true)
        let link = base + "/alias"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        try withStore(real + "\n") { _ in
            // Reached through the symlink, the file still resolves into the
            // excluded directory.
            #expect(throws: PolicyViolation.self) {
                try SafetyPolicy.validate(path: link + "/inner/file.bin", declaredRoots: [base])
            }
        }
    }

    @Test func expandsTilde() throws {
        let name = "chinchilla-test-tilde-\(UUID().uuidString)"
        let path = try makeCacheDir(name)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try withStore("~/Library/Caches/\(name)\n") { _ in
            #expect(UserExclusions.entries().first?.path == path)
            #expect(throws: PolicyViolation.self) {
                try SafetyPolicy.validate(path: path + "/x", declaredRoots: [home + "/Library/Caches"])
            }
        }
    }

    @Test func ignoresCommentsAndBlankLines() throws {
        let text = """
            # a comment
              # indented comment

            ~/Library/Caches/Alpha
              ~/Library/Caches/Beta

            """
        try withStore(text) { _ in
            let entries = UserExclusions.entries()
            #expect(entries.count == 2)
            #expect(entries.map(\.path) == [
                home + "/Library/Caches/Alpha",
                home + "/Library/Caches/Beta",
            ])
        }
    }

    @Test func missingFileMeansNothingIsExcluded() throws {
        try withStore(nil) { file in
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(UserExclusions.entries().isEmpty)
            try SafetyPolicy.validate(
                path: home + "/Library/Caches/com.example.app/Data",
                declaredRoots: [home + "/Library/Caches"]
            )
        }
    }

    @Test func addAndRemoveRoundTrip() throws {
        try withStore(nil) { file in
            try UserExclusions.add(home + "/Library/Caches/Gamma")
            // Written back with ~ so the file stays readable.
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("~/Library/Caches/Gamma"))

            // Adding the same folder twice must not duplicate the line.
            try UserExclusions.add(home + "/Library/Caches/Gamma")
            #expect(UserExclusions.entries().count == 1)

            let entry = try #require(UserExclusions.entries().first)
            #expect(entry.path == home + "/Library/Caches/Gamma")
            try UserExclusions.remove(entry)
            #expect(UserExclusions.entries().isEmpty)
        }
    }

    @Test func trailingSlashStillMatches() throws {
        let path = try makeCacheDir("chinchilla-test-slash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try withStore(path + "/\n") { _ in
            #expect(throws: PolicyViolation.self) {
                try SafetyPolicy.validate(path: path + "/x", declaredRoots: [home + "/Library/Caches"])
            }
        }
    }

    @Test func editsToTheFileAreNoticed() throws {
        let path = try makeCacheDir("chinchilla-test-reload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try withStore("") { file in
            #expect(UserExclusions.entries().isEmpty)
            try (path + "\n").write(to: file, atomically: true, encoding: .utf8)
            // The cache is time-windowed; the UI calls reload() after an edit.
            UserExclusions.reload()
            #expect(UserExclusions.entries().count == 1)
        }
    }
}
