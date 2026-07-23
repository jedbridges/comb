import CombNet
import SwiftUI
import UserNotifications

@main
struct CombApp: App {
    @State private var model = AppModel()
    @State private var pendingInvite: String?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must run before launch finishes, per BGTaskScheduler. Registering the
        // handler is free; whether a wake is ever scheduled depends on the
        // notification toggle.
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            stageView
            .task { await model.bootstrap() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    // Opening the app is the moment the badge is certainly
                    // stale: the user is now looking at the unread it counted.
                    Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
                case .background:
                    // Line up the next check as we leave, so a fresh wake is
                    // always pending while notifications are on.
                    BackgroundRefresh.schedule()
                default:
                    break
                }
            }
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

    @ViewBuilder private var stageView: some View {
        switch model.stage {
                case .launching:
                    LaunchingView()
                case .welcome:
                    WelcomeView(
                        notice: model.launchNotice,
                        onJoined: { model.adopt($0, landingInBusiestChannel: true) },
                        onSignedIn: { model.adopt($0) },
                        pendingInvite: $pendingInvite
                    )
                case .active(let session):
                    CommunityRoot(session: session, model: model, pendingInvite: $pendingInvite)
        }
    }
}

/// The open community, and the one place its media loader is created.
///
/// A separate view purely so the loader can live in `@State`: built inline in
/// `CombApp.body` it would be replaced on every re-evaluation, which throws
/// away the image caches on any state change at all. One loader per community
/// also means the timeline, the member list, and every avatar sheet share a
/// cache instead of each keeping their own.
private struct CommunityRoot: View {
    let session: CommunitySession
    let model: AppModel
    @Binding var pendingInvite: String?

    @State private var loader: MediaLoader

    init(session: CommunitySession, model: AppModel, pendingInvite: Binding<String?>) {
        self.session = session
        self.model = model
        _pendingInvite = pendingInvite
        _loader = State(initialValue: MediaLoader(session: session))
    }

    var body: some View {
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
        .environment(\.mediaLoader, loader)
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
