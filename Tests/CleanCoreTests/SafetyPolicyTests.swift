import Foundation
import Testing
@testable import CleanCore

private let home = NSHomeDirectory()
private let cachesRoot = home + "/Library/Caches"

@Test func rejectsSystemPaths() {
    #expect(throws: PolicyViolation.self) {
        try SafetyPolicy.validate(path: "/System/Library/Foo", declaredRoots: ["/System"])
    }
    #expect(throws: PolicyViolation.self) {
        try SafetyPolicy.validate(path: "/usr/lib/dyld", declaredRoots: ["/usr/lib"])
    }
}

@Test func rejectsPrivateVarEvenViaVarAlias() {
    // /var symlinks to /private/var — both spellings must be blocked.
    #expect(throws: PolicyViolation.self) {
        try SafetyPolicy.validate(path: "/private/var/db/powerlog/x", declaredRoots: ["/private/var/db"])
    }
    #expect(throws: PolicyViolation.self) {
        try SafetyPolicy.validate(path: "/var/db/powerlog/x", declaredRoots: ["/var/db"])
    }
    #expect(throws: PolicyViolation.self) {
        try SafetyPolicy.validate(path: "/var/folders/ab/cd/T/x", declaredRoots: ["/var/folders"])
    }
}

@Test func rejectsUserDataLocations() {
    for path in [
        home + "/Documents/tesis.pdf",
        home + "/Desktop/foto.png",
        home + "/Library/Mobile Documents/com~apple~CloudDocs/x",
        home + "/Library/Keychains/login.keychain-db",
        home + "/Library/Safari/Bookmarks.plist",
    ] {
        #expect(throws: PolicyViolation.self) {
            try SafetyPolicy.validate(path: path, declaredRoots: [home])
        }
    }
}

@Test func rejectsProtectedSyncStateBySubstring() {
    #expect(throws: PolicyViolation.self) {
        try SafetyPolicy.validate(path: cachesRoot + "/CloudKit/db", declaredRoots: [cachesRoot])
    }
    #expect(throws: PolicyViolation.self) {
        try SafetyPolicy.validate(path: cachesRoot + "/com.apple.akd/tokens", declaredRoots: [cachesRoot])
    }
}

@Test func rejectsPathOutsideDeclaredRoots() {
    #expect(throws: PolicyViolation.self) {
        try SafetyPolicy.validate(
            path: home + "/Library/Application Support/Important",
            declaredRoots: [cachesRoot]
        )
    }
}

@Test func rejectsShallowPaths() {
    #expect(throws: PolicyViolation.self) {
        try SafetyPolicy.validate(path: "/Users/admin", declaredRoots: ["/Users"])
    }
}

@Test func acceptsLegitimateCachePath() throws {
    try SafetyPolicy.validate(
        path: cachesRoot + "/com.spotify.client/Data",
        declaredRoots: [cachesRoot]
    )
    try SafetyPolicy.validate(
        path: home + "/Library/Developer/Xcode/DerivedData/MyApp-abc",
        declaredRoots: [home + "/Library/Developer/Xcode/DerivedData"]
    )
}

@Test func catalogRulesDeclareValidRoots() {
    for rule in RuleCatalog.rules {
        for root in rule.declaredRoots {
            #expect(root.hasPrefix("/"), "rule \(rule.id) has non-absolute root \(root)")
            #expect(root.split(separator: "/").count >= 2, "rule \(rule.id) root too shallow: \(root)")
        }
    }
}

@Test func globExpansionMatchesComponents() throws {
    let fm = FileManager.default
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("chinchilla-glob-\(UUID().uuidString)")
    try fm.createDirectory(at: base.appendingPathComponent("a/Cache"), withIntermediateDirectories: true)
    try fm.createDirectory(at: base.appendingPathComponent("b/Cache"), withIntermediateDirectories: true)
    try fm.createDirectory(at: base.appendingPathComponent("b/Other"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    let matches = CleanScanner.expand(pattern: base.path + "/*/Cache")
    #expect(matches.count == 2)
    #expect(matches.allSatisfy { $0.hasSuffix("/Cache") })
}
