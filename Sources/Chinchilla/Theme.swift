import SwiftUI
import AppKit

/// The app's design tokens, taken from the reference mockups.
///
/// Before this existed, card styling was copy-pasted into 22 places, corner
/// radii came in eight different sizes, and status colours were chosen per
/// call site — `.green` appears 42 times, `.orange` 35, with no rule about
/// what either meant. That's why the app looked assembled rather than
/// designed.
///
/// The dark values are the mockups' own, not approximations. The light ones
/// are their Material 3 counterparts, because a palette that only works at
/// night is half a palette — every token resolves per appearance and follows
/// the system switch on its own.
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

    private static func nsColor(_ value: UInt32, _ alpha: Double) -> NSColor {
        NSColor(
            srgbRed: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// One token, two values. Resolved by AppKit per appearance, so the whole
    /// palette follows the system switch — including mid-session, and
    /// including "Auto" at sunset.
    private static func dual(dark: UInt32, light: UInt32, alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? nsColor(dark, alpha) : nsColor(light, alpha)
        })
    }

    // MARK: Surfaces
    //
    // The dark values are the mockups'. The light ones are their Material 3
    // counterparts — the same neutral ramp mirrored, which is what the scheme
    // the mockups were generated from specifies for a light surface.

    static let background = dual(dark: 0x131315, light: 0xFAF9FA)
    static let surface = dual(dark: 0x131315, light: 0xFAF9FA)
    static let surfaceContainerLowest = dual(dark: 0x0E0E10, light: 0xFFFFFF)
    static let surfaceContainerLow = dual(dark: 0x1B1B1D, light: 0xF4F3F5)
    static let surfaceContainer = dual(dark: 0x1F1F21, light: 0xEEEDEF)
    static let surfaceContainerHigh = dual(dark: 0x2A2A2C, light: 0xE8E7EA)
    static let surfaceContainerHighest = dual(dark: 0x353437, light: 0xE3E2E4)

    // MARK: Text

    static let onSurface = dual(dark: 0xE4E2E4, light: 0x1B1B1D)
    /// Secondary copy — a cool grey, not plain 60% of the text colour.
    static let onSurfaceVariant = dual(dark: 0xC1C6D7, light: 0x44474F)
    static let outline = dual(dark: 0x8B90A0, light: 0x74788A)
    static let outlineVariant = dual(dark: 0x414755, light: 0xC4C7D4)

    // MARK: Accent and status
    //
    // One meaning each, so a glance is enough. Light-mode accents are the
    // mockups' own "fixed variant" tones, which is exactly what Material 3
    // defines those for: the version of each colour that stays legible on a
    // light surface. Caution is the one derived value — the reference palette
    // has no amber, and reusing its salmon would make "look at this" and
    // "this is wrong" the same colour.

    /// Actions the user can start. macOS uses this blue in both appearances.
    static let action = dual(dark: 0x007AFF, light: 0x007AFF)
    /// Filled accent — rings, progress, selected state.
    static let primaryContainer = dual(dark: 0x4B8EFF, light: 0x005BC1)
    /// Accent for text and thin strokes: #4B8EFF is hard to read on
    /// near-black at small sizes, and #ADC6FF is unreadable on white.
    static let primary = dual(dark: 0xADC6FF, light: 0x004493)
    /// Healthy, finished, safe to remove.
    static let ok = dual(dark: 0x42E355, light: 0x005313)
    /// Worth a look before acting.
    static let caution = dual(dark: 0xFFB4AA, light: 0x8A5000)
    /// Needs attention, or destructive.
    static let danger = dual(dark: 0xFF5447, light: 0x930007)
    static let error = dual(dark: 0xFFB4AB, light: 0x93000A)

    // MARK: Card surface
    //
    // A white veil lifts a card off a dark window; on a light one it
    // disappears. These invert.

    static let cardFill = dual(dark: 0xFFFFFF, light: 0x000000, alpha: 0.05)
    static let cardFillActive = dual(dark: 0xFFFFFF, light: 0x000000, alpha: 0.09)
    static let cardStroke = dual(dark: 0xFFFFFF, light: 0x000000, alpha: 0.10)
    /// Unfilled track behind a progress ring.
    static let track = dual(dark: 0xFFFFFF, light: 0x000000, alpha: 0.10)

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

/// Byte sizes, formatted once and the same way everywhere.
///
/// `ByteCountFormatter` renders zero as "Zero KB" by default, which reads as
/// a bug when it lands in a sentence — "Freed Zero KB" was exactly that.
enum Formatters {
    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        byteFormatter.string(fromByteCount: value)
    }
}
