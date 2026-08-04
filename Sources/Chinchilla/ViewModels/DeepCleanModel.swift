import SwiftUI
import Observation
import AppKit
import CleanCore
import SystemKit

@MainActor
@Observable
final class DeepCleanModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case review
        case cleaning
        case summary
    }

    var phase: Phase = .idle
    var report = ScanReport()
    var selected: Set<String> = []
    /// ON = preview only. The user must flip it to actually delete.
    var dryRun = true
    var outcome: CleanOutcome?
    /// Bundle IDs of running apps that conflict with some items (browsers).
    var runningConflicts: Set<String> = []
    var hasFullDiskAccess = true

    private static let rulesByID = Dictionary(
        uniqueKeysWithValues: RuleCatalog.rules.map { ($0.id, $0) }
    )

    var selectedItems: [CleanItem] {
        report.items.filter { selected.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    var categories: [CleanCategory] {
        CleanCategory.allCases.filter { !report.items(in: $0).isEmpty }
    }

    func itemHasConflict(_ item: CleanItem) -> Bool {
        guard let rule = Self.rulesByID[item.ruleID] else { return false }
        return rule.conflictingBundleIDs.contains { runningConflicts.contains($0) }
    }

    func scan() {
        // Not just .scanning: the menu bar's Smart Scan button has no
        // disabled state, so it can start a scan while a clean is running —
        // and then the two Tasks race on phase, report, selected and outcome.
        guard phase != .scanning, phase != .cleaning else { return }
        phase = .scanning
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
        outcome = nil
        Task {
            let fda = hasFullDiskAccess
            let result = await CleanScanner.scan(hasFullDiskAccess: fda)
            report = result
            refreshRunningConflicts()
            // Pre-check only `safe` items whose app isn't running.
            selected = Set(
                result.items
                    .filter { $0.safety == .safe && !itemHasConflict($0) }
                    .map(\.id)
            )
            withAnimation(.spring) { phase = .review }
        }
    }

    func refreshRunningConflicts() {
        let allConflicts = Set(RuleCatalog.rules.flatMap(\.conflictingBundleIDs))
        runningConflicts = Set(
            NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier)
                .filter { allConflicts.contains($0) }
        )
    }

    func toggleCategory(_ category: CleanCategory) {
        let ids = report.items(in: category).map(\.id)
        if ids.allSatisfy({ selected.contains($0) }) {
            selected.subtract(ids)
        } else {
            selected.formUnion(ids)
        }
    }

    /// Bundle IDs whose items were dropped at clean time because the app
    /// was running — shown in the summary.
    var skippedForRunningApps = 0

    func clean() {
        guard phase == .review, !selectedItems.isEmpty else { return }
        phase = .cleaning
        // Enforce the running-app guard at clean time, not just at
        // pre-selection — the user may have launched Chrome after scanning.
        let items = RunningAppGuard.filterOutConflicts(selectedItems)
        skippedForRunningApps = selectedItems.count - items.count
        let dry = dryRun
        Task {
            let result = await Cleaner.clean(items: items, dryRun: dry)
            outcome = result
            withAnimation(.spring) { phase = .summary }
        }
    }

    func backToIdle() {
        phase = .idle
        report = ScanReport()
        selected = []
        outcome = nil
    }
}
