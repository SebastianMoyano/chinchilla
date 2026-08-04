import SwiftUI

/// What the menu bar icon is saying right now.
///
/// The two modes aren't exclusive — Daily is a profile you leave on, Gaming is
/// a session you start and end — so the icon shows whichever is *doing
/// something to your Mac at this moment*. Gaming pauses apps and holds them
/// paused, so it wins while it lasts; the coffee cup comes back when it ends.
enum MenuBarStatus: Equatable {
    case gaming
    case daily
    case idle

    static func current(gaming: Bool, daily: Bool) -> MenuBarStatus {
        if gaming { .gaming } else if daily { .daily } else { .idle }
    }

    var symbol: String {
        switch self {
        case .gaming: "gamecontroller.fill"
        case .daily: "cup.and.saucer.fill"
        case .idle: "sparkles"
        }
    }

    /// Shown in the menu bar panel, so the icon is never a puzzle.
    var label: LocalizedStringKey {
        switch self {
        case .gaming: "Gaming mode is on"
        case .daily: "Daily mode is on"
        case .idle: "No mode active"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .gaming: "Apps you chose are paused. Ending the session brings them all back."
        case .daily: "Tabs sleep, the weekly clean is scheduled, and memory pressure is watched."
        case .idle: "Turn on Daily mode for everyday use, or start a Gaming session before you play."
        }
    }

    var tint: Color {
        switch self {
        case .gaming: .purple
        case .daily: .brown
        case .idle: .secondary
        }
    }
}
