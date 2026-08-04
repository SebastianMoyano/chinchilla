import SwiftUI

/// The app's design tokens, taken from the reference mockups.
///
/// Before this existed, card styling was copy-pasted into 22 places, corner
/// radii came in eight different sizes, and status colours were chosen per
/// call site — `.green` appears 42 times, `.orange` 35, with no rule about
/// what either meant. That's why the app looked assembled rather than
/// designed.
///
/// These are the mockups' own values, not approximations of them. The palette
/// is dark by construction — its surfaces are near-black and its text is
/// near-white — so the window pins itself to dark rather than washing out
/// under a light system appearance.
///
/// What is *not* copied is deliberate. SF Pro instead of Inter, SF Symbols
/// instead of Material Symbols: those are what macOS draws in every other
/// window, and a bundled web font is exactly what makes a Mac app feel like a
/// port. The glass is real vibrancy sampling the desktop behind the window,
/// which the mockups can only fake with a fixed screenshot.
///
/// And none of their glow. The mockups ring every accent in coloured light —
/// `shadow-[0_0_20px_rgba(0,122,255,0.6)]`, pulsing halos, drop shadows on
/// text. That's a web idiom. Apple's surfaces are flat and the depth comes
/// from translucency: a material, a hairline, and nothing bleeding out of the
/// edges. Sitting beside real Mac controls, a glowing button reads as a toy.
enum Theme {

    private static func hex(_ value: UInt32, alpha: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: alpha
        )
    }

    // MARK: Surfaces

    static let background = hex(0x131315)
    static let surface = hex(0x131315)
    static let surfaceContainerLowest = hex(0x0E0E10)
    static let surfaceContainerLow = hex(0x1B1B1D)
    static let surfaceContainer = hex(0x1F1F21)
    static let surfaceContainerHigh = hex(0x2A2A2C)
    static let surfaceContainerHighest = hex(0x353437)

    // MARK: Text

    static let onSurface = hex(0xE4E2E4)
    /// Secondary copy — a cool grey, not plain 60% white.
    static let onSurfaceVariant = hex(0xC1C6D7)
    static let outline = hex(0x8B90A0)
    static let outlineVariant = hex(0x414755)

    // MARK: Accent and status
    //
    // One meaning each, so a glance is enough:

    /// Actions the user can start. The mockups use the system blue for the
    /// one button that matters on each screen.
    static let action = hex(0x007AFF)
    /// Filled accent — rings, progress, selected state.
    static let primaryContainer = hex(0x4B8EFF)
    /// Accent for text and thin strokes on dark surfaces; the softer one
    /// exists because #4B8EFF on near-black is hard to read at small sizes.
    static let primary = hex(0xADC6FF)
    /// Healthy, finished, safe to remove.
    static let ok = hex(0x42E355)
    /// Worth a look before acting.
    static let caution = hex(0xFFB4AA)
    /// Needs attention, or destructive.
    static let danger = hex(0xFF5447)
    static let error = hex(0xFFB4AB)

    // MARK: Card surface

    static let cardFill = Color.white.opacity(0.05)
    static let cardFillActive = Color.white.opacity(0.09)
    static let cardStroke = Color.white.opacity(0.10)

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
            )
    }
}

/// The rounded icon square the mockups open every card with. It anchors the
/// eye and carries the status colour, so the meaning reads before the text.
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.primary
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous)
            .fill(tint.opacity(0.14))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
    }
}

/// "High", "Review", "Safe" — a word plus a colour, faster to read than a
/// number and harder to misjudge.
struct SeverityPill: View {
    let text: LocalizedStringKey
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// The primary action, the way macOS draws one: a flat capsule of solid
/// colour that darkens on press. The mockups put a coloured glow behind it —
/// that's a web idiom, and next to real Mac controls it reads as a toy.
/// Depth here comes from translucency, not from light bleeding out of things.
struct ActionButtonStyle: ButtonStyle {
    var tint: Color = Theme.action

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.7 : 1)))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Figures that change while you watch them shouldn't make the layout twitch.
struct DataValue: View {
    let text: String
    var size: CGFloat = 15
    var weight: Font.Weight = .medium

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: size, weight: weight, design: .rounded))
            .monospacedDigit()
    }
}
