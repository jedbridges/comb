import SwiftUI

/// The cold-start screen. One promise governs everything reachable from here:
/// the words key, npub, nsec, pubkey, and seed appear nowhere. A first-time
/// user joins a community and sends a message without learning what any of
/// those are.
struct WelcomeView: View {
    let notice: String?
    let onJoined: (CommunitySession) -> Void

    /// An invite that arrived by deep link jumps straight into the join flow.
    @Binding var pendingInvite: String?

    @State private var path: [Destination] = []

    enum Destination: Hashable {
        case enterInvite
        case browse
        case restore
    }

    var body: some View {
        NavigationStack(path: $path) {
            Backdrop {
                // Bees over the gradient, behind everything readable.
                BeeSwarmView()
                    .ignoresSafeArea()

                // Centred, deliberately. An asymmetric version was tried and
                // read worse: the identity block wants the optical centre, and
                // pushing it to a corner only opened a hole in the middle of
                // the screen. The composition work that stuck is the staggered
                // arrival below.
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: Space.md) {
                        WelcomeSymbol()
                            .frame(width: Sizing.heroMark, height: Sizing.heroMark)
                            .arrival(true)

                        VStack(spacing: Space.xxs) {
                            // Lowercase as a wordmark, not a sentence: the app
                            // is still called Comb everywhere it is prose.
                            Text(verbatim: "comb")
                                .font(Typography.display)
                                .kerning(Kerning.display)
                                .foregroundStyle(Palette.text)
                                .accessibilityLabel("Comb")
                            Text("Join a community.")
                                .font(Typography.secondary)
                                .foregroundStyle(Palette.subtext)
                        }
                        .arrival(true, delay: 0.08)
                    }

                    Spacer()

                    VStack(spacing: Space.sm) {
                        if let notice {
                            InlineNotice(kind: .warning, text: notice)
                                .multilineTextAlignment(.center)
                        }

                        PrimaryButton(title: "I have an invite link") {
                            path.append(.enterInvite)
                        }

                        SecondaryButton(title: "Browse communities") {
                            path.append(.browse)
                        }

                        // Last, but legible. The question reads as prose in
                        // white; only the action itself carries the accent, so
                        // the tappable part is the part that glows.
                        Button {
                            path.append(.restore)
                        } label: {
                            // Interpolated rather than `Text + Text`, which is
                            // deprecated on iOS 26.
                            Text("Have an account? \(Text("Sign in with your key").foregroundStyle(Palette.chartreuse))")
                                .foregroundStyle(Palette.text)
                        }
                        .font(Typography.actionSecondary)
                        .padding(.top, Space.sm)
                        .frame(minHeight: Sizing.hitTarget)
                    }
                    // Last in the stagger: the eye lands on the identity, then
                    // the way in.
                    .arrival(true, delay: 0.16)
                    .padding(.horizontal, Space.xl)
                    .padding(.bottom, Space.xxxl)
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .enterInvite:
                    JoinView(prefilledInvite: pendingInvite, onJoined: onJoined)
                case .browse:
                    BrowseView(onJoined: onJoined)
                case .restore:
                    RestoreView(onRestored: onJoined)
                }
            }
            .onChange(of: pendingInvite) { _, invite in
                guard invite != nil else { return }
                path = [.enterInvite]
            }
        }
    }
}
