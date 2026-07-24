import CombStore
import SwiftUI

/// Everyone hidden on this device, and the way back.
///
/// A block has to be reversible from somewhere the person can find, or it is a
/// trap rather than a tool. Nothing here is published: this list exists only on
/// this iPhone, and the people on it are never told.
struct BlockedListView: View {
    let session: CommunitySession

    @State private var blocked: [BlockedPerson] = []

    var body: some View {
        Group {
            if blocked.isEmpty {
                ContentUnavailableView(
                    "No one is blocked",
                    systemImage: "hand.raised",
                    description: Text("Blocking someone hides their messages here. You can undo it from this screen.")
                )
            } else {
                list
            }
        }
        .background(Palette.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Observation only fails if the database does, which the app
            // cannot recover from mid-flight; the list stops updating rather
            // than crashing, matching every other observed screen.
            do {
                for try await people in session.store.observeBlocked() {
                    blocked = people
                }
            } catch {}
        }
    }

    private var list: some View {
        Form {
            Section {
                ForEach(blocked) { person in
                    HStack(spacing: Space.sm) {
                        AvatarView(name: person.name, picture: person.picture)
                        Text(person.name)
                            .font(Typography.name)
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Unblock") {
                            Task { try? await session.store.unblock(pubkey: person.pubkey) }
                        }
                        .font(Typography.actionSecondary)
                        .buttonStyle(.glass)
                    }
                }
            } footer: {
                Text("Their messages come back as soon as you unblock them. Nothing was deleted.")
            }
            .combRows()
        }
        .combForm()
    }
}
