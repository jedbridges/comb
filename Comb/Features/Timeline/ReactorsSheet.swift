import CombStore
import SwiftUI

/// Who reacted to a message, grouped by emoji.
///
/// Reached by long-pressing a reaction chip. Every emoji on the message is
/// here, not just the one pressed, because "who else reacted at all" is
/// usually the real question and answering it should not cost a second
/// gesture. The pressed emoji leads, so the press is still honoured.
struct ReactorsSheet: View {
    let session: CommunitySession
    let messageID: String
    /// The chip that was pressed. Its group is shown first.
    let focusedEmoji: String

    @Environment(\.dismiss) private var dismiss
    @State private var groups: [ReactionGroup] = []
    @State private var selected: ProfileTarget?

    /// The pressed emoji first, everything else behind it in count order.
    private var ordered: [ReactionGroup] {
        guard let index = groups.firstIndex(where: { $0.emoji == focusedEmoji }) else {
            return groups
        }
        var ordered = groups
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    // Only reachable if every reaction was withdrawn between
                    // the press and the sheet opening.
                    ContentUnavailableView(
                        "No reactions",
                        systemImage: "face.smiling",
                        description: Text("These were taken back.")
                    )
                } else {
                    list
                }
            }
            .background(Palette.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Reactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            groups = (try? session.store.reactors(for: messageID)) ?? []
        }
        .sheet(item: $selected) { target in
            ProfileSheet(session: session, pubkey: target.pubkey)
        }
    }

    private var list: some View {
        Form {
            ForEach(ordered) { group in
                Section {
                    ForEach(group.reactors) { reactor in
                        Button {
                            selected = ProfileTarget(pubkey: reactor.pubkey)
                        } label: {
                            HStack(spacing: Space.sm) {
                                AvatarView(name: reactor.name, picture: reactor.picture)
                                Text(reactor.name)
                                    .font(Typography.name)
                                    .foregroundStyle(Palette.text)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens their profile")
                    }
                } header: {
                    HStack(spacing: Space.xs) {
                        Text(group.emoji)
                            .font(Typography.emoji)
                        Text("\(group.reactors.count)")
                            .font(Typography.count)
                            .foregroundStyle(Palette.subtext)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(group.reactors.count) reacted with \(group.emoji)")
                }
                .combRows()
            }
        }
        .combForm()
    }
}
