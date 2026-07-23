import SwiftUI

/// The type ramp. Every piece of text in the app uses one of these tokens;
/// a raw `.system(size:)` in a feature view is a bug.
///
/// Tokens map onto Apple's semantic text styles rather than fixed sizes, so
/// Dynamic Type scaling comes free: `.callout` is 16pt at the default setting,
/// which is Buzz's chat body size, and grows with the user's preference where
/// a hardcoded 16 would not. The Buzz ramp this maps from: body 16, secondary
/// 14, caption 12, meta 11, headings 24/28/32 at w600.
enum Typography {
    // MARK: - Display

    /// The app name on cold-start screens. Pair with `.kerning(Kerning.display)`.
    static let display = Font.system(.largeTitle, weight: .semibold)

    /// Screen titles rendered in content (navigation bars style themselves).
    static let screenTitle = Font.system(.title2, weight: .semibold)

    // MARK: - Content

    /// Chat messages and primary reading text. 16pt at default, Buzz's base.
    static let body = Font.system(.callout)
    static let bodyEmphasis = Font.system(.callout, weight: .semibold)

    /// Supporting copy: previews, explanations, empty states. 15pt at default.
    static let secondary = Font.system(.subheadline)

    /// Author names and row titles. Slightly smaller than body, heavier.
    static let name = Font.system(.subheadline, weight: .semibold)

    // MARK: - Chrome

    /// Buttons that carry the screen's primary action.
    static let action = Font.system(.body, weight: .semibold)
    /// Secondary and inline buttons.
    static let actionSecondary = Font.system(.callout, weight: .medium)

    /// Standalone small text: notices, hints, link-outs. 13pt at default.
    static let label = Font.system(.footnote, weight: .medium)
    static let labelRegular = Font.system(.footnote)

    /// Metadata riding on content: timestamps, counts. 12pt at default.
    static let caption = Font.system(.caption)
    static let captionEmphasis = Font.system(.caption, weight: .medium)

    /// Field labels and eyebrow text. Render uppercased with
    /// `.kerning(Kerning.eyebrow)`. 11pt at default.
    static let eyebrow = Font.system(.caption2, weight: .semibold)

    // MARK: - Code-shaped

    /// The six digits both devices must match during pairing. Large, bold and
    /// monospaced: this is the one number in the app a person reads aloud to
    /// compare against another screen, and every digit has to be unmistakable.
    static let pairingCode = Font.system(.largeTitle, design: .monospaced).weight(.bold)

    /// Relay URLs, keys, identifiers.
    static let mono = Font.system(.callout, design: .monospaced)
    static let monoSmall = Font.system(.footnote, design: .monospaced)

    /// Numbers that change in place (counts, badges), so digits do not jitter.
    static let count = Font.system(.caption, design: .default).monospacedDigit()

    /// Glyphs riding beside text: chevrons, small symbols. Same size as
    /// `caption` but without the monospaced digits, which mean nothing on a
    /// symbol and were only ever inherited by borrowing `count`.
    static let icon = Font.system(.caption)

    // MARK: - Emoji
    //
    // Emoji carry their own optical size: a glyph set at the same point size
    // as body text reads noticeably smaller, because the character fills less
    // of its em box than a letter does. These are the only place in the ramp
    // where a role gets a size for how it looks rather than what it is.

    /// Emoji in a reaction chip, beside its count.
    static let emoji = Font.system(.body)

    /// Emoji in the picker grid, sized to be tappable and scannable.
    static let emojiLarge = Font.system(.largeTitle)
}

/// Letterspacing pairs with the token, not the call site.
enum Kerning {
    /// Large display text tightens, per the Buzz lockup (-0.02em at 40pt).
    static let display: CGFloat = -0.8
    static let title: CGFloat = -0.4
    /// Uppercased eyebrow labels open up.
    static let eyebrow: CGFloat = 0.6
}
