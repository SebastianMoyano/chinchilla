import Foundation
import Darwin

public enum ArtifactKind: String, Sendable, CaseIterable {
    case nodeModules = "node_modules"
    case cargoTarget = "target"
    case venv = ".venv"
    case pods = "Pods"

    /// File that must exist next to the artifact for it to count as a project.
    var marker: String {
        switch self {
        case .nodeModules: "package.json"
        case .cargoTarget: "Cargo.toml"
        case .venv: "pyproject.toml"
        case .pods: "Podfile"
        }
    }
}

public struct ProjectArtifact: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let projectPath: String
    public let kind: String
    public let size: Int64
    public let lastTouched: Date

    public var projectName: String { (projectPath as NSString).lastPathComponent }
}

/// Finds reinstallable build artifacts (node_modules, target, .venv, Pods)
/// in project folders, with a "project last touched" age estimate.
public enum ArtifactFinder {
    public static func defaultRoots() -> [String] {
        let home = NSHomeDirectory()
        let candidates = ["Desktop", "Developer", "Projects", "projects", "dev", "code", "src", "work"]
            .map { home + "/" + $0 }
        var isDir: ObjCBool = false
        return candidates.filter {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
    }

    public static func find(roots: [String] = defaultRoots(), maxDepth: Int = 8) async -> [ProjectArtifact] {
        // Walk serially (directory enumeration is cheap), size in parallel.
        var candidates: [(path: String, project: String, kind: String)] = []
        for root in roots {
            walk(dir: root, depth: 0, maxDepth: maxDepth, into: &candidates)
        }
        var results: [ProjectArtifact] = []
        await withTaskGroup(of: ProjectArtifact?.self) { group in
            for candidate in candidates {
                group.addTask {
                    let size = await Blocking.run { DiskSize.allocated(at: candidate.path) }
                    guard size > 0 else { return nil }
                    return ProjectArtifact(
                        path: candidate.path,
                        projectPath: candidate.project,
                        kind: candidate.kind,
                        size: size,
                        lastTouched: projectAge(projectDir: candidate.project)
                    )
                }
            }
            for await artifact in group {
                if let artifact { results.append(artifact) }
            }
        }
        results.sort { $0.size > $1.size }
        return results
    }

    private static let skipNames: Set<String> = [
        ".git", "Library", ".Trash", "Applications",
    ]

    private static func walk(
        dir: String, depth: Int, maxDepth: Int,
        into results: inout [(path: String, project: String, kind: String)]
    ) {
        guard depth <= maxDepth else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }

        for entry in entries {
            if skipNames.contains(entry) { continue }
            if entry.hasPrefix(".") && entry != ".venv" { continue }
            let path = (dir as NSString).appendingPathComponent(entry)
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }

            if let kind = ArtifactKind.allCases.first(where: { $0.rawValue == entry }) {
                let marker = (dir as NSString).appendingPathComponent(kind.marker)
                guard fm.fileExists(atPath: marker) else { continue }
                results.append((path: path, project: dir, kind: kind.rawValue))
                continue  // never descend into the artifact itself
            }
            walk(dir: path, depth: depth + 1, maxDepth: maxDepth, into: &results)
        }
    }

    /// Newest mtime among cheap proxies for "the human touched this project".
    private static func projectAge(projectDir: String) -> Date {
        var newest = Date.distantPast
        let probes = [
            projectDir,
            projectDir + "/package.json", projectDir + "/Cargo.toml",
            projectDir + "/pyproject.toml", projectDir + "/Podfile",
            projectDir + "/src", projectDir + "/.git/HEAD",
        ]
        for probe in probes {
            var st = stat()
            if lstat(probe, &st) == 0 {
                let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                newest = max(newest, mtime)
            }
        }
        return newest
    }
}
