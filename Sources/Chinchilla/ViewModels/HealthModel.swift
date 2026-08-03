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

    func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            report = await HealthCheck.run()
            brewServices = await BrewServices.list()
            snappyOn = SnappyUI.isApplied
            loading = false
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
            await BrewServices.stop(name)
            brewServices = await BrewServices.list()
            brewBusy.remove(name)
        }
    }
}
