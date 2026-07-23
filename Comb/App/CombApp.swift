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
private struct LaunchingView: View {
    @State private var isBreathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Backdrop {
            Mark()
                .frame(width: Sizing.heroMark, height: Sizing.heroMark)
                .opacity(isBreathing ? 1 : 0.6)
                // A forever-repeating pulse is exactly what Reduce Motion is
                // for; the mark simply sits still instead.
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: isBreathing
                )
        }
        .accessibilityLabel("Opening Comb")
        .onAppear { isBreathing = !reduceMotion }
    }
}
