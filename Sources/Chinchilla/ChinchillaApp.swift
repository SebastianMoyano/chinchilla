import SwiftUI
import AppKit
import UserNotifications
import CleanCore
import SystemKit

/// Entry-point dispatcher: CLI subcommands run without ever spinning up the
/// GUI; everything else launches the SwiftUI app.
@main
struct Main {
    static func main() async {
        // Chrome spawns us as a native-messaging host with the extension
        // origin as argv[1] — this MUST run before the CLI/GUI dispatch or
        // every browser connection would boot a full GUI instance.
        if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("chrome-extension://") })
            || CommandLine.arguments.contains("--native-host") {
            exit(await TabGuardHost.run())
        }
        if let command = ChinchillaCLI.command(from: CommandLine.arguments) {
            let code = await ChinchillaCLI.run(command)
            exit(code)
        }
        ChinchillaApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let isScheduledRun =
        CommandLine.arguments.contains("--scheduled-clean")
        || ProcessInfo.processInfo.environment["CHINCHILLA_SCHEDULED"] == "1"

    static let keepInMenuBarKey = "keepInMenuBar"

    /// Launched right after boot/login (as a login item): start quietly in
    /// the menu bar instead of shoving the window in the user's face.
    static let isLoginLaunch = SystemUptime.seconds() < 180

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.isScheduledRun {
            runScheduledClean()
            return
        }
        UserDefaults.standard.register(defaults: [Self.keepInMenuBarKey: true])
        if Self.isLoginLaunch {
            NSApp.setActivationPolicy(.accessory)
            return
        }
        // Essential when launched via `swift run` (no bundle); harmless when bundled.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // macOS can restore a "no windows" state, and then the app looks like
        // it never opened. SwiftUI's `defaultLaunchBehavior` handles this, but
        // it's macOS 15+ and this app still supports 14 — so bring the window
        // up ourselves once the scene exists.
        presentMainWindow()
    }

    /// SwiftUI creates the `Window` scene's NSWindow lazily, and macOS can
    /// restore a "no windows" state — then the app looks like it never
    /// opened. `defaultLaunchBehavior` covers this but is macOS 15+, so we
    /// bring the window up ourselves, retrying briefly because the scene
    /// doesn't exist yet when the delegate is called.
    @MainActor
    private func presentMainWindow(attempt: Int = 0) {
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard attempt < 40 else { return }          // ~2 s, then give up quietly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.presentMainWindow(attempt: attempt + 1)
        }
    }

    /// With "keep running in menu bar" on (default), closing the window
    /// demotes the app to a menu-bar accessory instead of quitting — gaming
    /// mode, the widget and the weekly schedule survive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if Self.isScheduledRun { return false }
        if UserDefaults.standard.bool(forKey: Self.keepInMenuBarKey) {
            NSApp.setActivationPolicy(.accessory)
            return false
        }
        return true
    }

    /// Dock icon clicked (or app re-opened) with no windows: promote back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.setActivationPolicy(.regular)
        }
        return true
    }

    /// Headless weekly clean: safe categories only, skipping anything whose
    /// app is currently running, then notify and exit.
    @MainActor
    private func runScheduledClean() {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            let report = await CleanScanner.scan(hasFullDiskAccess: Permissions.hasFullDiskAccess())
            let safeItems = RunningAppGuard.filterOutConflicts(
                report.items.filter { $0.safety == .safe }
            )
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
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appState.updates.checkNow()
                }
            }
        }

        MenuBarExtra(isInserted: .constant(!AppDelegate.isScheduledRun)) {
            MenuBarView()
                .environment(appState)
        } label: {
            // The icon tells you which mode is on without opening anything.
            Image(systemName: MenuBarStatus.current(
                gaming: appState.gaming.isActive,
                daily: appState.dailyBoost.isEnabled
            ).symbol)
        }
        .menuBarExtraStyle(.window)
    }
}

