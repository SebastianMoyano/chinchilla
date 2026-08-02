import Foundation
import DiskScanKit

public struct InstalledApp: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let bundleID: String?
    public let size: Int64

    public init(path: String, name: String, bundleID: String?, size: Int64) {
        self.path = path
        self.name = name
        self.bundleID = bundleID
        self.size = size
    }
}

public enum LeftoverKind: String, Sendable, CaseIterable {
    case appBundle = "Application"
    case support = "Application Support"
    case preferences = "Preferences"
    case caches = "Caches"
    case containers = "Containers"
    case groupContainers = "Group Containers"
    case savedState = "Saved State"
    case launchAgents = "Launch Agents"
    case webStorage = "Web Storage"
    case logs = "Logs"
}

public struct Leftover: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let kind: LeftoverKind
    public let size: Int64
}

/// Inventory of user-installed apps (never /System/Applications).
public enum AppInventory {
    public static func scan() async -> [InstalledApp] {
        // Enumerate first (cheap), then size every bundle in parallel —
        // serial fts walks over 50+ apps are the difference between
        // "instant" and "spinner" on low-core machines.
        var paths: [String] = []
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
        let fm = FileManager.default
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let path = root + "/" + entry
                if entry.hasSuffix(".app") {
                    paths.append(path)
                } else {
                    // One level of vendor subfolders (e.g. /Applications/Utilities).
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                          let sub = try? fm.contentsOfDirectory(atPath: path) else { continue }
                    for inner in sub where inner.hasSuffix(".app") {
                        paths.append(path + "/" + inner)
                    }
                }
            }
        }
        var apps: [InstalledApp] = []
        await withTaskGroup(of: InstalledApp.self) { group in
            for path in paths {
                group.addTask { makeApp(path: path) }
            }
            for await app in group {
                apps.append(app)
            }
        }
        return apps.sorted { $0.size > $1.size }
    }

    private static func makeApp(path: String) -> InstalledApp {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let bundleID = Bundle(path: path)?.bundleIdentifier
        return InstalledApp(
            path: path,
            name: name,
            bundleID: bundleID,
            size: DiskSize.allocated(at: path)
        )
    }
}

/// Finds an app's on-disk remnants by bundle ID (exact/prefix) and, more
/// conservatively, by exact name. Apple bundle IDs are never offered.
public enum LeftoverFinder {
    public static func find(for app: InstalledApp) -> [Leftover] {
        var results: [Leftover] = []
        let home = NSHomeDirectory()
        let fm = FileManager.default

        func add(_ path: String, _ kind: LeftoverKind) {
            guard fm.fileExists(atPath: path) else { return }
            if let bundleID = app.bundleID, bundleID.hasPrefix("com.apple.") { return }
            let size = DiskSize.allocated(at: path)
            results.append(Leftover(path: path, kind: kind, size: size))
        }

        // Exact-name and bundle-id direct hits.
        var stems: [String] = []
        if let bundleID = app.bundleID { stems.append(bundleID) }
        stems.append(app.name)

        for stem in stems {
            add("\(home)/Library/Application Support/\(stem)", .support)
            add("\(home)/Library/Caches/\(stem)", .caches)
            add("\(home)/Library/Logs/\(stem)", .logs)
        }
        if let bundleID = app.bundleID {
            add("\(home)/Library/Preferences/\(bundleID).plist", .preferences)
            add("\(home)/Library/Containers/\(bundleID)", .containers)
            add("\(home)/Library/Saved Application State/\(bundleID).savedState", .savedState)
            add("\(home)/Library/HTTPStorages/\(bundleID)", .webStorage)
            add("\(home)/Library/WebKit/\(bundleID)", .webStorage)

            // Pattern-matched locations: ByHost prefs, LaunchAgents,
            // Group Containers (TEAMID.bundleID or group.bundleID).
            for match in glob("\(home)/Library/Preferences/ByHost/\(bundleID).*.plist") {
                add(match, .preferences)
            }
            for match in glob("\(home)/Library/LaunchAgents/\(bundleID)*.plist") {
                add(match, .launchAgents)
            }
            if let groups = try? fm.contentsOfDirectory(atPath: "\(home)/Library/Group Containers") {
                for group in groups where group.hasSuffix(bundleID) || group == "group.\(bundleID)" {
                    add("\(home)/Library/Group Containers/\(group)", .groupContainers)
                }
            }
        }

        // Dedupe (name == bundleID collisions).
        var seen = Set<String>()
        return results.filter { seen.insert($0.path).inserted }
            .sorted { $0.size > $1.size }
    }

    private static func glob(_ pattern: String) -> [String] {
        let dir = (pattern as NSString).deletingLastPathComponent
        let filePattern = (pattern as NSString).lastPathComponent
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return entries
            .filter { fnmatch(filePattern, $0, 0) == 0 }
            .map { dir + "/" + $0 }
    }
}
