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
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: Space.md) {
                        Mark().frame(width: Sizing.heroMark, height: Sizing.heroMark)
                        Text("Comb")
                            .font(Typography.display)
                            .kerning(Kerning.display)
                            .foregroundStyle(Palette.text)
                        Text("Join a community.")
                            .font(Typography.secondary)
                            .foregroundStyle(Palette.subtext)
                    }
                    .arrival(true)

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

                        // Deliberately small and last: this is the door for
                        // people who already live in this world, and a
                        // first-time user's eye should slide past it.
                        Button("Already have an account? Restore it") {
                            path.append(.restore)
                        }
                        .font(Typography.label)
                        .foregroundStyle(Palette.subtext)
                        .padding(.top, Space.xs)
                    }
                    .arrival(true, delay: 0.1)
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
