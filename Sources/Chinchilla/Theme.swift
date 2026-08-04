import SwiftUI

/// The app's design tokens.
///
/// Before this existed, card styling was copy-pasted into 22 places, corner
/// radii came in eight different sizes, and status colours were chosen per
/// call site — `.green` appears 42 times, `.orange` 35, with no rule about
/// what either means. That's why the app looks assembled rather than designed.
///
/// The palette below is adapted from the reference mockups. What is *not*
/// copied from them is deliberate: SF Pro instead of Inter and SF Symbols
/// instead of Material Symbols, because those are what macOS draws everywhere
/// else and a bundled web font is exactly what makes a Mac app feel foreign.
/// And the glass here is real vibrancy — it samples the desktop actually
/// behind the window, which a CSS backdrop filter can only imitate with a
/// static screenshot.
enum Theme {

    // MARK: Surfaces

    /// Cards float on the window's own material rather than painting their
    /// own background, so they pick up whatever is behind the window.
    static let cardFill = Color.white.opacity(0.05)
    static let cardStroke = Color.white.opacity(0.10)
    /// A card that is doing something right now.
    static let cardFillActive = Color.white.opacity(0.09)

    // MARK: Accent and status
    //
    // One meaning per colour, so a glance is enough:

    /// Actions, progress, anything the user can start.
    static let accent = Color(red: 0.29, green: 0.56, blue: 1.0)      // #4B8EFF
    /// Softer accent for text and rings on dark surfaces.
    static let accentSoft = Color(red: 0.68, green: 0.78, blue: 1.0)  // #ADC6FF
    /// Healthy, finished, safe to remove.
    static let ok = Color(red: 0.26, green: 0.89, blue: 0.33)         // #42E355
    /// Worth a look before acting.
    static let caution = Color(red: 1.0, green: 0.71, blue: 0.58)     // #FFB595
    /// Needs attention, or destructive.
    static let danger = Color(red: 1.0, green: 0.35, blue: 0.28)      // #FF5447

    // MARK: Geometry

    static let cardRadius: CGFloat = 14
    static let tileRadius: CGFloat = 10
    static let cardPadding: CGFloat = 18
    static let stackGap: CGFloat = 16
    static let sectionGap: CGFloat = 24
}

extension View {
    /// The one card style. `active` tints it for a card that's mid-operation.
    func card(active: Bool = false) -> some View {
        padding(Theme.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .fill(active ? Theme.cardFillActive : Theme.cardFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .strokeBorder(Theme.cardStroke, lineWidth: 1)
                    )
                    // Lifts the card off the window instead of leaving it flat.
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            )
    }
}

/// The rounded icon square the mockups use to open every card. It gives each
/// row an anchor for the eye and carries the status colour, so the meaning
/// reads before the text does.
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accentSoft
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
            .fill(.black.opacity(0.20))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
    }
}

/// "High", "Review", "Safe" — a word plus a colour, which is faster to read
/// than a number and harder to misjudge.
struct SeverityPill: View {
    let text: LocalizedStringKey
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
            .foregroundStyle(tint)
    }
}

/// Sizes and counts, in the one place monospacing earns its keep: figures
/// that change while you watch them shouldn't make the layout twitch.
struct DataValue: View {
    let text: String
    var size: CGFloat = 15

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .monospacedDigit()
    }
}
