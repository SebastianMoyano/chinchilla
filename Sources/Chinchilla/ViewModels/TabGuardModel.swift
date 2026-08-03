import SwiftUI
import Observation
import AppKit
import SystemKit

/// GUI side of Tab Guard: manifest install, connection status aggregated
/// across browser profiles, stats, and one-shot commands via the mailbox.
@MainActor
@Observable
final class TabGuardModel {
    var isManifestInstalled = TabGuardInstaller.isInstalled
    var stats = TabGuardStatus()
    var connections = 0
    var showingSetup = false
    var setupError: String?

    private var nextEventSeq = TabGuardMailbox.maxEventSeq() + 1
    private var pollTask: Task<Void, Never>?

    var isConnected: Bool { connections > 0 }

    func refresh() {
        isManifestInstalled = TabGuardInstaller.isInstalled
        let (combined, count) = TabGuardMailbox.aggregateStatus()
        stats = combined
        connections = count
    }

    /// Poll status files while the card is visible (5 s — cheap file reads).
    func startPolling() {
        guard pollTask == nil else { return }
        refresh()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func installConnector() {
        setupError = nil
        do {
            try TabGuardInstaller.installManifests()
            isManifestInstalled = true
        } catch {
            setupError = String(describing: error)
        }
    }

    func uninstallConnector() {
        TabGuardInstaller.removeManifests()
        isManifestInstalled = false
    }

    var bundledExtensionPath: String? {
        TabGuardInstaller.bundledExtensionPath
    }

    func revealExtensionInFinder() {
        guard let path = bundledExtensionPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyExtensionPath() {
        guard let path = bundledExtensionPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func openColdSaveList() {
        sendEvent(type: "openColdSavePage")
    }

    private func sendEvent(type: String, urls: [String]? = nil, all: Bool? = nil) {
        TabGuardMailbox.appendEvent(
            TabGuardEvent(seq: nextEventSeq, type: type, urls: urls, all: all)
        )
        nextEventSeq += 1
    }

    // MARK: - Desired state (settings + gaming)

    static func setGaming(active: Bool, pauseVideos: Bool) {
        var desired = TabGuardMailbox.readDesired() ?? TabGuardDesired()
        desired.gamingActive = active
        desired.pauseVideos = pauseVideos
        desired.seq += 1
        TabGuardMailbox.writeDesired(desired)
    }
}
