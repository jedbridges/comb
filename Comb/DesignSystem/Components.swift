import CombNet
import SwiftUI
import UIKit

// The recurring assemblies. A pattern that appears on two screens gets a
// component here on its second appearance; the third copy is where drift
// starts.

/// A glass surface with the standard card geometry.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = Space.md
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .glassEffect(in: .rect(cornerRadius: Radii.card))
    }
}

/// The screen's one most important action: chartreuse on ink, full width.
/// There is at most one of these per screen, which is what makes it work.
struct PrimaryButton: View {
    let title: String
    var isBusy = false
    var isDisabled = false
    let action: () -> Void

    private var isInactive: Bool { isBusy || isDisabled }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.action)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xxs)
        }
        .buttonStyle(.glassProminent)
        .tint(Palette.chartreuse)
        // Ink only earns its place on the chartreuse fill. Disabled, the style
        // drops the fill to dim glass, and ink on dim glass is black on dark:
        // the label has to switch with the background it sits on.
        .foregroundStyle(isInactive ? Palette.subtext : Palette.ink)
        .disabled(isInactive)
    }
}

/// A supporting action: glass, quieter, same shape as the primary.
struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.actionSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xxs)
        }
        .buttonStyle(.glass)
    }
}

/// Inline status with the standard iconography and color per severity.
struct InlineNotice: View {
    enum Kind {
        case success, info, warning, failure

        var symbol: String {
            switch self {
            case .success: "checkmark.seal.fill"
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle.fill"
            case .failure: "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: Palette.success
            case .info: Palette.subtext
            case .warning: Palette.warning
            case .failure: Palette.danger
            }
        }
    }

    let kind: Kind
    let text: String

    var body: some View {
        Label(text, systemImage: kind.symbol)
            .font(Typography.label)
            .foregroundStyle(kind.tint)
    }
}

/// Fine print under a form: the privacy line, a hint.
struct FootnoteText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Palette.subtext)
    }
}

/// A person, as initials until image loading lands.
///
/// The frame is `@ScaledMetric` so avatars grow with Dynamic Type. A fixed
/// 34pt circle beside 40pt text reads as broken; the whole row has to scale
/// together or the alignment falls apart at accessibility sizes.
struct AvatarView: View {
    let name: String
    var picture: String?

    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = Sizing.avatar

    /// Loaded through the community's loader rather than `AsyncImage`.
    ///
    /// `AsyncImage` was here and was wrong: an avatar set from inside Buzz
    /// lives on the community's own membership-gated Blossom server, so the
    /// unauthenticated GET returned 401 and the picture silently never
    /// appeared. Anyone who set their photo in Buzz showed up as a letter,
    /// which looked like the app simply having no avatars.
    @Environment(\.mediaLoader) private var mediaLoader
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
                    // The same edge the letter version carries. Without it a
                    // photo avatar was full-saturation photography dropped
                    // beside flat badges, and read as belonging to a
                    // different app.
                    .overlay(Circle().strokeBorder(Palette.glyphHairline, lineWidth: 0.75))
                    .transition(.opacity)
            } else {
                // The stand-in while loading, and forever if the URL is dead.
                // A broken-image glyph would be worse than the initial it
                // replaces.
                initial.glyphChrome(size: size)
            }
        }
        .animation(Motion.fast, value: image == nil)
        // A face is not information: the row's label already says who spoke.
        .accessibilityHidden(true)
        .task(id: picture) { await load() }
    }

    private func load() async {
        image = nil
        guard let url = pictureURL, let mediaLoader else { return }
        image = try? await mediaLoader.avatar(at: url)
    }

    /// Exactly ChannelGlyph's treatment in a circle: the same lift, the same
    /// hairline, the same chartreuse mark. A room and a person are the same
    /// object wearing two shapes, and the shape is the only thing that should
    /// tell them apart.
    private var initial: some View {
        ZStack {
            Circle().fill(Palette.glyphLift)
            Circle().stroke(Palette.glyphHairline, lineWidth: 0.75)
            Text(name.prefix(1).uppercased())
                // Sized off the circle rather than the type ramp, matching the
                // symbol in ChannelGlyph, so a letter and an icon sit at the
                // same optical weight at every size a caller asks for.
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Palette.glyphMark)
                .minimumScaleFactor(0.7)
        }
    }

    /// https, or an inlined `data:` picture. Never http: a profile can name
    /// any URL it likes, and an http avatar would be a cleartext request made
    /// on the viewer's behalf. `data:` fetches nothing, so it carries none of
    /// that risk, and some clients inline the whole image in the kind 0.
    private var pictureURL: URL? {
        guard let picture, let url = URL(string: picture),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "data"
        else { return nil }
        return url
    }
}

/// The standard screen backdrop: the Buzz gradient, edge to edge.
struct Backdrop<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Palette.backgroundGradient.ignoresSafeArea()
            content()
        }
    }
}


// MARK: - Form styling

/// The house style for every `Form`-based screen.
///
/// A `Form`'s default row fill is an opaque system grey that fights the brand
/// gradient behind it. This hides that fill, paints the gradient, and gives
/// each row a Liquid Glass background instead, so rows read as floating on the
/// gradient rather than as grey slabs laid over it.
///
/// One modifier, one place to tune: changing the row treatment restyles every
/// screen at once.
struct CombFormStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Palette.backgroundGradient.ignoresSafeArea())
            .softScrollEdges()
    }
}

extension View {
    /// Soft scroll edges, top and bottom, on every scrolling screen.
    ///
    /// Content dissolves under the bars instead of being cut by a hard line,
    /// which matters here more than in most apps: every screen sits on the
    /// gradient, and a hard clip edge against it reads as a seam.
    func softScrollEdges() -> some View {
        scrollEdgeEffectStyle(.soft, for: .all)
    }
}

extension View {
    /// Applies Comb's form styling: brand gradient behind a transparent list.
    func combForm() -> some View {
        modifier(CombFormStyle())
    }

    /// The row treatment: a luminance lift that keeps the gradient's own hue.
    ///
    /// A grey fill over a coloured backdrop always reads washed out, because
    /// the grey is a literal grey fighting the hue behind it. White at low
    /// opacity is a pure lightness shift, so the row stays olive at the top of
    /// the screen and blue at the bottom, exactly like the gradient it sits on.
    /// The hairline does the same job for the edge.
    ///
    /// Applied per `Section`, because SwiftUI only honours `listRowBackground`
    /// on row content: setting it on the `Form` itself silently does nothing.
    func combRows() -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: Radii.bubble)
                .fill(Palette.liftOnGradient)
                .overlay(
                    RoundedRectangle(cornerRadius: Radii.bubble)
                        .strokeBorder(Palette.hairlineOnGradient, lineWidth: 0.5)
                )
        )
    }

    /// The glyph treatment, shared by channel cells and avatars so the two
    /// read as one family.
    ///
    /// Deliberately opaque, with no blend. Blending a badge into the light
    /// behind it looks better in isolation and fails in a list: the gradient
    /// runs olive to blue down the screen, so a column of avatars inherits a
    /// different colour per row and reads as a dozen unrelated tints rather
    /// than one repeated element. A fixed fill is the same everywhere, which
    /// is what a repeated element needs to be.
    func glyphChrome(size: CGFloat) -> some View {
        compositingGroup()
            .frame(width: size, height: size)
    }

    /// The capsule chip: a luminance lift in a pill, for tags, date breaks,
    /// and any other small floating label on the gradient. One modifier so
    /// the treatment cannot be re-derived slightly differently per screen.
    func combChip() -> some View {
        padding(.horizontal, Space.xs)
            .padding(.vertical, Space.hairline)
            .background(Palette.liftOnGradient, in: .capsule)
            .overlay(
                Capsule().strokeBorder(Palette.hairlineOnGradient, lineWidth: 0.5)
            )
            .luminousChrome()
    }
}


// MARK: - Chrome over the gradient

/// Makes controls and secondary text sit *in* the gradient rather than on top
/// of it, by blending rather than compositing flat.
///
/// Grey chrome over a coloured backdrop reads as dead: the grey is a literal
/// grey, so it fights the hue behind it instead of belonging to it.
/// `plusLighter` adds the source to the destination, so light content glows
/// through and picks up the backdrop's colour. It is the treatment Apple uses
/// for overlay chrome on media.
///
/// The blend has to invert with the appearance: `plusLighter` on a light
/// background blows out to white, so light mode gets `plusDarker`, which is the
/// same idea in the other direction.
struct LuminousChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.blendMode(scheme == .dark ? .plusLighter : .plusDarker)
    }
}

extension View {
    /// Blends chrome into the gradient instead of laying it flat on top.
    /// For toolbar glyphs, secondary text, and separators over the backdrop.
    func luminousChrome() -> some View {
        modifier(LuminousChrome())
    }
}


// MARK: - Connection

/// Tells the user when the app is not actually connected.
///
/// Without this a dropped socket looks identical to a healthy one: messages
/// simply stop arriving and nothing explains why. It appears only when there is
/// something to say, so a working connection stays silent.
struct ConnectionBanner: View {
    let state: ConnectionState

    var body: some View {
        if let message {
            HStack(spacing: Space.xs) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Palette.ink)
                Text(message)
                    .font(Typography.label)
                    .foregroundStyle(Palette.ink)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity)
            .background(Palette.chartreuse)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel(message)
        }
    }

    /// Silent when connected: a banner that is always there stops being read.
    private var message: String? {
        switch state {
        case .ready, .idle: nil
        case .connecting, .authenticating: "Connecting…"
        case .reconnecting(let attempt):
            attempt <= 1 ? "Reconnecting…" : "Reconnecting, attempt \(attempt)…"
        case .stopped: "Offline"
        }
    }
}
