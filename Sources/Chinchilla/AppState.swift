import SwiftUI
import Observation
import CleanCore
import SystemKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard
    case deepClean
    case uninstaller
    case diskAnalyzer
    case gaming
    case startup
    case health
    case cast
    case devTools

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "Dashboard"
        case .deepClean: "Deep Clean"
        case .uninstaller: "Uninstaller"
        case .diskAnalyzer: "Disk Space"
        case .gaming: "Gaming Mode"
        case .startup: "Startup"
        case .health: "Health"
        case .cast: "Cast"
        case .devTools: "Docker & Dev"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .deepClean: "sparkles"
        case .uninstaller: "trash.square"
        case .diskAnalyzer: "chart.pie.fill"
        case .gaming: "gamecontroller.fill"
        case .startup: "power"
        case .health: "stethoscope"
        case .cast: "tv"
        case .devTools: "shippingbox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .dashboard: .blue
        case .deepClean: .purple
        case .uninstaller: .red
        case .diskAnalyzer: .orange
        case .gaming: .green
        case .startup: .yellow
        case .health: .mint
        case .cast: .indigo
        case .devTools: .cyan
        }
    }
}

@MainActor
@Observable
final class AppState {
    var selection: SidebarItem = .dashboard
    let diskAnalyzer = DiskAnalyzerModel()
    let deepClean = DeepCleanModel()
    let devTools = DevToolsModel()
    let gaming = GamingModel()
    let uninstaller = UninstallerModel()
    let startup = StartupModel()
    let schedule = ScheduleModel()
    let desktopWidget = DesktopWidgetModel()
    let tabSaver = TabSaverModel()
    let updates = UpdateModel()
    let snapshots = SnapshotModel()
    let memory = MemoryModel()
    let dailyBoost = DailyBoostModel()
    let tabGuard = TabGuardModel()
    let health = HealthModel()
    let cast = CastModel()

    let stalls = StallDetector()

    init() {
        dailyBoost.appState = self
        dailyBoost.startIfEnabled()
        // Never leave apps frozen by a crashed gaming session.
        gaming.resumeOrphanedPauses()
        stalls.context = { [weak self] in self?.stallContext ?? "unknown" }
        stalls.start()
    }

    /// What the app was doing, for the stall log. Anything that puts a
    /// spinner or live view on screen belongs here.
    private var stallContext: String {
        var parts = ["screen=\(selection)"]
        if health.loading { parts.append("health.loading") }
        if health.fixRunning != nil { parts.append("health.fix") }
        if health.snappyBusy { parts.append("health.snappy") }
        if !health.brewBusy.isEmpty { parts.append("health.brew") }
        if startup.loading { parts.append("startup.loading") }
        if cast.mirroring { parts.append("cast.mirroring") }
        if cast.mirrorStarting { parts.append("cast.mirrorStarting") }
        if smartScanRunning { parts.append("smartScan") }
        if deepClean.phase != .idle { parts.append("deepClean.\(deepClean.phase)") }
        if diskAnalyzer.phase != .idle { parts.append("disk.\(diskAnalyzer.phase)") }
        if devTools.pruneRunning { parts.append("devTools.prune") }
        if memory.refreshing { parts.append("memory.refreshing") }
        if memory.appleIntelligenceBusy { parts.append("memory.appleIntelligence") }
        if updates.installPhase != .idle { parts.append("update.\(updates.installPhase)") }
        return parts.joined(separator: " ")
    }

    // MARK: Smart Scan — one click, three sweeps, one number.

    var smartScanRunning = false
    var smartScanDone = false

    /// Bytes of `safe` clean items found by the last deep-clean scan.
    var smartCleanBytes: Int64 {
        deepClean.report.items.filter { $0.safety == .safe }.reduce(0) { $0 + $1.size }
    }

    var smartDockerBytes: Int64 {
        devTools.dockerUsage.reduce(0) { $0 + $1.reclaimableBytes }
    }

    var smartArtifactBytes: Int64 {
        devTools.artifacts.reduce(0) { $0 + $1.size }
    }

    var smartTotalBytes: Int64 {
        smartCleanBytes + smartDockerBytes + smartArtifactBytes
    }

    // MARK: Smart Clean — the step the scan used to stop short of

    var smartCleaning = false
    var smartCleanConfirming = false
    var smartFreedBytes: Int64?
    /// Kept so the card can say what didn't go, and why. Reporting only the
    /// happy number is how "freed zero" becomes a mystery instead of a
    /// permissions problem the user could act on.
    var smartCleanFailures: [CleanFailure] = []

    /// Everything the scan found that is safe to remove and whose app isn't
    /// running. Docker images and build artefacts are deliberately not here:
    /// those need a look before they go, and each has its own screen.
    var smartCleanableItems: [CleanItem] {
        RunningAppGuard.filterOutConflicts(
            deepClean.report.items.filter { $0.safety == .safe }
        )
    }

    var smartCleanableBytes: Int64 {
        smartCleanableItems.reduce(0) { $0 + $1.size }
    }

    /// Safe junk that can't go right now because its app is open. Naming it
    /// is the difference between "the button is broken" and "close Chrome".
    var smartBlockedByAppsBytes: Int64 {
        max(0, smartCleanBytes - smartCleanableBytes)
    }

    /// Runs the clean the scan just justified. Safe categories only, and
    /// straight to the Trash — the same work the weekly schedule does
    /// unattended, so doing it from a button that asks first is the more
    /// cautious version, not the riskier one.
    func smartClean() {
        guard !smartCleaning else { return }
        let items = smartCleanableItems
        guard !items.isEmpty else { return }
        smartCleaning = true
        smartFreedBytes = nil
        smartCleanFailures = []
        BusyDeadline.arm("Dashboard.smartClean", .seconds(300)) { [weak self] in
            self?.smartCleaning ?? false
        } clear: { [weak self] in
            self?.smartCleaning = false
        }
        Task {
            defer { smartCleaning = false }
            let outcome = await Cleaner.clean(items: items, dryRun: false)
            smartCleanFailures = outcome.failures
            withAnimation(.spring) { smartFreedBytes = outcome.freedBytes }
            // The numbers on screen are now stale in the user's favour.
            deepClean.scan()
        }
    }

    func smartScan() {
        guard !smartScanRunning else { return }
        smartScanRunning = true
        smartScanDone = false
        smartFreedBytes = nil
        smartCleanFailures = []
        deepClean.scan()
        devTools.refreshDocker()
        devTools.scanArtifacts()
        Task {
            // The three sweeps report through their own models; wait for all.
            while deepClean.phase == .scanning
                || devTools.dockerPhase == .loading
                || devTools.artifactsScanning {
                try? await Task.sleep(for: .milliseconds(200))
            }
            smartScanRunning = false
            withAnimation(.spring) { smartScanDone = true }
        }
    }
}
