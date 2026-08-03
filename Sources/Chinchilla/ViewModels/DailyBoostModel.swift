import SwiftUI
import Observation
import UserNotifications
import SystemKit

/// The "daily driver" profile: one switch that keeps a modest Mac feeling
/// quick, honestly. It does exactly three things — no constant "cleaning":
/// 1. Sleeps background browser tabs (the browser's own Memory Saver).
/// 2. Enables the weekly safe auto-clean.
/// 3. Watches memory pressure while Chinchilla runs and sends at most one
///    gentle heads-up every 2 hours when the Mac is genuinely struggling.
@MainActor
@Observable
final class DailyBoostModel {
    static let enabledKey = "dailyBoost"
    private static let lastAlertKey = "dailyBoost.lastAlert"
    private static let alertCooldown: TimeInterval = 2 * 3600

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: DailyBoostModel.enabledKey)
    private var watchdog: Task<Void, Never>?

    // Wired by AppState so the profile can flip the underlying features.
    weak var appState: AppState?

    func startIfEnabled() {
        guard isEnabled, !AppDelegate.isScheduledRun else { return }
        startWatchdog()
    }

    func toggle(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        guard let appState else { return }
        if on {
            appState.tabSaver.refresh()
            appState.tabSaver.setAllMemorySavers(true)
            if !appState.schedule.isEnabled {
                appState.schedule.toggle(true)
            }
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge])
            }
            startWatchdog()
        } else {
            appState.tabSaver.setAllMemorySavers(false)
            if appState.schedule.isEnabled {
                appState.schedule.toggle(false)
            }
            watchdog?.cancel()
            watchdog = nil
        }
    }

    /// Status of each sub-feature, for the card's chips.
    var tabsOn: Bool { appState?.tabSaver.anySaverOn ?? false }
    var weeklyOn: Bool { appState?.schedule.isEnabled ?? false }
    var watchdogOn: Bool { watchdog != nil }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.checkPressure()
            }
        }
    }

    private func checkPressure() async {
        let pressure = SystemSampler.memoryPressure()
        guard pressure == .warning || pressure == .critical else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastAlertKey)
        guard Date.now.timeIntervalSince1970 - last > Self.alertCooldown else { return }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.lastAlertKey)

        let biggest = await Task.detached {
            ProcessMemory.topConsumers(limit: 2).first { $0.name != "macOS" }
        }.value

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your Mac is running low on memory")
        if let biggest {
            let size = ByteCountFormatter.string(fromByteCount: biggest.footprint, countStyle: .memory)
            content.body = String(localized: "\(biggest.name) is using \(size). Open Chinchilla to see what's safe to close.")
        } else {
            content.body = String(localized: "Open Chinchilla to see what's safe to close.")
        }
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "dailyboost.pressure", content: content, trigger: nil)
        )
    }
}
