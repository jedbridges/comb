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

    /// Nav-bar and toolbar glyphs. Solid, and never blended.
    ///
    /// These used to be `text` plus `luminousChrome`, and `plusLighter` adds
    /// the source to whatever happens to be behind it. On the channel list the
    /// bar sits on bare olive gradient and the glyph blew out toward white; on
    /// a timeline it sits over scrolled message content and came back warm.
    /// Same code, two colours, which is what made the app's own chrome look
    /// like it had been drawn by two people. A fixed warm off-white renders
    /// identically wherever the bar lands.
    static let chrome = adaptive(light: 0x3A3728, dark: 0xF1EDDB)

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

    /// The wordmark's fill: ambient light from the mark above it.
    ///
    /// The mark sits directly over the word everywhere the word appears, so
    /// the top of the letters catches a faint chartreuse warmth that fades to
    /// plain text colour by the baseline. Diegetic, not decorative: the
    /// gradient runs the way the light actually falls, and it is subtle
    /// enough to read as illumination rather than as coloured type.
    static var wordmarkGlow: LinearGradient {
        LinearGradient(
            colors: [
                adaptive(light: 0x8A8434, dark: 0xE9E7C0),
                adaptive(light: 0x4C4F69, dark: 0xCAD3F5),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Signature gradient

    /// The vertical olive-to-blue wash Buzz paints across the whole app surface.
    ///
    /// Built from many stops rather than two, for two reasons that compound on
    /// a full-screen backdrop.
    ///
    /// A two-stop gradient blends in sRGB, where the numbers are gamma-encoded
    /// rather than proportional to light. Interpolating them directly darkens
    /// and desaturates the middle, which is the muddy band across the centre of
    /// the screen. These stops are mixed in linear light and converted back, so
    /// the midpoint is the colour halfway between the ends rather than an
    /// artefact of the encoding.
    ///
    /// The stops are then distributed on a smoothstep rather than evenly, so
    /// the wash holds its olive at the top and settles into navy at the bottom
    /// instead of ramping at a constant rate. A constant ramp reads as a
    /// mechanical fade; eased, it reads as light falling off.
    static let backgroundGradient = LinearGradient(
        stops: gradientStops(light: (0xE6E6B6, 0xC4D0DA), dark: (0x4A4616, 0x0A1423)),
        startPoint: .top,
        endPoint: .bottom
    )

    /// Resolution is the cheapest fix for banding: more stops mean smaller
    /// steps than the display can resolve. Seventeen is past the point where
    /// another one is visible on a 3x screen.
    private static let gradientResolution = 16

    private static func gradientStops(
        light: (UInt32, UInt32),
        dark: (UInt32, UInt32)
    ) -> [Gradient.Stop] {
        (0...gradientResolution).map { step in
            let position = Double(step) / Double(gradientResolution)
            // Smoothstep: flat at both ends, steepest in the middle.
            let eased = position * position * (3 - 2 * position)
            return Gradient.Stop(
                color: adaptive(
                    light: mixInLinearLight(light.0, light.1, eased),
                    dark: mixInLinearLight(dark.0, dark.1, eased)
                ),
                location: position
            )
        }
    }

    /// Blends two sRGB colours the way light actually adds, by undoing the
    /// transfer function, mixing, and reapplying it.
    private static func mixInLinearLight(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color {
        func toLinear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func toGamma(_ c: Double) -> Double {
            c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        func channel(_ hex: UInt32, _ shift: UInt32) -> Double {
            Double((hex >> shift) & 0xFF) / 255
        }
        func mixed(_ shift: UInt32) -> Double {
            let low = toLinear(channel(a, shift))
            let high = toLinear(channel(b, shift))
            return toGamma(low + (high - low) * t)
        }
        return Color(.sRGB, red: mixed(16), green: mixed(8), blue: mixed(0), opacity: 1)
    }

    /// The adaptive overload that takes already-built colours, for the gradient
    /// stops, which are computed rather than named as hex literals.
    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
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
