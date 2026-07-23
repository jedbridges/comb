import CombNet
import SwiftUI

@main
struct CombApp: App {
    @State private var model = AppModel()
    @State private var pendingInvite: String?

    var body: some Scene {
        WindowGroup {
            Group {
                switch model.stage {
                case .launching:
                    LaunchingView()
                case .welcome:
                    WelcomeView(
                        notice: model.launchNotice,
                        onJoined: { model.adopt($0, landingInBusiestChannel: true) },
                        pendingInvite: $pendingInvite
                    )
                case .active(let session):
                    NavigationStack {
                        ChannelListView(
                            session: session,
                            openOnArrival: model.openOnArrival,
                            onArrivalConsumed: { model.consumeArrivalChannel() },
                            communities: model.communities,
                            onSwitch: { community in
                                Task { await model.openCommunity(community) }
                            },
                            onAddCommunity: {
                                Task { await model.addCommunity() }
                            },
                            onJoined: { model.adopt($0, landingInBusiestChannel: true) },
                            onDisconnect: {
                                Task { await model.signOut() }
                            }
                        )
                    }
                }
            }
            .task { await model.bootstrap() }
            .onOpenURL { url in
                // buzz:// and comb:// join links. Only honoured before a
                // community is open; multi-community switching is later work.
                guard InviteLink.parse(url.absoluteString) != nil,
                      case .welcome = model.stage
                else { return }
                pendingInvite = url.absoluteString
            }
        }
    }
}

/// The instant between launch and knowing whether a community opens silently.
///
/// One orchestrated entrance rather than scattered effects, on the same
/// arrival curve as everything else in the app: a bloom of the brand colour
/// wakes the gradient, the icon settles into place through it with a slight
/// overshoot, and the wordmark resolves underneath. If the session opens
/// quickly the whole thing is a subliminal flash of brand; if the relay is
/// slow, a gentle breath keeps the screen alive without nagging.
private struct LaunchingView: View {
    @State private var phase: Phase = .void
    @State private var isBreathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase {
        /// Nothing yet: the gradient alone, for one beat.
        case void
        /// The icon lands and the bloom opens.
        case landed
    }

    var body: some View {
        Backdrop {
            ZStack {
                // The bloom: chartreuse light opening behind the icon, blended
                // into the gradient the way all chrome is, so it reads as the
                // background waking up rather than a sticker of glow.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Palette.chartreuse.opacity(0.45), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: Sizing.heroMark * 2.2
                        )
                    )
                    .frame(width: Sizing.heroMark * 4.4, height: Sizing.heroMark * 4.4)
                    .luminousChrome()
                    .scaleEffect(phase == .landed ? 1 : 0.4)
                    .opacity(phase == .landed ? 1 : 0)

                VStack(spacing: Space.md) {
                    // The same artwork as the app icon, so launch, icon and
                    // cold start read as one identity. The drawn Mark remains
                    // only as WelcomeSymbol's fallback.
                    WelcomeSymbol()
                        .frame(width: Sizing.heroMark, height: Sizing.heroMark)
                        .scaleEffect(iconScale)
                        .opacity(phase == .landed ? 1 : 0)
                        .blur(radius: phase == .landed ? 0 : Motion.arrivalBlur * 3)

                    Text(verbatim: "comb")
                        .font(Typography.display)
                        .kerning(Kerning.display)
                        .foregroundStyle(Palette.text)
                        .arrival(phase == .landed, delay: 0.25)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Opening Comb")
        .task {
            guard !reduceMotion else {
                // The composed entrance collapses to a plain fade; the breath
                // never starts. Stillness is the accessible version, not a
                // lesser one.
                withAnimation(.easeOut(duration: 0.2)) { phase = .landed }
                return
            }

            // One beat of just the gradient makes the landing an event instead
            // of a state the app booted into.
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.spring(duration: 0.55, bounce: 0.28)) { phase = .landed }

            // If we are still here after the entrance, the relay is slow:
            // settle into a quiet breath so the screen reads as alive.
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
    }

    /// Lands with a spring overshoot, then breathes at ±2% if kept waiting.
    private var iconScale: CGFloat {
        guard phase == .landed else { return 0.62 }
        return isBreathing ? 1.02 : 1
    }
}
