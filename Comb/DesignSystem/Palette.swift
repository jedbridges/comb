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

    /// The channel badge's fill: a muted tone that sits back from the text
    /// rather than competing with it. Chartreuse here would spend the brand's
    /// scarcest colour on decoration.
    static let glyphSurface = adaptive(light: 0xDCDFE8, dark: 0x343850)
    /// The symbol inside it, soft enough to read as texture.
    static let glyphTint = adaptive(light: 0x6C6F85, dark: 0x9BA3C4)

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
