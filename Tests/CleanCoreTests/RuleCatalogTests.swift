import Foundation
import Testing
@testable import CleanCore

@Test func ruleIDsAreUnique() {
    let ids = RuleCatalog.rules.map(\.id)
    #expect(Set(ids).count == ids.count)
}

@Test func bundleIDConflictsMatchExactlyOrByTrailingStar() {
    let adobe = RuleCatalog.rules.first { $0.id == "apps.adobe.mediacache" }!
    #expect(adobe.conflicts(runningBundleIDs: ["com.adobe.PremierePro.25"], runningProcessNames: []))
    // Creative Cloud's helpers are always running; they must not block it.
    #expect(!adobe.conflicts(runningBundleIDs: ["com.adobe.acc.AdobeCreativeCloud"], runningProcessNames: []))

    let chrome = RuleCatalog.rules.first { $0.id == "browsers.chrome" }!
    #expect(chrome.conflicts(runningBundleIDs: ["com.google.Chrome"], runningProcessNames: []))
    #expect(!chrome.conflicts(runningBundleIDs: ["com.google.Chrome.helper"], runningProcessNames: []))
}

@Test func processNameConflictsBlockToolCaches() {
    let uv = RuleCatalog.rules.first { $0.id == "dev.uv" }!
    #expect(uv.conflicts(runningBundleIDs: [], runningProcessNames: ["uvx"]))
    #expect(!uv.conflicts(runningBundleIDs: [], runningProcessNames: ["python3"]))

    // A simulator booted headless has no app to see — only launchd_sim.
    for id in ["dev.simulator.caches", "dev.simulator.devices", "dev.simulator.runtimes"] {
        let rule = RuleCatalog.rules.first { $0.id == id }!
        #expect(rule.conflicts(runningBundleIDs: [], runningProcessNames: ["launchd_sim"]))
    }
}

@Test func modelsAndLiveTerminalStateAreNotCaches() {
    #expect(RuleCatalog.cachesSkipNames.contains("llama.cpp"))
    #expect(RuleCatalog.cachesSkipNames.contains("kitty"))
    let caches = NSHomeDirectory() + "/Library/Caches"
    #expect(throws: PolicyViolation.self) {
        try SafetyPolicy.validate(path: caches + "/llama.cpp/model.gguf", declaredRoots: [caches])
    }
}

@Test func untouchedFolderIsOnlyOneWhoseFilesKeptTheirCreationTime() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("chinchilla-untouched-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("factura.pdf")
    try Data("x".utf8).write(to: file)

    #expect(CleanScanner.isUntouched(directory: dir.path))

    // Edited an hour after it was saved: the user's work, so it stays.
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: file.path
    )
    #expect(!CleanScanner.isUntouched(directory: dir.path))
}

@Test func untouchedGivesUpOnCrowdedFolders() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("chinchilla-crowded-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for i in 0..<5 {
        try Data().write(to: dir.appendingPathComponent("f\(i)"))
    }
    #expect(!CleanScanner.isUntouched(directory: dir.path, maxEntries: 3))
    #expect(CleanScanner.isUntouched(directory: dir.path, maxEntries: 5))
}

@Test func liveProfilesAndModelsAreProtected() {
    let caches = NSHomeDirectory() + "/Library/Caches"
    #expect(RuleCatalog.cachesSkipNames.contains("ms-playwright-mcp"))
    #expect(throws: PolicyViolation.self) {
        try SafetyPolicy.validate(
            path: caches + "/ms-playwright-mcp/mcp-chrome-1/Default/Cookies",
            declaredRoots: [caches]
        )
    }
    let home = NSHomeDirectory()
    #expect(throws: PolicyViolation.self) {
        try SafetyPolicy.validate(
            path: home + "/.cache/huggingface/hub/model.safetensors", declaredRoots: [home + "/.cache"]
        )
    }
}

@Test func keepsTheCurrentVersionAndOnesStillRunning() async throws {
    let root = NSHomeDirectory() + "/Library/Caches/chinchilla-test-\(UUID().uuidString)"
    let fm = FileManager.default
    try fm.createDirectory(atPath: root + "/versions", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    let old = Date().addingTimeInterval(-3 * 86400)
    for version in ["1.0", "1.1", "1.2"] {
        let path = root + "/versions/" + version
        try Data(count: 4096).write(to: URL(fileURLWithPath: path))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: path)
    }
    try fm.createSymbolicLink(atPath: root + "/current", withDestinationPath: root + "/versions/1.2")
    // Stands in for a session still running on an old version: this test
    // process's own executable, copied path-for-path, isn't possible — so a
    // second rule checks the running-executable guard on the real binary.
    let rule = CleanRule(
        id: "test.versions", category: .developer, title: "Test",
        patterns: [root + "/versions/*"], safety: .safe,
        keepTargetsOf: [root + "/current"]
    )
    let report = await CleanScanner.scan(rules: [rule], hasFullDiskAccess: true)
    #expect(Set(report.items.map { ($0.path as NSString).lastPathComponent }) == ["1.0", "1.1"])

    let me = CommandLine.arguments[0]
    let selfRule = CleanRule(
        id: "test.self", category: .developer, title: "Test",
        patterns: [(me as NSString).deletingLastPathComponent + "/*"], safety: .safe,
        minAgeHours: 0, keepRunningExecutables: true
    )
    let selfReport = await CleanScanner.scan(rules: [selfRule], hasFullDiskAccess: true)
    let running = (me as NSString).resolvingSymlinksInPath
    #expect(!selfReport.items.contains { ($0.path as NSString).resolvingSymlinksInPath == running })
}
