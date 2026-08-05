import Foundation
import AppKit
import DiskScanKit

/// One file or folder left behind by an app that is no longer installed.
public struct OrphanFile: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let kind: LeftoverKind
    public let size: Int64
    public let modified: Date

    public init(path: String, kind: LeftoverKind, size: Int64, modified: Date) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
    }
}

/// Every leftover that belongs to the same missing app, as one row.
public struct Orphan: Sendable, Identifiable, Hashable {
    public var id: String { bundleID }
    /// Reverse-DNS id the leftovers were grouped by (e.g. `com.acme.Widget`).
    public let bundleID: String
    /// Last component, which is what the app was probably called.
    public var displayName: String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.isEmpty ? bundleID : last
    }
    public let files: [OrphanFile]
    public var size: Int64 { files.reduce(0) { $0 + $1.size } }
    /// Newest mtime across the group — how long ago anything touched it.
    public var lastTouched: Date { files.map(\.modified).max() ?? .distantPast }
    /// Orphans are never `safe`: they are user data until the user says
    /// otherwise, so the weekly automatic clean must never sweep them.
    public var safety: Safety { .caution }

    public init(bundleID: String, files: [OrphanFile]) {
        self.bundleID = bundleID
        self.files = files
    }
}

/// What is installed on this Mac, as far as we can tell. Anything a leftover
/// can be attributed to counts — a missing signal must never be read as
/// "the app is gone".
public struct InstalledIndex: Sendable {
    /// Every id we found, lowercased: .app bundle ids plus weaker signals
    /// (installer receipts, launchd jobs, privileged helpers) that prove a
    /// vendor is present even without a visible app.
    public var identifiers: Set<String> = []
    /// `com.vendor` for every id above.
    public var publishers: Set<String> = []
    /// Normalized names of installed apps ("visual studio code").
    public var appNames: Set<String> = []
    /// Last component of every installed app's bundle id. Vendors rename
    /// their bundle id and leave the old prefs behind (`com.x.thing` →
    /// `net.y.thing`); the app is still installed, so that is not an orphan.
    public var appIDLeaves: Set<String> = []
    /// `known + "."` for every identifier, precomputed. `covers` runs once
    /// per directory entry across nine roots; building these strings inside
    /// its loop was two allocations per identifier per call — millions of
    /// throwaway strings per scan.
    private var identifierPrefixes: [String] = []

    public init(
        identifiers: Set<String> = [], publishers: Set<String> = [],
        appNames: Set<String> = [], appIDLeaves: Set<String> = []
    ) {
        self.identifiers = identifiers
        self.publishers = publishers
        self.appNames = appNames
        self.appIDLeaves = appIDLeaves
        self.identifierPrefixes = identifiers.map { $0 + "." }
    }

    /// Recomputes `publishers` (and the prefix cache `covers` matches
    /// against) from `identifiers` — call after filling the set.
    mutating func indexPublishers() {
        for id in identifiers {
            if let publisher = OrphanFinder.publisher(of: id) { publishers.insert(publisher) }
        }
        identifierPrefixes = identifiers.map { $0 + "." }
    }

    /// True when `bundleID` can be attributed to something still on the Mac.
    public func covers(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        if identifiers.contains(id) { return true }
        // `prefix.hasPrefix(idDot)` matches the old `known.hasPrefix(idDot)`:
        // they only differ when `known == id`, which the exact-match check
        // above has already answered.
        let idDot = id + "."
        for prefix in identifierPrefixes where id.hasPrefix(prefix) || prefix.hasPrefix(idDot) {
            return true
        }
        if let publisher = OrphanFinder.publisher(of: id), publishers.contains(publisher) {
            return true
        }
        guard let last = id.split(separator: ".").last.map(String.init) else { return false }
        // `com.acme.MyApp` while "MyApp.app" is installed but unreadable.
        if appNames.contains(last) { return true }
        // Same app, older bundle id. Only trust a distinctive leaf.
        if last.count >= 5, !OrphanFinder.genericLeaves.contains(last),
           appIDLeaves.contains(last) {
            return true
        }
        return false
    }
}

public enum OrphanFinder {
    public struct Options: Sendable {
        /// Leftovers touched more recently than this are never offered:
        /// something is still writing to them, so something still uses them.
        public var minAgeDays: Double = 30
        /// Ask LaunchServices where a bundle id lives. Catches apps outside
        /// the four scanned folders (Desktop, Setapp, nested helpers).
        public var useLaunchServices = true
        /// Groups smaller than this are dropped. Zero by default: a stale
        /// 4 KB plist frees nothing, but it is still the user's call, and the
        /// list is sorted by size so it sinks to the bottom.
        public var minGroupBytes: Int64 = 0

        public init() {}
    }

    // MARK: - Where apps live / where leftovers live

    static let applicationRoots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// One level deep in each of these; the value is how we label a hit.
    static var leftoverRoots: [(path: String, kind: LeftoverKind)] {
        let home = NSHomeDirectory()
        return [
            (home + "/Library/Application Support", .support),
            (home + "/Library/Preferences", .preferences),
            (home + "/Library/Containers", .containers),
            (home + "/Library/Group Containers", .groupContainers),
            (home + "/Library/Caches", .caches),
            (home + "/Library/Saved Application State", .savedState),
            (home + "/Library/HTTPStorages", .webStorage),
            (home + "/Library/WebKit", .webStorage),
            (home + "/Library/Logs", .logs),
        ]
    }

    /// Roots handed to SafetyPolicy when trashing — nothing outside these.
    public static var declaredRoots: [String] { leftoverRoots.map(\.path) }

    // MARK: - Allowlist

    /// Publishers that ship no `.app` and would otherwise look abandoned on
    /// every Mac. Matched on the `com.vendor` prefix. Everything Apple is
    /// blocked separately and unconditionally.
    static let allowedPublishers: Set<String> = [
        "com.apple",            // belt and braces; also blocked by prefix
        "org.webkit",           // Playwright / WebKit builds from npm
        "org.python", "org.pypa", "org.swift", "org.llvm",
        "org.freedesktop", "org.macports", "org.xquartz", "org.gnu",
        "org.nodejs", "com.electron",   // dev runtimes, no bundle of their own
        "com.docker",           // docker CLI without Docker.app
        "com.google.keystone", "com.google.googleupdater",  // Google's updater
        "com.microsoft.autoupdate",
        "com.oracle.java", "net.java", "com.sun.java",
        "org.mozilla.crashreporter",
        "org.cups",             // printing subsystem, ships with macOS
        "com.android",          // Android SDK / emulator, no .app of its own
    ]

    /// Bundle-id leaves too generic to prove two ids are the same app.
    static let genericLeaves: Set<String> = [
        "agent", "helper", "client", "desktop", "browser", "editor", "player",
        "viewer", "updater", "installer", "launcher", "service", "manager",
        "framework", "extension", "plugin", "daemon", "shared", "common",
    ]

    /// Exact ids never offered, whatever the state of the Mac.
    static let allowedIDs: Set<String> = [
        "com.sebastian.chinchilla",
        "com.googlecode.iterm2.shellintegration",
    ]

    // MARK: - Public API

    /// Full scan: index what is installed, walk the leftover folders, size
    /// what survives. Every blocking step runs off the cooperative pool.
    /// `isCancelled` reaches the sizing fts loops inside `Blocking.run`,
    /// where `Task.isCancelled` never fires — pass a `CancelFlag` probe so an
    /// abandoned scan actually stops walking.
    public static func scan(
        options: Options = Options(),
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async -> [Orphan] {
        let index = await Blocking.run { buildIndex() }
        var candidates = await Blocking.run { collect(index: index, options: options) }
        // Second pass: the bytes usually sit in a plainly named folder
        // ("Plex", "obs-studio"), not in the bundle-id one. Only ids the
        // first pass already proved dead may claim such a folder.
        let confirmed = candidates.map(\.bundleID)
        candidates += await Blocking.run {
            namedFolders(forDeadIDs: confirmed, index: index, options: options)
        }

        var sized: [String: [OrphanFile]] = [:]
        await withTaskGroup(of: (String, OrphanFile)?.self) { group in
            for candidate in candidates {
                group.addTask {
                    if isCancelled?() == true { return nil }
                    let size = await Blocking.run {
                        DiskSize.allocated(at: candidate.path, isCancelled: isCancelled)
                    }
                    guard size > 0 else { return nil }
                    return (
                        candidate.bundleID,
                        OrphanFile(
                            path: candidate.path, kind: candidate.kind,
                            size: size, modified: candidate.modified
                        )
                    )
                }
            }
            for await result in group {
                guard let (bundleID, file) = result else { continue }
                sized[bundleID, default: []].append(file)
            }
        }

        return mergeSubIdentifiers(sized)
            .map { Orphan(bundleID: $0.key, files: $0.value.sorted { $0.size > $1.size }) }
            .filter { $0.size >= options.minGroupBytes }
            .sorted { $0.size > $1.size }
    }

    /// Folds helper/XPC ids into the app id they extend, so one dead app is
    /// one row instead of four (`…obs-studio.helper` → `…obs-studio`).
    static func mergeSubIdentifiers(
        _ groups: [String: [OrphanFile]]
    ) -> [String: [OrphanFile]] {
        let ids = groups.keys.sorted { $0.count < $1.count }
        var owner: [String: String] = [:]
        for id in ids {
            let parent = ids.first { $0.count < id.count && id.hasPrefix($0 + ".") }
            owner[id] = parent.map { owner[$0] ?? $0 } ?? id
        }
        var merged: [String: [OrphanFile]] = [:]
        for (id, files) in groups {
            merged[owner[id] ?? id, default: []].append(contentsOf: files)
        }
        return merged
    }

    // MARK: - Candidate collection

    struct Candidate: Sendable {
        let bundleID: String
        let path: String
        let kind: LeftoverKind
        let modified: Date
    }

    static func collect(
        roots: [(path: String, kind: LeftoverKind)] = leftoverRoots,
        index: InstalledIndex,
        options: Options
    ) -> [Candidate] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-options.minAgeDays * 86_400)
        var candidates: [Candidate] = []
        // LaunchServices is a per-id question; the same id shows up in eight
        // folders, so ask once.
        var installedElsewhere: [String: Bool] = [:]

        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for entry in entries {
                guard let bundleID = bundleIDStem(fromEntryName: entry) else { continue }
                guard !isProtected(bundleID) else { continue }
                guard !index.covers(bundleID) else { continue }

                let path = root.path + "/" + entry
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                guard modified < cutoff else { continue }

                if options.useLaunchServices {
                    let known = installedElsewhere[bundleID] ?? {
                        let found = isKnownToLaunchServices(bundleID)
                        installedElsewhere[bundleID] = found
                        return found
                    }()
                    if known { continue }
                }
                candidates.append(
                    Candidate(bundleID: bundleID, path: path, kind: root.kind, modified: modified)
                )
            }
        }
        return candidates
    }

    /// Folder names shared by several vendors or owned by the OS — never
    /// attributed to a single dead app.
    static let ambiguousFolderNames: Set<String> = [
        "google", "microsoft", "apple", "adobe", "mozilla", "java", "electron",
        "chromium", "cef", "code", "node", "npm", "pip", "homebrew", "xcode",
        "developer", "crashreporter", "crash reporter", "icloud", "clouddocs",
        "mobilesync", "logs", "caches", "cache", "data", "temp", "sync",
        "firefox", "safari", "chrome", "python", "go", "rust", "kotlin",
    ]

    /// Plainly named leftovers (`~/Library/Application Support/Plex`) for ids
    /// the first pass already flagged. Matched on the id's own words, so a
    /// folder is only ever claimed by a vendor with nothing left installed.
    static var namedFolderRoots: [(path: String, kind: LeftoverKind)] {
        let home = NSHomeDirectory()
        return [
            (home + "/Library/Application Support", .support),
            (home + "/Library/Caches", .caches),
            (home + "/Library/Logs", .logs),
        ]
    }

    static func namedFolders(
        forDeadIDs deadIDs: [String],
        roots: [(path: String, kind: LeftoverKind)] = namedFolderRoots,
        index: InstalledIndex,
        options: Options
    ) -> [Candidate] {
        // "com.etwok.netspotwifi" → ["netspotwifi", "etwok"].
        var wordsByID: [String: [String]] = [:]
        for id in Set(deadIDs) {
            let components = id.split(separator: ".").map(String.init)
            guard components.count >= 3 else { continue }
            var words: [String] = []
            if let leaf = components.last?.lowercased(),
               leaf.count >= 4, !genericLeaves.contains(leaf) {
                words.append(leaf)
            }
            let vendor = components[1].lowercased()
            if vendor.count >= 4 { words.append(vendor) }
            wordsByID[id] = words.filter { !ambiguousFolderNames.contains($0) }
        }

        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-options.minAgeDays * 86_400)
        var found: [Candidate] = []
        for (root, kind) in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let name = entry.lowercased()
                guard name.count >= 4,
                      !ambiguousFolderNames.contains(name),
                      !name.hasPrefix("."),
                      bundleIDStem(fromEntryName: entry) == nil,   // ids are pass one
                      !index.appNames.contains(name),
                      !index.publishers.contains(where: { $0.hasSuffix("." + name) })
                else { continue }

                // The folder must be this app's: same word, or the folder name
                // is how the id's word starts ("NetSpot" ⊂ "netspotwifi").
                guard let owner = wordsByID.first(where: { _, words in
                    words.contains { word in
                        word == name
                            || (word.hasPrefix(name) && name.count >= 6)   // NetSpot ⊂ netspotwifi
                            || startsWithWord(name, word)                  // arduino-ide
                    }
                })?.key else { continue }

                let path = root + "/" + entry
                var st = stat()
                guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
                let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                guard modified < cutoff else { continue }
                found.append(Candidate(bundleID: owner, path: path, kind: kind, modified: modified))
            }
        }
        return found
    }

    /// True for "arduino-ide" against "arduino": the folder starts with the
    /// whole word, followed by a separator — never mid-word.
    static func startsWithWord(_ name: String, _ word: String) -> Bool {
        guard word.count >= 5, name.count > word.count, name.hasPrefix(word) else { return false }
        let next = name[name.index(name.startIndex, offsetBy: word.count)]
        return next == "-" || next == "_" || next == " " || next == "."
    }

    /// LaunchServices knows about apps we never look at — on the Desktop, in
    /// a disk image, nested inside another bundle. A hit is proof of life.
    /// Parent ids count too: `…blender.thumbnailer` belongs to `…blender`.
    static func isKnownToLaunchServices(_ bundleID: String) -> Bool {
        var components = bundleID.split(separator: ".").map(String.init)
        while components.count >= 3 {
            if NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: components.joined(separator: ".")
            ) != nil {
                return true
            }
            components.removeLast()
        }
        return false
    }

    // MARK: - Index

    static func buildIndex() -> InstalledIndex {
        var index = InstalledIndex()
        let fm = FileManager.default

        for root in applicationRoots {
            for bundle in appBundles(in: root) {
                let name = ((bundle as NSString).lastPathComponent as NSString)
                    .deletingPathExtension
                index.appNames.insert(normalize(appName: name))
                guard let id = Bundle(path: bundle)?.bundleIdentifier?.lowercased() else { continue }
                index.identifiers.insert(id)
                if let leaf = id.split(separator: ".").last {
                    index.appIDLeaves.insert(String(leaf))
                }
            }
        }

        // Weaker signals: a vendor with an installer receipt, a launchd job or
        // a privileged helper is present even without a visible .app.
        let otherPaths = [
            "/var/db/receipts",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/PrivilegedHelperTools",
            "/Library/Application Support",
            "/Library/Containers",
            NSHomeDirectory() + "/Library/LaunchAgents",
        ]
        for path in otherPaths {
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else { continue }
            for entry in entries {
                // Receipts and launchd plists carry the raw id in the name;
                // ".disabled" suffixes still prove the job was installed.
                var stem = entry
                if stem.hasSuffix(".disabled") { stem = (stem as NSString).deletingPathExtension }
                stem = strippingKnownSuffixes(stem).lowercased()
                guard isBundleIDShaped(stem) else { continue }
                index.identifiers.insert(stem)
            }
        }

        index.indexPublishers()
        return index
    }

    /// `.app` bundles directly in `root` or one vendor folder below it.
    static func appBundles(in root: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var bundles: [String] = []
        for entry in entries {
            let path = root + "/" + entry
            if entry.hasSuffix(".app") {
                bundles.append(path)
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  let inner = try? fm.contentsOfDirectory(atPath: path) else { continue }
            for sub in inner where sub.hasSuffix(".app") {
                bundles.append(path + "/" + sub)
            }
        }
        return bundles
    }

    // MARK: - Name logic (pure — this is what the tests pin down)

    static let knownSuffixes = [
        "savedstate", "plist", "binarycookies", "lockfile", "sfl2", "sfl3", "csstore",
        "bom", "xml",
    ]

    /// Strips the trailing `.plist` / `.savedState` / … that turns a bundle id
    /// into a file name. One pass: `com.a.b.plist` → `com.a.b`.
    static func strippingKnownSuffixes(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        guard knownSuffixes.contains(ext) else { return name }
        return (name as NSString).deletingPathExtension
    }

    /// The reverse-DNS id a leftover entry belongs to, or nil when the name
    /// says nothing (`go`, `Firefox`, `default.store-shm`). Group container
    /// wrappers (`group.`, `TEAMID.`) are peeled off first.
    public static func bundleIDStem(fromEntryName name: String) -> String? {
        var stem = strippingKnownSuffixes(name)
        if stem.hasPrefix("group.") {
            stem = String(stem.dropFirst("group.".count))
        } else if let first = stem.split(separator: ".").first, isTeamID(String(first)) {
            stem = String(stem.dropFirst(first.count + 1))
        }
        guard isBundleIDShaped(stem) else { return nil }
        return stem
    }

    /// Apple's 10-character team identifier prefix on group containers.
    static func isTeamID(_ component: String) -> Bool {
        component.count == 10
            && component.allSatisfy { $0.isUppercase && $0.isASCII || $0.isNumber }
    }

    /// Conservative reverse-DNS test: three or more components, a short
    /// lowercase TLD-ish head, and nothing but id characters. Two-component
    /// names (`default.store`, `io.sentry`) are deliberately rejected —
    /// they are as often a file name as a bundle id.
    public static func isBundleIDShaped(_ name: String) -> Bool {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3 else { return false }
        guard let head = components.first,
              head.count >= 2, head.count <= 5,
              head.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter })
        else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }
        }
    }

    /// `com.acme` for `com.acme.Widget.helper`.
    public static func publisher(of bundleID: String) -> String? {
        let components = bundleID.lowercased().split(separator: ".")
        guard components.count >= 2 else { return nil }
        return components[0] + "." + components[1]
    }

    /// Apple, plus the vendors that legitimately leave reverse-DNS folders
    /// behind without ever shipping an app.
    public static func isProtected(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        if id == "com.apple" || id.hasPrefix("com.apple.") { return true }
        if allowedIDs.contains(id) { return true }
        for allowed in allowedPublishers where id == allowed || id.hasPrefix(allowed + ".") {
            return true
        }
        return false
    }

    static func normalize(appName: String) -> String {
        appName.lowercased()
            .replacingOccurrences(of: ".localized", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
