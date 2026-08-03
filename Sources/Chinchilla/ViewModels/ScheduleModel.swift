import SwiftUI
import Observation
import UserNotifications
import SystemKit

/// Weekly automatic clean: a user LaunchAgent runs the app headless with
/// `--scheduled-clean` (Sundays 12:00). Only `safe` categories, real delete,
/// result lands in the notification center and the audit log.
@MainActor
@Observable
final class ScheduleModel {
    static let label = "com.sebastian.chinchilla.autoclean"
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    var isEnabled = FileManager.default.fileExists(atPath: ScheduleModel.plistPath)
    var errorMessage: String?

    func toggle(_ on: Bool) {
        errorMessage = nil
        Task {
            do {
                if on {
                    try await enable()
                } else {
                    try await disable()
                }
                isEnabled = FileManager.default.fileExists(atPath: Self.plistPath)
            } catch {
                errorMessage = error.localizedDescription
                isEnabled = FileManager.default.fileExists(atPath: Self.plistPath)
            }
        }
    }

    struct ScheduleError: LocalizedError {
        let errorDescription: String?
    }

    private func enable() async throws {
        // The agent plist bakes in the executable path — only a real installed
        // bundle survives rebuilds and relaunches.
        guard Bundle.main.bundleIdentifier != nil,
              let executable = Bundle.main.executablePath,
              !executable.contains("/.build/") else {
            throw ScheduleError(errorDescription: String(
                localized: "Run the installed app (e.g. /Applications/Chinchilla.app) to enable scheduling."
            ))
        }

        // Ask for notification permission so the weekly result is visible;
        // if denied, warn — the clean would otherwise run invisibly.
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge])) ?? false
        if !granted {
            errorMessage = String(
                localized: "Notifications are off — the weekly clean will run silently. You can still check the log in Deep Clean."
            )
        }
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable, "--scheduled-clean"],
            "StartCalendarInterval": ["Weekday": 0, "Hour": 12, "Minute": 0],
            "RunAtLoad": false,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        let dir = (Self.plistPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: Self.plistPath))
        _ = try? await ShellRunner.run(
            "/bin/launchctl", ["bootstrap", "gui/\(getuid())", Self.plistPath], timeout: .seconds(10)
        )
    }

    private func disable() async throws {
        _ = try? await ShellRunner.run(
            "/bin/launchctl", ["bootout", "gui/\(getuid())/\(Self.label)"], timeout: .seconds(10)
        )
        try FileManager.default.removeItem(atPath: Self.plistPath)
    }
}
