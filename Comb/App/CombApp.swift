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
                            onJoined: { model.adopt($0, landingInBusiestChannel: true) },
                            pendingInvite: $pendingInvite,
                            onDisconnect: {
                                Task { await model.signOut() }
                            }
                        )
                    }
                }
            }
            .task { await model.bootstrap() }
            .onOpenURL { url in
                // buzz:// and comb:// join links, honoured in either stage:
                // signed out they open the welcome join flow, signed in they
                // present the join sheet over the open community. Silently
                // ignoring a tapped invite is never the right answer.
                guard InviteLink.parse(url.absoluteString) != nil else { return }
                pendingInvite = url.absoluteString
            }
        }
    }
}

/// The instant between launch and knowing whether a community opens silently.
///
/// One entrance, flat and quick: the icon lands with a single spring, the
/// wordmark resolves underneath. If the session opens quickly the whole thing
/// is a subliminal flash of brand; if the relay is slow, a gentle breath keeps
/// the screen alive without nagging.
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
            // Flat and quick: the icon lands with one spring, the wordmark
            // resolves under it, nothing else. A glow bloom was tried here and
            // cut as decoration; the artwork carries the moment on its own.
            VStack(spacing: Space.md) {
                // The same artwork as the app icon, so launch, icon and cold
                // start read as one identity. The drawn Mark remains only as
                // WelcomeSymbol's fallback.
                WelcomeSymbol()
                    .frame(width: Sizing.heroMark, height: Sizing.heroMark)
                    .scaleEffect(iconScale)
                    .opacity(phase == .landed ? 1 : 0)

                Text(verbatim: "comb")
                    .font(Typography.display)
                    .kerning(Kerning.display)
                    .foregroundStyle(Palette.text)
                    .arrival(phase == .landed, delay: 0.12)
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

            withAnimation(.spring(duration: 0.4, bounce: 0.22)) { phase = .landed }

            // If we are still here after the entrance, the relay is slow:
            // settle into a quiet breath so the screen reads as alive.
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
    }

    /// Lands with a small spring overshoot, then breathes at ±2% if kept
    /// waiting on a slow relay.
    private var iconScale: CGFloat {
        guard phase == .landed else { return 0.85 }
        return isBreathing ? 1.02 : 1
    }
}
