import AppKit
import CleanCore
import SystemKit

/// Enforced at clean time (not just pre-selection): items whose rule declares
/// a conflicting app or tool that is currently running are dropped, so we
/// never unlink a live browser cache, DerivedData mid-build, or the uv cache
/// under a running `uvx`.
@MainActor
enum RunningAppGuard {
    private static let rulesByID = Dictionary(
        uniqueKeysWithValues: RuleCatalog.rules.map { ($0.id, $0) }
    )

    private static let declaredProcessNames = Set(
        RuleCatalog.rules.flatMap(\.conflictingProcessNames)
    )

    /// IDs of the rules whose items can't go right now. Computed once per
    /// call — rows ask by rule ID, so no render ever enumerates processes.
    static func conflictingRuleIDs() -> Set<String> {
        let bundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let processNames = ProcessNames.running().intersection(declaredProcessNames)
        return Set(
            RuleCatalog.rules
                .filter { $0.conflicts(runningBundleIDs: bundleIDs, runningProcessNames: processNames) }
                .map(\.id)
        )
    }

    static func filterOutConflicts(_ items: [CleanItem]) -> [CleanItem] {
        let blocked = conflictingRuleIDs()
        return items.filter { item in
            rulesByID[item.ruleID] != nil && !blocked.contains(item.ruleID)
        }
    }
}
