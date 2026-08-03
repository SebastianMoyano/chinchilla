import SwiftUI
import Observation
import AppKit
import SystemKit

@MainActor
@Observable
final class HealthModel {
    var report = HealthReport()
    var loading = false

    // Fix-it kit
    var fixRunning: String?
    var fixResult: String?

    // Snappy UI
    var snappyOn = SnappyUI.isApplied
    var snappyBusy = false

    // Brew services
    var brewServices: [BrewService] = []
    var brewBusy: Set<String> = []

    /// Health and brew load as INDEPENDENT tasks: the screen renders
    /// instantly and each block fills in when its data lands — a slow brew
    /// can never hold the health rows hostage (or vice versa).
    func refresh() {
        guard !loading else { return }
        loading = true
        snappyOn = SnappyUI.isApplied
        Task {
            defer { loading = false }
            report = await HealthCheck.run()
        }
        BusyDeadline.arm("Health.loading", .seconds(30)) { [weak self] in
            self?.loading ?? false
        } clear: { [weak self] in
            self?.loading = false
        }
        Task {
            brewServices = await BrewServices.list()
        }
    }

    func runFix(_ id: String, _ operation: @escaping @Sendable () async throws -> Void, success: String) {
        guard fixRunning == nil else { return }
        fixRunning = id
        fixResult = nil
        BusyDeadline.arm("Health.fix(\(id))", .seconds(180)) { [weak self] in
            self?.fixRunning == id
        } clear: { [weak self] in
            self?.fixRunning = nil
        }
        Task {
            defer { fixRunning = nil }
            do {
                try await operation()
                fixResult = success
            } catch {
                fixResult = String(localized: "Cancelled or failed — nothing was changed.")
            }
        }
    }

    func toggleSnappy(_ on: Bool) {
        guard !snappyBusy else { return }
        snappyBusy = true
        BusyDeadline.arm("Health.snappy", .seconds(60)) { [weak self] in
            self?.snappyBusy ?? false
        } clear: { [weak self] in
            self?.snappyBusy = false
        }
        Task {
            defer { snappyBusy = false }
            if on { await SnappyUI.apply() } else { await SnappyUI.revert() }
            snappyOn = SnappyUI.isApplied
        }
    }

    func stopBrewService(_ name: String) {
        guard !brewBusy.contains(name) else { return }
        brewBusy.insert(name)
        BusyDeadline.arm("Health.brew(\(name))", .seconds(90)) { [weak self] in
            self?.brewBusy.contains(name) ?? false
        } clear: { [weak self] in
            self?.brewBusy.remove(name)
        }
        Task {
            defer { brewBusy.remove(name) }
            await BrewServices.stopService(name)
            brewServices = await BrewServices.list()
        }
    }
}
