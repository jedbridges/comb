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
                // Ink only earns its place on the chartreuse fill. Disabled,
                // the style drops the fill to dim glass, and ink on dim glass
                // is black on dark: the label has to switch with the
                // background it sits on.
                .textRole(.action, isInactive ? .muted : .onBrand)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xxs)
        }
        .buttonStyle(.glassProminent)
        .tint(Palette.chartreuse)
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
                .font(Typography.control)
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

        var tone: TextTone {
            switch self {
            case .success: .success
            case .info: .muted
            case .warning: .warning
            case .failure: .danger
            }
        }
    }

    let kind: Kind
    let text: String

    var body: some View {
        Label(text, systemImage: kind.symbol)
            .labelStyle(.compact)
            .textRole(.supportStrong, kind.tone)
    }
}

/// Symbol and text set at reading distance from each other.
///
/// A `Label` in a `Form` reserves an icon column wide enough to align the
/// symbols of every row beneath it. That is right in Settings and wrong for a
/// lone status line, where it strands the badge from the words it modifies.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xxs) {
            configuration.icon
            configuration.title
        }
    }
}

extension LabelStyle where Self == CompactLabelStyle {
    static var compact: CompactLabelStyle { CompactLabelStyle() }
}

/// A checkbox, for consent rows where a switch overpromises.
///
/// A switch is for a setting you will come back and change. An agreement is
/// answered once, on the way past, and a row of full-size switches gives two
/// sentences the visual weight of a settings screen. iOS ships no checkbox
/// style, so this is drawn by hand, but it stays a real `Toggle`: VoiceOver
/// still announces a switch with an on/off value, and the whole row stays the
/// hit target rather than just the mark.
///
/// Checked is `success`, not `chartreuse`. Chartreuse belongs to the one
/// primary action on a screen, and on the join screen that is already spent on
/// the button and the links.
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .textRole(.body, configuration.isOn ? .success : .muted)
                    // The mark carries the state, so it is the only thing that
                    // moves. Animating the label would read as the sentence
                    // changing rather than the answer.
                    .animation(Motion.instant, value: configuration.isOn)

                configuration.label
                    .textRole(.body)

                Spacer(minLength: 0)
            }
            // The mark is small on purpose, but the target must not be. A
            // single-line agreement is about 20pt of text, so without this the
            // row is less than half Apple's minimum.
            .frame(minHeight: Sizing.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

extension ToggleStyle where Self == CheckboxToggleStyle {
    static var checkbox: CheckboxToggleStyle { CheckboxToggleStyle() }
}

/// A person, as initials until image loading lands.
///
/// The frame is `@ScaledMetric` so avatars grow with Dynamic Type. A fixed
/// 34pt circle beside 40pt text reads as broken; the whole row has to scale
/// together or the alignment falls apart at accessibility sizes.
struct AvatarView: View {
    let name: String
    var picture: String?
    var pubkey: String?
    var isOnline = false

    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = Sizing.avatar
    @Environment(\.presenceMonitor) private var presenceMonitor: PresenceMonitor?

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
                    .overlay(Circle().strokeBorder(Palette.glyphHairline, lineWidth: Stroke.hairline))
                    .transition(.opacity)
            } else {
                // The stand-in while loading, and forever if the URL is dead.
                // A broken-image glyph would be worse than the initial it
                // replaces.
                initial.glyphChrome(size: size)
            }
        }
        .animation(Motion.fast, value: image == nil)
        .overlay(alignment: .bottomTrailing) {
            if showOnline {
                Circle()
                    .fill(Palette.chartreuse)
                    .frame(width: size * 0.27, height: size * 0.27)
                    .overlay(
                        Circle().strokeBorder(Palette.ink, lineWidth: Stroke.hairline * 2)
                    )
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Online")
            }
        }
        .animation(Motion.fast, value: showOnline)
        .accessibilityHidden(!showOnline)
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
            Circle().stroke(Palette.glyphHairline, lineWidth: Stroke.hairline)
            Text(name.prefix(1).uppercased())
                // Sized off the circle rather than the type ramp, matching the
                // symbol in ChannelGlyph, so a letter and an icon sit at the
                // same optical weight at every size a caller asks for.
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Palette.glyphMark)
                .minimumScaleFactor(0.7)
        }
    }

    private var showOnline: Bool {
        isOnline || (pubkey.flatMap { presenceMonitor?.isOnline($0) } ?? false)
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

/// A transient confirmation, floating over content and gone in a few seconds.
///
/// For actions whose result is off-screen: setting a reminder, or being told
/// notifications are off. An alert would demand a tap to dismiss something the
/// person does not need to acknowledge, and silence would leave them unsure
/// the action landed.
///
/// The contract is the important part, and it is narrow: a toast is for an
/// outcome nobody has to act on. A failure that has a next step belongs in an
/// `InlineNotice` beside the control, or in a `confirmationDialog` that offers
/// the step. Present it with `.toast(_:)` rather than by hand, so every screen
/// gets the same placement, the same dwell, and the same announcement.
struct Toast: View {
    let text: String

    var body: some View {
        Text(text)
            .textRole(.supportStrong, .primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .background(.ultraThinMaterial, in: .capsule)
            .overlay(Capsule().strokeBorder(Palette.hairlineOnGradient, lineWidth: Stroke.fine))
            .padding(.horizontal, Space.xl)
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Something to say once, carrying its own identity.
///
/// Identity rather than a bare `String` because the same failure happening
/// twice is two events, and SwiftUI cannot see the difference between "set to
/// the same text again" and "never changed". With a plain string the second of
/// two identical failures neither re-announces nor restarts the clock: it
/// inherits whatever is left of the first one's and vanishes early.
struct ToastMessage: Equatable, Sendable {
    /// Whether this is news or bad news. The words differ either way; the tone
    /// is what decides how it feels, so a reminder being set cannot arrive with
    /// the same buzz as a message that failed to send.
    enum Tone: Sendable {
        case neutral
        case failure
    }

    let text: String
    let tone: Tone
    private let id = UUID()

    init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// One toast, presented the same way everywhere.
///
/// Written as a modifier because the presentation is four decisions that must
/// not drift between screens: where it sits, how long it stays, how it moves,
/// and the fact that it is spoken. Hand-rolling it in each view is how the
/// second copy silently loses the fourth.
private struct ToastPresenter: ViewModifier {
    @Binding var message: ToastMessage?

    /// Long enough to read a sentence, short enough not to sit over the
    /// compose bar while someone is typing the next thing.
    private static let dwell = Duration.seconds(3)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Toast(text: message.text)
                        .padding(.bottom, Space.xxxl)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.standard, value: message)
            // Owned here rather than at each call site, so a screen cannot
            // present a toast and forget the feeling that goes with it, and so
            // good news never arrives with the buzz of bad.
            .sensoryFeedback(trigger: message) { _, new in
                guard new?.tone == .failure else { return nil }
                return Haptics.failure
            }
            .task(id: message) {
                guard let message else { return }
                // VoiceOver does not move focus to an overlay that appears
                // without being asked, so without this the toast is silent to
                // the people least able to notice it visually.
                AccessibilityNotification.Announcement(message.text).post()
                try? await Task.sleep(for: Self.dwell)
                // Only clears what it presented. A toast raised while this one
                // was on screen has already replaced `message`, and the sleep
                // it started owns the dismissal from here.
                if self.message == message { self.message = nil }
            }
    }
}

extension View {
    /// Presents `message` as a toast, then clears it.
    func toast(_ message: Binding<ToastMessage?>) -> some View {
        modifier(ToastPresenter(message: message))
    }
}

/// A Form row label: accent icon, ordinary text.
///
/// Exists because a `Button`'s label inherits the accent colour for the whole
/// label, while a `NavigationLink`'s tints only the icon. Two rows written the
/// same way in the same section therefore came out different colours, and the
/// usual fix, forcing `foregroundStyle` on the Button's label, drags the icon
/// to the text colour instead. Setting both explicitly is the only way they
/// match.
struct RowLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            Text(title).foregroundStyle(Palette.text)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Palette.chartreuse)
        }
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
                        .strokeBorder(Palette.hairlineOnGradient, lineWidth: Stroke.fine)
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
    ///
    /// The lift is a fill, and stops there. It used to end in a `plusLighter`
    /// blend, and that made one component render as three going down a single
    /// screen: the same date pill was bright olive under the navigation bar,
    /// muted in the middle, and cold at the bottom, because the blend adds
    /// whatever the gradient happens to be doing behind it. The fill alone
    /// already picks up the backdrop's hue, which was the point; the blend was
    /// only ever adding light on top of that.
    func combChip() -> some View {
        padding(.horizontal, Space.xs)
            .padding(.vertical, Space.hairline)
            .background(Palette.liftOnGradient, in: .capsule)
            .overlay(
                Capsule().strokeBorder(Palette.hairlineOnGradient, lineWidth: Stroke.fine)
            )
    }

    /// The tally capsule that rides under a message: a glyph and a number that
    /// counts something other people did.
    ///
    /// Extracted on the second use, per DESIGN.md. Reactions and zaps are
    /// different counts of the same shape, and the shape is the part that must
    /// not be re-derived: the lift fill exists because a literal grey fights the
    /// gradient's hue instead of belonging to it, and that reasoning is not
    /// specific to either one.
    ///
    /// `isMine` takes the solid brand fill, so a pile you have joined reads as
    /// decided. Only reactions pass true. A zap chip stays lifted whatever its
    /// total, and marks the reader's own with a brand-coloured glyph instead:
    /// a bubble can already carry a chartreuse reaction pill, and DESIGN.md's
    /// rule is that three accents on a screen means one of them is wrong.
    func tallyChip(isMine: Bool) -> some View {
        padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
            .background(
                isMine
                    ? AnyShapeStyle(Palette.chartreuse)
                    : AnyShapeStyle(Palette.glyphLift),
                in: .capsule
            )
            .overlay {
                if !isMine {
                    Capsule().strokeBorder(Palette.glyphHairline, lineWidth: Stroke.hairline)
                }
            }
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

    /// Held back for a moment before appearing.
    ///
    /// The banner sits in a top safe-area inset, so showing it pushes the
    /// whole screen down and hiding it pulls the screen back up. A healthy
    /// launch passes through `connecting` for a few hundred milliseconds, and
    /// the list visibly jumped down and back for no reason a reader could
    /// name. A connection that resolves faster than this now says nothing at
    /// all, which is what a working connection should say.
    @State private var isDue = false

    private static let grace = Duration.milliseconds(700)

    var body: some View {
        content
            .task(id: message) {
                guard message != nil else {
                    isDue = false
                    return
                }
                try? await Task.sleep(for: Self.grace)
                isDue = true
            }
    }

    @ViewBuilder private var content: some View {
        if let message, isDue {
            HStack(spacing: Space.xs) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Palette.ink)
                Text(message)
                    .textRole(.supportStrong, .onBrand)
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
