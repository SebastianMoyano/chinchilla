import AppKit
import CleanCore

/// Enforced at clean time (not just pre-selection): items whose rule declares
/// a conflicting app that is currently running are dropped, so we never
/// unlink a live browser cache or DerivedData mid-build.
@MainActor
enum RunningAppGuard {
    private static let rulesByID = Dictionary(
        uniqueKeysWithValues: RuleCatalog.rules.map { ($0.id, $0) }
    )

    static func runningConflictBundleIDs() -> Set<String> {
        let declared = Set(RuleCatalog.rules.flatMap(\.conflictingBundleIDs))
        return Set(
            NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier)
                .filter { declared.contains($0) }
        )
    }

    static func filterOutConflicts(_ items: [CleanItem]) -> [CleanItem] {
        let running = runningConflictBundleIDs()
        guard !running.isEmpty else { return items }
        return items.filter { item in
            guard let rule = rulesByID[item.ruleID] else { return false }
            return !rule.conflictingBundleIDs.contains { running.contains($0) }
        }
    }
}
