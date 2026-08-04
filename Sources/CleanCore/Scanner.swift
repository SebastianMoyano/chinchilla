import Foundation
import Darwin
import DiskScanKit

public enum CleanScanner {
    /// Scans all rules and returns cleanable items with sizes.
    /// Never deletes anything — scanning is always a dry run.
    public static func scan(
        rules: [CleanRule] = RuleCatalog.rules,
        hasFullDiskAccess: Bool
    ) async -> ScanReport {
        let usable = rules.filter { hasFullDiskAccess || !$0.requiresFullDiskAccess }
        var items: [CleanItem] = []
        await withTaskGroup(of: [CleanItem].self) { group in
            for rule in usable {
                group.addTask { await scanRule(rule) }
            }
            for await ruleItems in group {
                items.append(contentsOf: ruleItems)
            }
        }
        // Refused at delete time anyway; dropping them here means the list
        // never offers something it will then refuse.
        items.removeAll { UserExclusions.isExcluded($0.path) }
        items.sort { $0.size > $1.size }
        // Rules overlap — a glob over ~/Library/Caches and a rule naming one
        // folder inside it both find that folder. Two items with the same path
        // means the same bytes counted twice, the same file deleted twice, and
        // a SwiftUI list holding two rows under one identity, which sends its
        // view graph into a spin that pins a core and stops responding.
        // Sorted by size first, so the survivor is the one that measured most.
        var seen = Set<String>()
        items.removeAll { !seen.insert($0.path).inserted }
        return ScanReport(items: items)
    }

    private static func scanRule(_ rule: CleanRule) async -> [CleanItem] {
        // Phase 1 (cheap): match paths and apply filters.
        struct Candidate: Sendable {
            let path: String
            let modified: Date
        }
        var candidates: [Candidate] = []
        let now = Date()
        for pattern in rule.patterns {
            for path in expand(pattern: pattern) {
                let name = (path as NSString).lastPathComponent
                if rule.skipNames.contains(name) { continue }
                if case .skipUnlessAllowlisted(let allowlist) = rule.applePolicy,
                   name.hasPrefix("com.apple."), !allowlist.contains(name) {
                    continue
                }
                if !rule.extensions.isEmpty {
                    let ext = (name as NSString).pathExtension.lowercased()
                    guard rule.extensions.contains(ext) else { continue }
                }

                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let isDirectory = st.st_mode & S_IFMT == S_IFDIR
                let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))

                // In-use guard applies to plain files; cache directories churn
                // constantly, so their age says nothing (per-file failures are
                // handled attempt-and-skip at delete time).
                if !isDirectory, rule.minAgeHours > 0,
                   now.timeIntervalSince(modified) < rule.minAgeHours * 3600 {
                    continue
                }
                candidates.append(Candidate(path: path, modified: modified))
            }
        }

        // Phase 2 (expensive): size all matches in parallel.
        var items: [CleanItem] = []
        await withTaskGroup(of: CleanItem?.self) { group in
            for candidate in candidates {
                group.addTask {
                    let size = await Blocking.run { DiskSize.allocated(at: candidate.path) }
                    guard size > 0 else { return nil }
                    return CleanItem(
                        ruleID: rule.id,
                        category: rule.category,
                        path: candidate.path,
                        size: size,
                        modified: candidate.modified,
                        safety: rule.safety,
                        deleteMode: rule.deleteMode,
                        contentsOnly: rule.contentsOnly
                    )
                }
            }
            for await item in group {
                if let item { items.append(item) }
            }
        }
        return items
    }

    /// Expands `~` and per-component `*` globs (fnmatch semantics).
    static func expand(pattern: String) -> [String] {
        let expanded = (pattern as NSString).expandingTildeInPath
        var current = [""]
        for component in (expanded as NSString).pathComponents {
            if component == "/" {
                current = ["/"]
                continue
            }
            if component.contains("*") {
                var next: [String] = []
                for base in current {
                    let entries = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                    for entry in entries where fnmatch(component, entry, 0) == 0 {
                        next.append((base as NSString).appendingPathComponent(entry))
                    }
                }
                current = next
            } else {
                current = current.map { ($0 as NSString).appendingPathComponent(component) }
            }
        }
        return current.filter { FileManager.default.fileExists(atPath: $0) }
    }
}
