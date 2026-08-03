import SwiftUI
import Observation
import AppKit
import SystemKit

struct QuitCandidate: Identifiable {
    let pid: pid_t
    let bundleID: String
    let name: String
    let bundleURL: URL?
    let isSuggested: Bool
    let warning: LocalizedStringKey?
    /// Only curated background apps may be frozen — browsers/media/chat
    /// reconnect badly or beachball; closing is more honest for those.
    let canPause: Bool

    var id: pid_t { pid }
}

enum GamingAppAction: String, CaseIterable {
    case keep
    case pause
    case close
}

@MainActor
@Observable
final class GamingModel {
    var isActive = false
    var candidates: [QuitCandidate] = []
    /// Per-row decision, seeded from remembered per-bundleID preferences.
    var rowActions: [pid_t: GamingAppAction] = [:]
    var pendingConfirmation = false
    var overlayVisible = false

    // Rolling 60-sample history for sparklines.
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var snapshot = SystemSnapshot()

    private let sampler = SystemSampler()
    private var samplingTask: Task<Void, Never>?
    private var backupStopTask: Task<Void, Never>?
    private let sleepAssertion = SleepAssertion()
    private var overlayPanel: NSPanel?

    /// Apps that must never be offered for quitting.
    private static let denylist: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.apple.loginwindow", "com.apple.WindowManager",
        "com.sebastian.chinchilla",
    ]

    /// Known background hogs, pre-suggested (with honest warnings).
    private static let suggested: [String: LocalizedStringKey?] = [
        "com.tinyspeck.slackmacgap": nil,
        "com.hnc.Discord": "Voice chat will disconnect",
        "com.microsoft.teams2": nil,
        "com.google.Chrome": "All tabs will close",
        "com.getdropbox.dropbox": nil,
        "com.google.drivefs": nil,
        "com.microsoft.OneDrive": nil,
        "com.apple.Photos": nil,
        "com.adobe.acc.AdobeCreativeCloud": nil,
        "com.docker.docker": "Running containers will stop",
        "com.spotify.client": nil,
    ]

    /// Background/sync apps that freeze cleanly. Browsers, media players,
    /// chat apps and Docker are deliberately excluded.
    private static let pausable: Set<String> = [
        "com.getdropbox.dropbox", "com.google.drivefs", "com.microsoft.OneDrive",
        "com.adobe.acc.AdobeCreativeCloud", "com.apple.Photos",
    ]

    private static let relaunchDefaultsKey = "gaming.terminatedApps"
    private static let pausedDefaultsKey = "gaming.pausedApps"
    private static let actionPrefsKey = "gaming.actionPrefs"
    static let skipConfirmKey = "gaming.skipConfirm"
    static let focusShortcutOnKey = "gaming.focusShortcutOn"
    static let focusShortcutOffKey = "gaming.focusShortcutOff"

    // MARK: Candidates

    func refreshCandidates() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let prefs = UserDefaults.standard.dictionary(forKey: Self.actionPrefsKey) as? [String: String] ?? [:]
        candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.processIdentifier != frontmost }
            .compactMap { app in
                guard let bundleID = app.bundleIdentifier,
                      !Self.denylist.contains(bundleID) else { return nil }
                let suggestion = Self.suggested[bundleID]
                return QuitCandidate(
                    pid: app.processIdentifier,
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID,
                    bundleURL: app.bundleURL,
                    isSuggested: suggestion != nil,
                    warning: suggestion ?? nil,
                    canPause: Self.pausable.contains(bundleID)
                )
            }
            .sorted { ($0.isSuggested ? 0 : 1, $0.name) < ($1.isSuggested ? 0 : 1, $1.name) }
        // Seed row actions: remembered preference > suggested-close > keep.
        rowActions = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
            let remembered = prefs[candidate.bundleID].flatMap(GamingAppAction.init(rawValue:))
            let action = remembered ?? (candidate.isSuggested ? .close : .keep)
            // A remembered "pause" for an app no longer pausable degrades to close.
            let valid = (action == .pause && !candidate.canPause) ? GamingAppAction.close : action
            return (candidate.pid, valid)
        })
    }

    func setAction(_ action: GamingAppAction, for candidate: QuitCandidate) {
        rowActions[candidate.pid] = action
        var prefs = UserDefaults.standard.dictionary(forKey: Self.actionPrefsKey) as? [String: String] ?? [:]
        prefs[candidate.bundleID] = action.rawValue
        UserDefaults.standard.set(prefs, forKey: Self.actionPrefsKey)
    }

    var closingCandidates: [QuitCandidate] { candidates.filter { rowActions[$0.pid] == .close } }
    var pausingCandidates: [QuitCandidate] { candidates.filter { rowActions[$0.pid] == .pause } }

    // MARK: Activation

    /// Entry point from the toggle: confirm first unless the user opted out
    /// or nothing disruptive would happen.
    func requestActivate() {
        refreshConflictFreeCandidates()
        let disruptive = !closingCandidates.isEmpty || !pausingCandidates.isEmpty
        if UserDefaults.standard.bool(forKey: Self.skipConfirmKey) || !disruptive {
            activate()
        } else {
            pendingConfirmation = true
        }
    }

    /// Candidates may be stale (apps quit since the list was built).
    private func refreshConflictFreeCandidates() {
        if candidates.isEmpty { refreshCandidates() }
    }

    func activate() {
        guard !isActive else { return }
        pendingConfirmation = false
        isActive = true
        sleepAssertion.activate()

        // 1. Pause the freeze-safe ones — persist BEFORE the first SIGSTOP
        //    so a crash can always resume them.
        var pausedList: [PausedProcess] = []
        for candidate in pausingCandidates {
            guard let start = ProcessPauser.startTime(of: candidate.pid) else { continue }
            pausedList.append(PausedProcess(
                pid: candidate.pid, startTime: start,
                bundleID: candidate.bundleID, name: candidate.name
            ))
        }
        persistPaused(pausedList)
        var actuallyPaused: [PausedProcess] = []
        for candidate in pausingCandidates {
            if let paused = ProcessPauser.pauseTree(
                pid: candidate.pid, bundleID: candidate.bundleID, name: candidate.name
            ) {
                actuallyPaused.append(paused)
            }
        }
        persistPaused(actuallyPaused)

        // 2. Quit the rest gracefully; remember them for relaunch.
        let closingPIDs = Set(closingCandidates.map(\.pid))
        let toQuit = NSWorkspace.shared.runningApplications.filter {
            closingPIDs.contains($0.processIdentifier)
        }
        var terminatedPaths = UserDefaults.standard.stringArray(forKey: Self.relaunchDefaultsKey) ?? []
        for app in toQuit {
            if let path = app.bundleURL?.path, !terminatedPaths.contains(path) {
                terminatedPaths.append(path)
            }
            app.terminate()  // graceful Quit event — the app may prompt to save
        }
        UserDefaults.standard.set(terminatedPaths, forKey: Self.relaunchDefaultsKey)

        // 3. Tell Tab Guard (all connected browser profiles): sleep background
        //    tabs, pause background media. No-op when not installed.
        TabGuardModel.setGaming(active: true, pauseVideos: true)

        // 4. User's Focus/DND shortcut, if configured.
        if let shortcut = UserDefaults.standard.string(forKey: Self.focusShortcutOnKey), !shortcut.isEmpty {
            Task { await ShortcutsRunner.run(shortcut) }
        }

        // 5. Stop TM backups now and every 10 minutes while active.
        backupStopTask = Task {
            while !Task.isCancelled {
                await TimeMachine.stopBackup()
                try? await Task.sleep(for: .seconds(600))
            }
        }
        startSampling()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        sleepAssertion.release()
        backupStopTask?.cancel()
        backupStopTask = nil
        resumePaused()
        TabGuardModel.setGaming(active: false, pauseVideos: false)
        if let shortcut = UserDefaults.standard.string(forKey: Self.focusShortcutOffKey), !shortcut.isEmpty {
            Task { await ShortcutsRunner.run(shortcut) }
        }
        hideOverlay()
    }

    // MARK: Pause bookkeeping (crash-safe)

    private func persistPaused(_ list: [PausedProcess]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.pausedDefaultsKey)
        }
    }

    private var persistedPaused: [PausedProcess] {
        guard let data = UserDefaults.standard.data(forKey: Self.pausedDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([PausedProcess].self, from: data)) ?? []
    }

    private func resumePaused() {
        for paused in persistedPaused {
            ProcessPauser.resumeTree(paused)
        }
        UserDefaults.standard.removeObject(forKey: Self.pausedDefaultsKey)
    }

    /// Called at app launch: SIGCONT verified leftovers from a crashed
    /// session (never leaves apps frozen), and clear a stale gaming flag
    /// in the Tab Guard mailbox.
    func resumeOrphanedPauses() {
        let orphans = persistedPaused
        guard !orphans.isEmpty || !isActive else { return }
        for paused in orphans {
            ProcessPauser.resumeTree(paused)
        }
        UserDefaults.standard.removeObject(forKey: Self.pausedDefaultsKey)
        if !isActive {
            TabGuardModel.setGaming(active: false, pauseVideos: false)
        }
    }

    var terminatedAppPaths: [String] {
        UserDefaults.standard.stringArray(forKey: Self.relaunchDefaultsKey) ?? []
    }

    func relaunchTerminatedApps() {
        for path in terminatedAppPaths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        UserDefaults.standard.removeObject(forKey: Self.relaunchDefaultsKey)
    }

    func clearTerminatedApps() {
        UserDefaults.standard.removeObject(forKey: Self.relaunchDefaultsKey)
    }

    // MARK: Stats sampling

    func startSampling() {
        guard samplingTask == nil else { return }
        samplingTask = Task {
            while !Task.isCancelled {
                let snap = sampler.sample()
                snapshot = snap
                if let cpu = snap.cpuUsage {
                    cpuHistory.append(cpu)
                    if cpuHistory.count > 60 { cpuHistory.removeFirst() }
                }
                if let gpu = snap.gpuUtilization {
                    gpuHistory.append(gpu)
                    if gpuHistory.count > 60 { gpuHistory.removeFirst() }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopSampling() {
        // Keep sampling while gaming mode or the overlay is alive.
        guard !isActive, !overlayVisible else { return }
        samplingTask?.cancel()
        samplingTask = nil
    }

    // MARK: Overlay

    func toggleOverlay() {
        overlayVisible ? hideOverlay() : showOverlay()
    }

    private func showOverlay() {
        startSampling()
        if overlayPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 130),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: OverlayView(model: self))
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(
                    x: frame.maxX - 260,
                    y: frame.maxY - 150
                ))
            }
            overlayPanel = panel
        }
        overlayPanel?.orderFrontRegardless()
        overlayVisible = true
    }

    private func hideOverlay() {
        overlayPanel?.orderOut(nil)
        overlayVisible = false
        stopSampling()
    }
}
