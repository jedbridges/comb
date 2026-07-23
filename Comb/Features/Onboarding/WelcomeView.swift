import SwiftUI
import UIKit

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
    /// Whether the clipboard probably holds a link, checked with
    /// `detectedPatterns`, which reports the presence of a URL without reading
    /// it, so no system paste banner. The most likely reason a first-time user
    /// opens Comb is an invite someone just sent them; if it is sitting on the
    /// clipboard, the fastest path in should be one tap, offered, not sprung.
    @State private var clipboardHasLink = false

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
                            Text("Join a Buzz community")
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

                        // Browse leads, because it is the one door a newcomer
                        // with nothing in hand can always walk through. The old
                        // primary was "I have an invite link", which shouted
                        // loudest at exactly the person least able to act on it:
                        // someone who found Comb without an invite tapped the
                        // brightest button into a flow they could not finish.
                        // "Find" rather than "Browse": the affirmative verb
                        // frames a beginning, not a catalogue.
                        PrimaryButton(title: "Find a community") {
                            path.append(.browse)
                        }

                        // The invite door, and one door only. When the
                        // clipboard probably holds a link, this same slot
                        // becomes its smarter self: it reads the clipboard on
                        // tap (the system paste prompt is the user's own
                        // action) and arrives at the join screen prefilled.
                        // A separate shortcut chip was tried above the primary
                        // and cut: it sat an inch from this button meaning
                        // nearly the same thing, and two doors to one room is
                        // exactly the choice overhead this screen exists to
                        // avoid.
                        if clipboardHasLink {
                            SecondaryButton(title: "Join from your copied link") {
                                guard let text = UIPasteboard.general.string,
                                      !text.trimmingCharacters(in: .whitespaces).isEmpty
                                else {
                                    // The clipboard changed since detection;
                                    // fall back to the plain join screen.
                                    path.append(.enterInvite)
                                    return
                                }
                                // Same route a deep link takes: join screen,
                                // invite prefilled. A copied link that is not
                                // an invite gets that screen's own correction.
                                pendingInvite = text
                            }
                        } else {
                            SecondaryButton(title: "I have an invite link") {
                                path.append(.enterInvite)
                            }
                        }

                        // Last, but legible. The question reads as prose in
                        // white; only the action itself carries the accent, so
                        // the tappable part is the part that glows.
                        //
                        // "Pair this phone", not "sign in with your key": the
                        // person this line is for already runs Buzz on a
                        // desktop, and pairing is their own vocabulary for
                        // exactly this act. "Key" is accurate and colder, and
                        // it lives one screen deeper for whoever needs it.
                        Button {
                            path.append(.signIn)
                        } label: {
                            // Interpolated rather than `Text + Text`, which is
                            // deprecated on iOS 26.
                            Text("Already on Buzz? \(Text("Pair this phone").foregroundStyle(Palette.chartreuse))")
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
            .task {
                // Presence only, never content: detection reports that a URL
                // is probably there without reading the clipboard, so no
                // system banner. The read happens on tap or not at all.
                let patterns = try? await UIPasteboard.general
                    .detectedPatterns(for: [\.probableWebURL])
                withAnimation(Motion.standard) {
                    clipboardHasLink = patterns?.contains(\.probableWebURL) == true
                }
            }
            .onChange(of: pendingInvite) { _, invite in
                guard invite != nil else { return }
                path = [.enterInvite]
            }
        }
    }
}
