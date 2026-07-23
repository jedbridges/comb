import SwiftUI

/// The cold-start screen. One promise governs everything reachable from here:
/// the words key, npub, nsec, pubkey, and seed appear nowhere. A first-time
/// user joins a community and sends a message without learning what any of
/// those are.
struct WelcomeView: View {
    let notice: String?
    /// A brand new member. They land in the busiest channel, because a list of
    /// mostly-empty rooms is a worse first impression than a conversation
    /// already in progress.
    let onJoined: (CommunitySession) -> Void
    /// Someone returning to a community they already belong to. They land on
    /// the channel list: they know the place, and dropping them into whichever
    /// room happens to be loudest is a decision they did not ask for.
    let onSignedIn: (CommunitySession) -> Void

    /// An invite that arrived by deep link jumps straight into the join flow.
    @Binding var pendingInvite: String?

    @State private var path: [Destination] = []
    /// Flipped once, on the first frame, so the whole screen resolves into
    /// place instead of being painted already finished. Everything below reads
    /// from it, which is what makes the stagger a stagger.
    @State private var appeared = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Destination: Hashable {
        case enterInvite
        case browse
        case signIn
    }

    var body: some View {
        NavigationStack(path: $path) {
            Backdrop {
                // Bees over the gradient, behind everything readable, and
                // gathered around the mark rather than patrolling the whole
                // screen. 0.4 rather than 0.5: the identity block sits above
                // centre, and the swarm should orbit the mark, not the type.
                BeeSwarmView(hive: UnitPoint(x: 0.5, y: 0.4))
                    .ignoresSafeArea()
                    // The swarm gathers. It starts wide and invisible and
                    // draws in toward the mark over about a second, so the
                    // bees look like they flew in rather than like they were
                    // always sitting there. Slowest thing on screen, and last
                    // to finish, because atmosphere should settle after the
                    // content it surrounds.
                    .scaleEffect(appeared ? 1 : 1.2, anchor: UnitPoint(x: 0.5, y: 0.4))
                    .opacity(appeared ? 1 : 0)
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: 0.2)
                            : Motion.arrival.delay(0.2).speed(0.55),
                        value: appeared
                    )

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
                            // The one element that scales: a mark growing into
                            // place reads as the app introducing itself. Text
                            // doing the same would read as a zoom.
                            .arrival(appeared, from: 0.9)

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
                        .arrival(appeared, delay: 0.08)
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
                            path.append(.signIn)
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
                    .arrival(appeared, delay: 0.16)
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
                case .signIn:
                    SignInView(onSignedIn: onSignedIn)
                }
            }
            // First frame paints the screen still arriving; this commits the
            // resolved state, and the value-driven animations do the rest.
            // Idempotent, so popping back from Join does not replay it.
            .onAppear { appeared = true }
            .onChange(of: pendingInvite) { _, invite in
                guard invite != nil else { return }
                path = [.enterInvite]
            }
        }
    }
}
