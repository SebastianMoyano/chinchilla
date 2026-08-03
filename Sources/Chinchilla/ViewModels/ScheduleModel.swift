import SwiftUI
import Observation
import ServiceManagement
import UserNotifications
import SystemKit

/// Weekly automatic clean, registered through SMAppService (the modern
/// login-item API): no baked executable paths, survives app moves, and shows
/// up properly in System Settings → Login Items. Runs the app headless with
/// CHINCHILLA_SCHEDULED=1 (Sundays 12:00), safe categories only.
@MainActor
@Observable
final class ScheduleModel {
    static let agentPlistName = "com.sebastian.chinchilla.autoclean.plist"
    /// Pre-0.3.0 installs used a hand-written user LaunchAgent — migrate it out.
    static var legacyPlistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.sebastian.chinchilla.autoclean.plist"
    }

    private let service = SMAppService.agent(plistName: ScheduleModel.agentPlistName)

    var isEnabled = false
    var needsApproval = false
    var errorMessage: String?

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        isEnabled = service.status == .enabled
        needsApproval = service.status == .requiresApproval
    }

    struct ScheduleError: LocalizedError {
        let errorDescription: String?
    }

    func toggle(_ on: Bool) {
        errorMessage = nil
        Task {
            do {
                if on {
                    try await enable()
                } else {
                    try disable()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            refreshStatus()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func enable() async throws {
        guard Bundle.main.bundleIdentifier != nil else {
            throw ScheduleError(errorDescription: String(
                localized: "Run the installed app (e.g. /Applications/Chinchilla.app) to enable scheduling."
            ))
        }
        await migrateLegacyAgent()

        // Ask for notification permission so the weekly result is visible;
        // if denied, warn — the clean would otherwise run invisibly.
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge])) ?? false
        if !granted {
            errorMessage = String(
                localized: "Notifications are off — the weekly clean will run silently. You can still check the log in Deep Clean."
            )
        }

        try service.register()
        if service.status == .requiresApproval {
            errorMessage = String(
                localized: "Approve Chinchilla in System Settings → Login Items to finish."
            )
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func disable() throws {
        try service.unregister()
    }

    /// Removes the pre-0.3.0 hand-written LaunchAgent if present.
    private func migrateLegacyAgent() async {
        let legacy = Self.legacyPlistPath
        guard FileManager.default.fileExists(atPath: legacy) else { return }
        _ = try? await ShellRunner.run(
            "/bin/launchctl",
            ["bootout", "gui/\(getuid())/com.sebastian.chinchilla.autoclean"],
            timeout: .seconds(10)
        )
        try? FileManager.default.removeItem(atPath: legacy)
    }
}
