import SwiftUI
import AppKit
import UserNotifications
import CleanCore
import SystemKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let isScheduledRun = CommandLine.arguments.contains("--scheduled-clean")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isScheduledRun {
            runScheduledClean()
            return
        }
        // Essential when launched via `swift run` (no bundle); harmless when bundled.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.isScheduledRun
    }

    /// Headless weekly clean: safe categories only, then notify and exit.
    @MainActor
    private func runScheduledClean() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.windows.forEach { $0.orderOut(nil) }
        Task { @MainActor in
            // The Window scene may materialize after launch — keep it hidden.
            try? await Task.sleep(for: .milliseconds(300))
            NSApp.windows.forEach { $0.orderOut(nil) }

            let report = await CleanScanner.scan(hasFullDiskAccess: Permissions.hasFullDiskAccess())
            let safeItems = report.items.filter { $0.safety == .safe }
            let outcome = await Cleaner.clean(items: safeItems, dryRun: false)

            let content = UNMutableNotificationContent()
            content.title = String(localized: "Weekly clean done")
            let freed = ByteCountFormatter.string(fromByteCount: outcome.freedBytes, countStyle: .file)
            content.body = String(localized: "Chinchilla freed \(freed) of safe junk.")
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
            try? await Task.sleep(for: .seconds(1))
            NSApp.terminate(nil)
        }
    }
}

@main
struct ChinchillaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("Chinchilla", id: "main") {
            MainWindow()
                .environment(appState)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        // Always show the main window on launch — without this, macOS can
        // restore a "no windows" state and the app looks like it didn't open.
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appState.updates.checkNow()
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}
