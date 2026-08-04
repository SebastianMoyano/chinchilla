import SwiftUI
import Observation
import AppKit
import CleanCore
import DiskScanKit

@MainActor
@Observable
final class UninstallerModel {
    var apps: [InstalledApp] = []
    var scanning = false
    var searchText = ""

    // Detail/uninstall flow
    var inspecting: InstalledApp?
    var leftovers: [Leftover] = []
    var selectedLeftovers: Set<String> = []
    var includeAppBundle = true
    var uninstalling = false
    var lastResult: String?

    var filteredApps: [InstalledApp] {
        guard !searchText.isEmpty else { return apps }
        let query = searchText.lowercased()
        return apps.filter { $0.name.lowercased().contains(query) }
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            apps = await AppInventory.scan()
            scanning = false
        }
    }

    func inspect(_ app: InstalledApp) {
        inspecting = app
        leftovers = []
        includeAppBundle = true
        lastResult = nil
        Task {
            let found = await Blocking.run { LeftoverFinder.find(for: app) }
            // The user may have opened another app's sheet meanwhile — never
            // attach app A's leftovers to app B.
            guard inspecting?.id == app.id else { return }
            leftovers = found
            selectedLeftovers = Set(found.map(\.id))
        }
    }

    var inspectedTotalBytes: Int64 {
        let leftoverBytes = leftovers
            .filter { selectedLeftovers.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.size }
        return leftoverBytes + (includeAppBundle ? (inspecting?.size ?? 0) : 0)
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        guard let bundleID = app.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func quit(_ app: InstalledApp) {
        guard let bundleID = app.bundleID else { return }
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            running.terminate()
        }
    }

    // MARK: - Leftovers from apps that are already gone

    enum OrphanPhase: Equatable {
        case idle, scanning, done
    }

    var orphanPhase: OrphanPhase = .idle
    var orphans: [Orphan] = []
    var selectedOrphans: Set<String> = []
    var orphanResult: String?

    var selectedOrphanBytes: Int64 {
        orphans.filter { selectedOrphans.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func scanOrphans() {
        guard orphanPhase != .scanning else { return }
        orphanPhase = .scanning
        orphanResult = nil
        Task {
            let found = await OrphanFinder.scan()
            orphans = found
            // Nothing is pre-selected: these are `caution`, and the user is
            // the only one who knows whether that app is coming back.
            selectedOrphans = []
            withAnimation(.spring) { orphanPhase = .done }
        }
    }

    /// Trash every file of the selected groups. SafetyPolicy re-checks each
    /// path even though the finder only ever looks inside ~/Library.
    /// Deletion runs off the main thread. Each file costs a `SafetyPolicy`
    /// validation — per-component symlink resolution plus an `lstat` — on top
    /// of the `trashItem` itself, and a big leftover group is thousands of
    /// files. On the main thread that was a frozen window for the duration.
    func trashSelectedOrphans() {
        guard !trashingOrphans else { return }
        trashingOrphans = true
        let groups = orphans.filter { selectedOrphans.contains($0.id) }
        let work = groups.map { (id: $0.id, paths: $0.files.map(\.path)) }
        Task {
            defer { trashingOrphans = false }
            let outcome = await Blocking.run { Self.trashGroups(work) }
            orphans.removeAll { outcome.done.contains($0.id) }
            selectedOrphans.subtract(outcome.done)
            orphanResult = outcome.failures.isEmpty
                ? String(localized: "Moved \(outcome.trashed) items to Trash.")
                : outcome.failures.joined(separator: "\n")
        }
    }

    var trashingOrphans = false

    private nonisolated static func trashGroups(
        _ groups: [(id: String, paths: [String])]
    ) -> (done: Set<String>, trashed: Int, failures: [String]) {
        var done: Set<String> = []
        var failures: [String] = []
        var trashed = 0
        for group in groups {
            var groupFailed = false
            for path in group.paths {
                do {
                    let target = try SafetyPolicy.validate(
                        path: path, declaredRoots: OrphanFinder.declaredRoots
                    )
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: target), resultingItemURL: nil
                    )
                    trashed += 1
                } catch {
                    groupFailed = true
                    failures.append(
                        "\((path as NSString).lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
            if !groupFailed { done.insert(group.id) }
        }
        return (done, trashed, failures)
    }


    /// Everything goes to Trash — uninstalling is always recoverable.
    func uninstall() {
        guard let app = inspecting, !uninstalling else { return }
        guard app.bundleID != "com.sebastian.chinchilla" else {
            lastResult = String(localized: "Chinchilla can't uninstall itself.")
            return
        }
        uninstalling = true
        let paths = leftovers.filter { selectedLeftovers.contains($0.id) }.map(\.path)
            + (includeAppBundle ? [app.path] : [])
        Task {
            var failures: [String] = []
            var trashed = 0
            for path in paths {
                do {
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: path), resultingItemURL: nil
                    )
                    trashed += 1
                } catch {
                    failures.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
            uninstalling = false
            if failures.isEmpty {
                lastResult = String(localized: "Moved \(trashed) items to Trash.")
                inspecting = nil
                scan()
            } else {
                lastResult = failures.joined(separator: "\n")
            }
        }
    }
}
