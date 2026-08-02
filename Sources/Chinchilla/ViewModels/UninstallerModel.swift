import SwiftUI
import Observation
import AppKit
import CleanCore

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
            let found = await Task.detached(priority: .userInitiated) {
                LeftoverFinder.find(for: app)
            }.value
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
