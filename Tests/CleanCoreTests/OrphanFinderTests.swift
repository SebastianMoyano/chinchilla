import Foundation
import Testing
@testable import CleanCore

// Everything here runs on synthetic input: real leftovers on the machine
// running the tests must never decide whether they pass.

// MARK: - What looks like a bundle id

@Test func acceptsRealBundleIDShapes() {
    for name in [
        "com.acme.Widget", "org.videolan.vlc", "io.github.nolze.tiny-wifi-analyzer",
        "cc.arduino.IDE2", "de.code-and-web.TexturePacker", "com.utmapp.QEMUHelper",
        "net.whatsapp.WhatsApp.ServiceExtension", "pro.betterdisplay.BetterDisplay",
    ] {
        #expect(OrphanFinder.isBundleIDShaped(name), "\(name) should look like a bundle id")
    }
}

@Test func rejectsNamesThatAreNotBundleIDs() {
    for name in [
        "go", "Firefox", "Riot Games", "obs-studio", "google-heartbeat-storage",
        "default.store", "default.store-shm",   // two components: as likely a file name
        "io.sentry",                            // ditto
        "RLT.FB1",                              // uppercase head, two components
        "com..broken", "Chrome Apps.localized", "com.acme.Wid get",
    ] {
        #expect(!OrphanFinder.isBundleIDShaped(name), "\(name) should not look like a bundle id")
    }
}

@Test func stripsFileSuffixesFromEntryNames() {
    #expect(OrphanFinder.bundleIDStem(fromEntryName: "com.acme.Widget.plist") == "com.acme.Widget")
    #expect(OrphanFinder.bundleIDStem(fromEntryName: "com.acme.Widget.savedState") == "com.acme.Widget")
    #expect(OrphanFinder.bundleIDStem(fromEntryName: "com.acme.Widget.binarycookies") == "com.acme.Widget")
    #expect(OrphanFinder.bundleIDStem(fromEntryName: "com.acme.Widget") == "com.acme.Widget")
}

@Test func peelsGroupContainerWrappers() {
    #expect(OrphanFinder.bundleIDStem(fromEntryName: "group.com.acme.Widget") == "com.acme.Widget")
    #expect(OrphanFinder.bundleIDStem(fromEntryName: "WDNLXAD4W8.com.acme.Widget") == "com.acme.Widget")
    // Team id plus a nickname is not a bundle id — nothing to attribute it to.
    #expect(OrphanFinder.bundleIDStem(fromEntryName: "22MMUN2RN5.lv") == nil)
    #expect(OrphanFinder.bundleIDStem(fromEntryName: "group.com.docker") == nil)
}

// MARK: - Never Apple, never the allowlist

@Test func appleIsNeverAnOrphan() {
    for id in ["com.apple.Safari", "com.apple.dt.Xcode", "com.apple.bird", "com.apple"] {
        #expect(OrphanFinder.isProtected(id))
    }
}

@Test func allowlistedPublishersAreNeverOrphans() {
    for id in [
        "org.cups.PrintingPrefs", "com.android.Emulator", "org.webkit.Playwright",
        "com.google.keystone.agent", "com.sebastian.chinchilla", "org.macports.slapd",
    ] {
        #expect(OrphanFinder.isProtected(id), "\(id) must stay protected")
    }
    #expect(!OrphanFinder.isProtected("com.acme.Widget"))
    // A near-miss must not inherit the allowlist.
    #expect(!OrphanFinder.isProtected("com.androidfake.Thing"))
    #expect(!OrphanFinder.isProtected("org.cupsy.Thing"))
}

// MARK: - Attributing an id to something still installed

private func index(
    ids: Set<String> = [], names: Set<String> = [], leaves: Set<String> = []
) -> InstalledIndex {
    var index = InstalledIndex(identifiers: ids, appNames: names, appIDLeaves: leaves)
    index.indexPublishers()
    return index
}

@Test func coversExactAndNestedIdentifiers() {
    let installed = index(ids: ["com.acme.widget"])
    #expect(installed.covers("com.acme.Widget"))              // case-insensitive
    #expect(installed.covers("com.acme.Widget.helper"))       // XPC service
    #expect(installed.covers("com.acme"))                     // parent of an installed id
}

@Test func coversAnythingFromAPublisherThatIsStillHere() {
    // Deleting Chrome must not put every com.google folder up for deletion
    // while Google's other apps are installed.
    let installed = index(ids: ["com.google.chrome"])
    #expect(installed.covers("com.google.Keystone.Agent"))
    #expect(installed.covers("com.google.GECommonSettings"))
    #expect(!installed.covers("com.googol.Thing"))
}

@Test func coversAppsThatRenamedTheirBundleID() {
    // DB Browser ships as net.sourceforge.sqlitebrowser but left
    // com.sqlitebrowser.sqlitebrowser prefs behind. The app is installed.
    let installed = index(ids: ["net.sourceforge.sqlitebrowser"], leaves: ["sqlitebrowser"])
    #expect(installed.covers("com.sqlitebrowser.sqlitebrowser"))
}

@Test func genericLeavesAreTooWeakToAttribute() {
    let installed = index(ids: ["com.acme.desktop"], leaves: ["desktop", "app"])
    #expect(!installed.covers("tv.plex.desktop"))
    #expect(!installed.covers("com.other.app"))
}

@Test func coversByInstalledAppName() {
    let installed = index(names: ["widget"])
    #expect(installed.covers("com.acme.Widget"))
}

@Test func emptyIndexCoversNothing() {
    #expect(!index().covers("com.acme.Widget"))
}

// MARK: - Folders named after the app rather than its bundle id

@Test func matchesFolderNamesOnlyOnWholeWords() {
    #expect(OrphanFinder.startsWithWord("arduino-ide", "arduino"))
    #expect(OrphanFinder.startsWithWord("obs-studio helper", "obs-studio"))
    #expect(!OrphanFinder.startsWithWord("gooey", "goo"))          // word too short
    #expect(!OrphanFinder.startsWithWord("arduinoide", "arduino")) // no separator
    #expect(!OrphanFinder.startsWithWord("arduino", "arduino"))    // equality is not a prefix
}

// MARK: - Grouping

@Test func helperIdentifiersFoldIntoTheirApp() {
    let file = { (path: String) in
        OrphanFile(path: path, kind: .preferences, size: 4096, modified: .distantPast)
    }
    let merged = OrphanFinder.mergeSubIdentifiers([
        "com.acme.Widget": [file("/a")],
        "com.acme.Widget.helper.renderer": [file("/b")],
        "com.acme.Other": [file("/c")],
    ])
    #expect(merged.count == 2)
    #expect(merged["com.acme.Widget"]?.count == 2)
    #expect(merged["com.acme.Other"]?.count == 1)
}

@Test func orphanTotalsAndSafety() {
    let orphan = Orphan(bundleID: "com.acme.Widget", files: [
        OrphanFile(path: "/a", kind: .containers, size: 100, modified: Date(timeIntervalSince1970: 1_000)),
        OrphanFile(path: "/b", kind: .preferences, size: 20, modified: Date(timeIntervalSince1970: 9_000)),
    ])
    #expect(orphan.size == 120)
    #expect(orphan.lastTouched == Date(timeIntervalSince1970: 9_000))
    #expect(orphan.displayName == "Widget")
    // Never `safe`: the weekly automatic clean must not be able to take these.
    #expect(orphan.safety == .caution)
    #expect(orphan.safety > .safe)
}

// MARK: - End to end over a synthetic Library

private struct Sandbox: ~Copyable {
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "orphan-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    /// Creates `<root>/<dir>/<name>` and backdates it.
    @discardableResult
    func make(_ dir: String, _ name: String, daysOld: Double) throws -> String {
        let parent = root + "/" + dir
        let path = parent + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: path
        )
        return path
    }

    func roots(_ pairs: [(String, LeftoverKind)]) -> [(path: String, kind: LeftoverKind)] {
        pairs.map { (root + "/" + $0.0, $0.1) }
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }
}

@Test func collectsOnlyLeftoversOfAppsThatAreGone() throws {
    let sandbox = try Sandbox()
    try sandbox.make("Containers", "com.acme.Widget", daysOld: 200)
    try sandbox.make("Containers", "com.installed.Thing", daysOld: 200)
    try sandbox.make("Containers", "com.apple.Safari", daysOld: 200)
    try sandbox.make("Containers", "com.acme.Fresh", daysOld: 2)          // still in use
    try sandbox.make("Containers", "SomeFolder", daysOld: 200)            // not an id
    try sandbox.make("Preferences", "com.acme.Widget.plist", daysOld: 200)

    var options = OrphanFinder.Options()
    options.useLaunchServices = false   // no machine state in tests
    let found = OrphanFinder.collect(
        roots: sandbox.roots([("Containers", .containers), ("Preferences", .preferences)]),
        index: index(ids: ["com.installed.thing"]),
        options: options
    )
    #expect(Set(found.map(\.bundleID)) == ["com.acme.Widget"])
    #expect(found.count == 2)   // container + plist
    #expect(found.contains { $0.kind == .containers })
    #expect(found.contains { $0.kind == .preferences })
}

@Test func claimsPlainlyNamedFoldersOnlyForConfirmedDeadApps() throws {
    let sandbox = try Sandbox()
    try sandbox.make("Application Support", "Plex", daysOld: 300)
    try sandbox.make("Application Support", "arduino-ide", daysOld: 300)
    try sandbox.make("Application Support", "Google", daysOld: 300)      // ambiguous name
    try sandbox.make("Application Support", "Blender", daysOld: 300)     // nobody dead claims it
    try sandbox.make("Application Support", "Plexish", daysOld: 300)     // not a whole-word match
    try sandbox.make("Application Support", "Zed", daysOld: 300)         // shorter than 4 chars

    var options = OrphanFinder.Options()
    options.useLaunchServices = false
    let found = OrphanFinder.namedFolders(
        forDeadIDs: ["tv.plex.desktop", "cc.arduino.IDE2", "com.google.Dead", "dev.zed.Zed"],
        roots: sandbox.roots([("Application Support", .support)]),
        index: index(),
        options: options
    )
    let names = Set(found.map { ($0.path as NSString).lastPathComponent })
    #expect(names == ["Plex", "arduino-ide"])
    #expect(found.first { ($0.path as NSString).lastPathComponent == "Plex" }?.bundleID == "tv.plex.desktop")
}

@Test func recentlyTouchedFoldersAreLeftAlone() throws {
    let sandbox = try Sandbox()
    try sandbox.make("Application Support", "Plex", daysOld: 3)

    var options = OrphanFinder.Options()
    options.useLaunchServices = false
    let found = OrphanFinder.namedFolders(
        forDeadIDs: ["tv.plex.desktop"],
        roots: sandbox.roots([("Application Support", .support)]),
        index: index(),
        options: options
    )
    #expect(found.isEmpty)
}

@Test func installedAppNamesProtectTheirFolders() throws {
    let sandbox = try Sandbox()
    try sandbox.make("Application Support", "Plex", daysOld: 300)

    var options = OrphanFinder.Options()
    options.useLaunchServices = false
    let found = OrphanFinder.namedFolders(
        forDeadIDs: ["tv.plex.desktop"],
        roots: sandbox.roots([("Application Support", .support)]),
        index: index(names: ["plex"]),
        options: options
    )
    #expect(found.isEmpty)
}
