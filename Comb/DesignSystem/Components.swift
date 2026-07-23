import SwiftUI

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

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.action)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.xxs)
        }
        .buttonStyle(.glassProminent)
        .tint(Palette.chartreuse)
        .foregroundStyle(Palette.ink)
        .disabled(isBusy || isDisabled)
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

    var body: some View {
        ZStack {
            Circle().fill(Palette.surface.opacity(0.8))
            Text(name.prefix(1).uppercased())
                .font(Typography.name)
                .foregroundStyle(Palette.text)
                .minimumScaleFactor(0.7)
        }
        .frame(width: size, height: size)
        // The initial is a stand-in for a face, not information: the row's
        // label already says who spoke.
        .accessibilityHidden(true)
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
    }
}

extension View {
    /// Applies Comb's form styling: brand gradient behind a transparent list.
    func combForm() -> some View {
        modifier(CombFormStyle())
    }

    /// The translucent row treatment, so rows float on the gradient instead of
    /// sitting on opaque system grey.
    ///
    /// Applied per `Section`, because SwiftUI only honours `listRowBackground`
    /// on row content: setting it on the `Form` itself silently does nothing.
    func combRows() -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: Radii.bubble)
                .fill(Palette.surface.opacity(0.30))
        )
    }
}
