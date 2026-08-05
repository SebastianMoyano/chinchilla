import Foundation
import UserNotifications
import AppKit
import SystemKit

/// Asks about closing an idle app from the notification itself.
///
/// A notification that only says "memory is getting tight" makes the user go
/// and find out what to do about it, which is most of the reason people ignore
/// these. This one names the app, says what it's holding and how long it has
/// done nothing, and carries the two answers as buttons — so the whole
/// exchange happens without opening anything.
@MainActor
enum MemoryNotifier {
    // Plain constants, readable from wherever the reply lands — the
    // notification delegate callback is nonisolated.
    nonisolated static let categoryID = "chinchilla.memory.quit"
    nonisolated static let closeAction = "chinchilla.memory.close"
    nonisolated static let neverAction = "chinchilla.memory.never"
    /// Carries the app name back when the user taps a button.
    nonisolated static let targetKey = "target"

    static func registerCategory() {
        let close = UNNotificationAction(
            identifier: closeAction,
            title: String(localized: "Close it"),
            options: []
        )
        let never = UNNotificationAction(
            identifier: neverAction,
            title: String(localized: "Never ask about this app"),
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: categoryID, actions: [close, never],
                intentIdentifiers: [], options: []
            )
        ])
    }

    static func ask(about action: MemoryPlan.Action) async {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Close \(action.target)?")
        content.body = action.reason
        content.categoryIdentifier = categoryID
        content.userInfo = [targetKey: action.target]
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                // One identifier, so a second ask replaces the first instead of
                // stacking up while the user is away from the Mac.
                identifier: "chinchilla.memory.quit", content: content, trigger: nil
            )
        )
    }
}
