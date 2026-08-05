import SwiftUI
import Observation
import CleanCore
import SystemKit

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard
    case deepClean
    case uninstaller
    case diskAnalyzer
    case memory
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
        case .memory: "Memory"
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
        case .memory: "memorychip"
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
        case .memory: .teal
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
    let memoryHistory = MemoryHistoryModel()
    let everydayPlan = EverydayPlanModel()
    let dailyBoost = DailyBoostModel()
    let tabGuard = TabGuardModel()
    let health = HealthModel()
    let cast = CastModel()

    let stalls = StallDetector()

    /// The live app state, for the few places outside SwiftUI that need it —
    /// notification replies arrive at the app delegate, which has no
    /// environment to read from.
    static weak var current: AppState?

    init() {
        Self.current = self
        dailyBoost.appState = self
        dailyBoost.startIfEnabled()
        deepClean.onReportChanged = { [weak self] in self?.refreshSmartTotals() }
        // Never leave apps frozen by a crashed gaming session.
        gaming.resumeOrphanedPauses()
        // Same idea for sound: a crash mid-cast must not leave a silent Mac.
        OutputMute.restoreIfInterrupted()
        stalls.start()
        // Starts with the app, not with the screen: a record only kept while
        // you're looking at it wouldn't be a record.
        memoryHistory.start()
        everydayPlan.appState = self
        // The plan is rebuilt from each new reading, so it always reflects
        // what this Mac is doing rather than what it was doing at launch.
        memoryHistory.onSample = { [weak self] samples in
            guard let self else { return }
            everydayPlan.refresh(samples: samples)
        }
    }

    /// What the app was doing, for the stall log. Anything that puts a
    /// spinner or live view on screen belongs here.
    /// Pushed to the watchdog on every screen change, because it can't come
    /// and ask once the main thread is wedged.
    func refreshStallContext() {
        stalls.lastKnownContext.withLock { $0 = stallContext }
    }

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

    /// The Smart Scan card's numbers, worked out when a scan finishes rather
    /// than while drawing. Every one of these used to be a computed property
    /// that walked the full item list — and `smartCleanableItems` also
    /// enumerated every running process, through `NSWorkspace`, five times per
    /// render of that one card.
    private(set) var smartCleanBytes: Int64 = 0
    private(set) var smartDockerBytes: Int64 = 0
    private(set) var smartArtifactBytes: Int64 = 0
    private(set) var smartCleanableItems: [CleanItem] = []
    private(set) var smartCleanableBytes: Int64 = 0

    var smartTotalBytes: Int64 {
        smartCleanBytes + smartDockerBytes + smartArtifactBytes
    }

    /// Safe junk that can't go right now because its app is open. Naming it
    /// is the difference between "the button is broken" and "close Chrome".
    var smartBlockedByAppsBytes: Int64 {
        max(0, smartCleanBytes - smartCleanableBytes)
    }

    /// Call whenever a scan or clean changes what's on offer. Cheap to call;
    /// it is the only place that pays for the process enumeration.
    func refreshSmartTotals() {
        let safe = deepClean.report.items.filter { $0.safety == .safe }
        smartCleanBytes = safe.reduce(0) { $0 + $1.size }
        smartDockerBytes = devTools.dockerUsage.reduce(0) { $0 + $1.reclaimableBytes }
        smartArtifactBytes = devTools.artifacts.reduce(0) { $0 + $1.size }
        // Docker images and build artefacts are deliberately not cleanable
        // from here: those need a look before they go, and each has its own
        // screen.
        smartCleanableItems = RunningAppGuard.filterOutConflicts(safe)
        smartCleanableBytes = smartCleanableItems.reduce(0) { $0 + $1.size }
    }

    // MARK: Smart Clean — the step the scan used to stop short of

    var smartCleaning = false
    var smartCleanConfirming = false
    var smartFreedBytes: Int64?
    /// Kept so the card can say what didn't go, and why. Reporting only the
    /// happy number is how "freed zero" becomes a mystery instead of a
    /// permissions problem the user could act on.
    var smartCleanFailures: [CleanFailure] = []

    /// Runs the clean the scan just justified. Safe categories only, and
    /// straight to the Trash — the same work the weekly schedule does
    /// unattended, so doing it from a button that asks first is the more
    /// cautious version, not the riskier one.
    func smartClean() {
        // Deep Clean can be mid-clean over overlapping items; two passes make
        // the loser report files the winner already removed.
        guard !smartCleaning, deepClean.phase != .cleaning else { return }
        // Apps may have opened since the scan; the guard is enforced at clean
        // time, not just at scan time.
        refreshSmartTotals()
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
        // This waits on three other models' flags, so it inherits whatever
        // can go wrong in any of them. It was the one busy flag in the app
        // with no deadline of its own.
        BusyDeadline.arm("Dashboard.smartScan", .seconds(180)) { [weak self] in
            self?.smartScanRunning ?? false
        } clear: { [weak self] in self?.smartScanRunning = false }
        deepClean.scan()
        devTools.refreshDocker()
        devTools.scanArtifacts()
        Task {
            // The three sweeps report through their own models; wait for all.
            // The wait has its own limit rather than trusting theirs: this
            // loop wakes the main actor five times a second, and one model
            // that never clears its phase turns that into a permanent
            // heartbeat nobody can see.
            let giveUpAt = ContinuousClock.now + .seconds(200)
            while deepClean.phase == .scanning
                || devTools.dockerPhase == .loading
                || devTools.artifactsScanning {
                guard ContinuousClock.now < giveUpAt else { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            smartScanRunning = false
            // Docker and artefacts finish outside the deep-clean callback.
            refreshSmartTotals()
            withAnimation(.spring) { smartScanDone = true }
        }
    }
}
