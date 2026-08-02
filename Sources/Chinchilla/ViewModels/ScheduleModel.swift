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

    private func enable() async throws {
        // Ask for notification permission so the weekly result is visible.
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge])

        let executable = Bundle.main.executablePath
            ?? "/Applications/Chinchilla.app/Contents/MacOS/Chinchilla"
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
