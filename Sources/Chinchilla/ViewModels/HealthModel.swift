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
            report = await HealthCheck.run()
            loading = false
        }
        Task {
            brewServices = await BrewServices.list()
        }
    }

    func runFix(_ id: String, _ operation: @escaping @Sendable () async throws -> Void, success: String) {
        guard fixRunning == nil else { return }
        fixRunning = id
        fixResult = nil
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
        Task {
            if on { await SnappyUI.apply() } else { await SnappyUI.revert() }
            snappyOn = SnappyUI.isApplied
            snappyBusy = false
        }
    }

    func stopBrewService(_ name: String) {
        guard !brewBusy.contains(name) else { return }
        brewBusy.insert(name)
        Task {
            await BrewServices.stopService(name)
            brewServices = await BrewServices.list()
            brewBusy.remove(name)
        }
    }
}
