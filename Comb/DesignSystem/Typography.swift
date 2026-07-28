import SwiftUI

/// The type ramp.
///
/// Tokens map onto Apple's semantic text styles rather than fixed sizes, so
/// Dynamic Type scaling comes free: `.body` is `.callout`, 16pt at the default
/// setting, which is Buzz's chat body size, and grows with the user's
/// preference where a hardcoded 16 would not.
///
/// Six sizes, and no two of them are a point apart. An earlier ramp had eight,
/// with twelve of its twenty tokens crowded into the 16/15 and 13/12 bands.
/// Two tokens that render a point apart at the same weight are not a step in a
/// hierarchy, they are a coin flip at the call site, and the coin came up
/// differently on every screen: message text was `.callout` in the timeline and
/// `.subheadline` in search results, and an author's name was set *smaller*
/// than the message it introduced. The steps below are far enough apart that
/// picking the wrong one is visible, which is the only thing that keeps a ramp
/// honest.
///
/// | Size | Style | Role |
/// |---|---|---|
/// | 34 | `.largeTitle` | display |
/// | 22 | `.title2` | title |
/// | 17 | `.body` | action (buttons only) |
/// | 16 | `.callout` | body, names, controls |
/// | 13 | `.footnote` | support |
/// | 11 | `.caption2` | meta, eyebrow |
///
/// Prefer `.textRole(_:)` at call sites: it sets the font, letterspacing and
/// colour together. These fonts are public for the places that need a `Font`
/// rather than a view modifier, which in practice means `AttributedString`.
enum Typography {
    // MARK: - Display

    /// The app name on cold-start screens.
    static let display = Font.system(.largeTitle, weight: .semibold)

    /// Screen titles rendered in content (navigation bars style themselves).
    static let title = Font.system(.title2, weight: .semibold)

    // MARK: - Content

    /// Chat messages and primary reading text. 16pt at default, Buzz's base.
    static let body = Font.system(.callout)
    static let bodyStrong = Font.system(.callout, weight: .semibold)
    static let bodyItalic = Font.system(.callout).italic()

    /// Buttons that carry the screen's primary action. The one place the ramp
    /// goes above body size for something that is not a heading: a full-width
    /// button's label is the target, not a label on it.
    static let action = Font.system(.body, weight: .semibold)

    /// Inline and secondary controls. Body size, medium weight, so a control
    /// reads as a control beside the text it acts on rather than by being big.
    static let control = Font.system(.callout, weight: .medium)

    /// Supporting copy: previews, explanations, empty states. 13pt at default.
    static let support = Font.system(.footnote)
    static let supportStrong = Font.system(.footnote, weight: .medium)

    // MARK: - Meta

    /// Metadata riding on content: timestamps, counts, hints. 11pt at default.
    static let meta = Font.system(.caption2)
    static let metaStrong = Font.system(.caption2, weight: .medium)

    /// Section labels. Meta size, but semibold and tracked out, which is what
    /// tells it apart from a timestamp set at the same size.
    static let eyebrow = Font.system(.caption2, weight: .semibold)

    /// Numbers that change in place (counts, badges), so digits do not jitter.
    static let count = Font.system(.caption2).monospacedDigit()

    // MARK: - Code-shaped

    /// The six digits both devices must match during pairing. Large, bold and
    /// monospaced: this is the one number in the app a person reads aloud to
    /// compare against another screen, and every digit has to be unmistakable.
    static let pairingCode = Font.system(.largeTitle, design: .monospaced).weight(.bold)

    /// Relay URLs, keys, identifiers.
    static let mono = Font.system(.callout, design: .monospaced)
    static let monoSupport = Font.system(.footnote, design: .monospaced)

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

/// Letterspacing pairs with the role, not the call site.
enum Kerning {
    /// Large display text tightens, per the Buzz lockup (-0.02em at 40pt).
    static let display: CGFloat = -0.8
    static let title: CGFloat = -0.4
    /// Small semibold labels open up. Deliberately not paired with uppercasing:
    /// modern iOS sets section headers in sentence case, and half these labels
    /// are names a person chose, which nothing should be shouting.
    static let eyebrow: CGFloat = 0.6
}


// MARK: - Roles

/// What a piece of text *is*, which is the only thing a call site should have
/// to decide.
///
/// A role carries its size, its weight, its letterspacing and its colour
/// together. Before this they were three independent choices at every `Text`,
/// and nothing said which of the three expressed a demotion: a timestamp was
/// `caption + subtext + luminousChrome` in the timeline, `caption + subtext`
/// in search, and `caption + subtext.opacity(0.8)` on a date pill. Three
/// treatments for one role, because there were three dials and no rule.
///
/// Now there is one dial. `TextTone` exists for the cases where the same role
/// genuinely changes meaning (a failed send, a selected chip), and it is a
/// closed set rather than an open `Color`, so a screen cannot invent a shade.
enum TextRole {
    /// The app name on cold-start screens.
    case display
    /// A screen title set in content.
    case title

    /// Chat messages and primary reading text.
    case body
    /// Emphasis within body text, and the name at the head of a message. Same
    /// size as the message it introduces, distinguished by weight: a header
    /// smaller than its own content is not a header.
    case bodyStrong
    /// Quoted and deleted content.
    case bodyItalic

    /// The screen's primary action.
    case action
    /// Inline and secondary controls.
    case control

    /// Supporting copy: previews, explanations, empty states.
    case support
    /// Supporting copy that carries weight: notices, hints, link-outs.
    case supportStrong

    /// Timestamps, counts, and other metadata riding on content.
    case meta
    /// Metadata that has to be picked out of a line of it.
    case metaStrong
    /// A count that changes in place, so its digits do not jitter.
    case count
    /// A section label.
    case eyebrow

    /// Relay URLs, keys, identifiers.
    case mono
    /// Identifiers and log lines at support size.
    case monoSupport
    /// The six digits read aloud during pairing.
    case pairingCode

    /// Emoji in a reaction chip.
    case emoji
    /// Emoji in the picker grid.
    case emojiLarge

    var font: Font {
        switch self {
        case .display: Typography.display
        case .title: Typography.title
        case .body: Typography.body
        case .bodyStrong: Typography.bodyStrong
        case .bodyItalic: Typography.bodyItalic
        case .action: Typography.action
        case .control: Typography.control
        case .support: Typography.support
        case .supportStrong: Typography.supportStrong
        case .meta: Typography.meta
        case .metaStrong: Typography.metaStrong
        case .count: Typography.count
        case .eyebrow: Typography.eyebrow
        case .mono: Typography.mono
        case .monoSupport: Typography.monoSupport
        case .pairingCode: Typography.pairingCode
        case .emoji: Typography.emoji
        case .emojiLarge: Typography.emojiLarge
        }
    }

    var kerning: CGFloat {
        switch self {
        case .display: Kerning.display
        case .title, .pairingCode: Kerning.title
        case .eyebrow: Kerning.eyebrow
        default: 0
        }
    }

    /// The colour the role wears unless a tone overrides it. This pairing is
    /// the whole point: hierarchy is expressed by role, once, rather than by
    /// size here and colour there.
    var tone: TextTone {
        switch self {
        case .display, .title, .body, .bodyStrong, .action, .control,
             .metaStrong, .mono, .pairingCode, .emoji, .emojiLarge:
            .primary
        case .support, .supportStrong, .meta, .count, .eyebrow, .monoSupport:
            .muted
        // A tombstone, and it should read like one.
        case .bodyItalic:
            .faint
        }
    }
}

/// The closed set of colours text is allowed to take.
enum TextTone {
    /// Primary reading text.
    case primary
    /// Secondary text: supporting copy, metadata, anything demoted.
    case muted
    /// Text that is present but deliberately receding: a message still in
    /// flight, a channel nobody has posted in. The named third tier, which
    /// used to be four different `.opacity()` values applied by hand.
    case faint
    /// The brand accent. One per screen.
    case brand
    /// Text sitting on a chartreuse fill.
    case onBrand
    /// Toolbar and bar-button glyphs: a fixed value that renders identically
    /// wherever the bar lands over the gradient.
    case chrome

    case danger
    case success
    case warning

    var color: Color {
        switch self {
        case .primary: Palette.text
        case .muted: Palette.subtext
        case .faint: Palette.faint
        case .brand: Palette.chartreuse
        case .onBrand: Palette.ink
        case .chrome: Palette.chrome
        case .danger: Palette.danger
        case .success: Palette.success
        case .warning: Palette.warning
        }
    }
}

private struct TextRoleModifier: ViewModifier {
    let role: TextRole
    let tone: TextTone?

    /// Nonisolated for the same reason `textRole` is, below.
    nonisolated init(role: TextRole, tone: TextTone?) {
        self.role = role
        self.tone = tone
    }

    func body(content: Content) -> some View {
        content
            .font(role.font)
            .kerning(role.kerning)
            .foregroundStyle((tone ?? role.tone).color)
    }
}

extension View {
    /// Sets this text's size, weight, letterspacing and colour from its role.
    ///
    /// One call, one decision. Pass a `tone` only when the same role means
    /// something different here: a failed send, a selection, a label on the
    /// brand fill.
    /// `nonisolated` because the call sites are not all on the main actor:
    /// a `PhotosPicker` label closure, for one, is nonisolated, and applying a
    /// modifier is just building a value. Only the modifier's `body` needs the
    /// main actor, and it still has it.
    nonisolated func textRole(_ role: TextRole, _ tone: TextTone? = nil) -> some View {
        modifier(TextRoleModifier(role: role, tone: tone))
    }
}
