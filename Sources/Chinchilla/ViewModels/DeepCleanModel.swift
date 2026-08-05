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
    var selected: Set<String> = [] {
        // Every checkbox toggle re-renders every section header; keeping the
        // per-category selected counts here makes that O(selected) once per
        // click instead of a contains-per-item reduce in each header's body.
        didSet { recomputeSelectedCounts() }
    }
    /// ON = preview only. The user must flip it to actually delete.
    var dryRun = true
    var outcome: CleanOutcome?
    /// Bundle IDs of running apps that conflict with some items (browsers).
    var runningConflicts: Set<String> = []
    var hasFullDiskAccess = true
    /// Fired when a scan replaces the report, so whoever derives numbers from
    /// it can do that work once instead of per render.
    var onReportChanged: (@MainActor () -> Void)?

    private static let rulesByID = Dictionary(
        uniqueKeysWithValues: RuleCatalog.rules.map { ($0.id, $0) }
    )

    var selectedItems: [CleanItem] {
        report.items(ids: selected)
    }

    /// Read on every render of the Deep Clean screen, so it doesn't walk the
    /// item list — it adds up the selection, which is what it's actually about.
    var selectedBytes: Int64 {
        report.bytes(of: selected)
    }

    var categories: [CleanCategory] {
        report.populatedCategories
    }

    // MARK: Per-category numbers, derived once instead of per render

    /// The report is immutable between scans, so its category totals are
    /// computed when it changes — not summed by every section on every render.
    private var categoryTotalBytes: [CleanCategory: Int64] = [:]
    private var selectedCountsByCategory: [CleanCategory: Int] = [:]

    func totalBytes(in category: CleanCategory) -> Int64 {
        categoryTotalBytes[category] ?? 0
    }

    func selectedCount(in category: CleanCategory) -> Int {
        selectedCountsByCategory[category] ?? 0
    }

    private func rebuildCategoryTotals() {
        var totals: [CleanCategory: Int64] = [:]
        for item in report.items {
            totals[item.category, default: 0] += item.size
        }
        categoryTotalBytes = totals
    }

    private func recomputeSelectedCounts() {
        var counts: [CleanCategory: Int] = [:]
        for id in selected {
            if let item = report.item(id: id) {
                counts[item.category, default: 0] += 1
            }
        }
        selectedCountsByCategory = counts
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
        // This was the one busy phase in the app without a deadline, and it
        // drives an indeterminate spinner: if the scan wedges (a TCC prompt
        // nobody answered, a dead network volume), the window re-lays out at
        // display rate forever and the screen stays unusable until relaunch.
        BusyDeadline.arm("DeepClean.scanning", .seconds(180)) { [weak self] in
            self?.phase == .scanning
        } clear: { [weak self] in
            guard let self, phase == .scanning else { return }
            phase = report.items.isEmpty ? .idle : .review
        }
        Task {
            let fda = hasFullDiskAccess
            let result = await CleanScanner.scan(hasFullDiskAccess: fda)
            report = result
            rebuildCategoryTotals()
            refreshRunningConflicts()
            // The dashboard's totals are derived from this report; it can't
            // recompute them while drawing without enumerating every running
            // process on every frame.
            onReportChanged?()
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
        BusyDeadline.arm("DeepClean.cleaning", .seconds(600)) { [weak self] in
            self?.phase == .cleaning
        } clear: { [weak self] in
            guard let self, phase == .cleaning else { return }
            phase = .review
        }
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
        rebuildCategoryTotals()
        selected = []
        outcome = nil
    }
}
