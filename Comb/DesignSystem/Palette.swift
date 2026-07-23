import SwiftUI

/// Comb's color tokens.
///
/// Values are taken from the Buzz source so Comb sits naturally beside it:
/// the brand pair from `desktop/src/shared/styles/globals/components.css`, the
/// surface ramp from its Catppuccin Latte (light) and Macchiato (dark) themes.
/// Only the palette is borrowed. The mark and the name are Comb's own, because
/// Apache 2.0 section 6 withholds trademark rights.
enum Palette {
    // MARK: - Brand

    /// The brand yellow, and the app's global accent (`AccentColor` in the
    /// asset catalog carries the same value, so system controls tint to match).
    /// Used sparingly, for the single most important thing on a screen.
    static let chartreuse = Color(hex: 0xD7D700)

    /// Warm near-black. Pairs with chartreuse; not the same as the text color.
    static let ink = Color(hex: 0x231E1E)

    /// Olive ink, for text sitting on a chartreuse field.
    static let oliveInk = Color(hex: 0x717106)

    // MARK: - Surfaces

    static let base = adaptive(light: 0xEFF1F5, dark: 0x24273A)
    static let mantle = adaptive(light: 0xE6E9EF, dark: 0x1E2030)
    static let surface = adaptive(light: 0xCCD0DA, dark: 0x363A4F)
    static let border = adaptive(light: 0xBCC0CC, dark: 0x494D64)

    // MARK: - Content

    static let text = adaptive(light: 0x4C4F69, dark: 0xCAD3F5)
    static let subtext = adaptive(light: 0x6C6F85, dark: 0xA5ADCB)
    static let accent = adaptive(light: 0x8839EF, dark: 0xA875F5)
    static let link = adaptive(light: 0x1E66F5, dark: 0x8AADF4)

    /// A hue-preserving lift for surfaces sitting on the gradient. White at low
    /// opacity shifts lightness without introducing a competing grey.
    static let liftOnGradient = Color.white.opacity(0.07)
    static let hairlineOnGradient = Color.white.opacity(0.10)

    // MARK: - Glyphs

    /// A channel badge and an avatar are the same object wearing two shapes,
    /// so they share every token below.
    ///
    /// The rule: a glyph has no hue of its own. It used to carry a Catppuccin
    /// indigo, and that one value read as two different things depending on
    /// where in the list it landed, clashing as a cool patch against the olive
    /// at the top and dissolving into the navy at the bottom. Lifting the
    /// backdrop instead of painting over it means the badge belongs at every
    /// scroll position, in either appearance, with one value.

    /// The badge fill: a lift of whatever the gradient is doing behind it.
    /// Inverts with the appearance, because lightening a pale background does
    /// nothing at all, which is exactly how the old token failed in light mode.
    static let glyphLift = adaptiveOverlay(light: .black, lightAlpha: 0.07,
                                           dark: .white, darkAlpha: 0.10)

    /// The edge that keeps the badge from dissolving completely where the
    /// gradient happens to match its own value.
    static let glyphHairline = adaptiveOverlay(light: .black, lightAlpha: 0.12,
                                               dark: .white, darkAlpha: 0.14)

    /// The symbol or initial. The one place a glyph is allowed colour, and it
    /// is the brand's. Light mode drops to olive ink: chartreuse on a pale
    /// gradient is close to unreadable, and the token exists for exactly this.
    static let glyphMark = adaptive(light: 0x717106, dark: 0xBFBF0A)

    // MARK: - Semantic

    static let danger = adaptive(light: 0xD20F39, dark: 0xED8796)
    static let success = adaptive(light: 0x40A02B, dark: 0xA6DA95)
    static let warning = adaptive(light: 0xDF8E1D, dark: 0xEED49F)

    // MARK: - Signature gradient

    /// The vertical olive-to-blue wash Buzz paints across the whole app surface.
    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                adaptive(light: 0xE6E6B6, dark: 0x4A4616),
                adaptive(light: 0xC4D0DA, dark: 0x0A1423),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }

    /// An overlay that has to flip direction with the appearance, not just
    /// change value. White at 10% lifts a dark backdrop and does essentially
    /// nothing to a pale one, so light mode needs black instead.
    private static func adaptiveOverlay(
        light: Color, lightAlpha: Double,
        dark: Color, darkAlpha: Double
    ) -> Color {
        Color(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return UIColor(isDark ? dark.opacity(darkAlpha) : light.opacity(lightAlpha))
        })
    }
}

extension Color {
    /// Builds a color from a 24-bit RGB literal, so tokens above read like the
    /// hex values in the Buzz source they came from.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
