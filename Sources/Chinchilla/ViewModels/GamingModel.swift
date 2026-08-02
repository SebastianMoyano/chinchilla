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

    var id: pid_t { pid }
}

@MainActor
@Observable
final class GamingModel {
    var isActive = false
    var candidates: [QuitCandidate] = []
    var selectedPIDs: Set<pid_t> = []
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

    private static let relaunchDefaultsKey = "gaming.terminatedApps"

    // MARK: Candidates

    func refreshCandidates() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
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
                    warning: suggestion ?? nil
                )
            }
            .sorted { ($0.isSuggested ? 0 : 1, $0.name) < ($1.isSuggested ? 0 : 1, $1.name) }
        selectedPIDs = Set(candidates.filter(\.isSuggested).map(\.pid))
    }

    // MARK: Activation

    func activate() {
        guard !isActive else { return }
        isActive = true
        sleepAssertion.activate()

        // Quit selected apps gracefully; remember them for relaunch.
        let toQuit = NSWorkspace.shared.runningApplications.filter {
            selectedPIDs.contains($0.processIdentifier)
        }
        var terminatedPaths = UserDefaults.standard.stringArray(forKey: Self.relaunchDefaultsKey) ?? []
        for app in toQuit {
            if let path = app.bundleURL?.path, !terminatedPaths.contains(path) {
                terminatedPaths.append(path)
            }
            app.terminate()  // graceful Quit event — the app may prompt to save
        }
        UserDefaults.standard.set(terminatedPaths, forKey: Self.relaunchDefaultsKey)

        // Stop TM backups now and every 10 minutes while active.
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
        hideOverlay()
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
