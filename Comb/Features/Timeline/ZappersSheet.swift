import CombStore
import SwiftUI

/// Who zapped a message, and what the number does and does not mean.
///
/// Reached by long-pressing the zap chip. This is where the honesty about zap
/// totals lives, rather than as a permanent caption under every chip: the
/// limitations are real and worth stating once, where someone looking at the
/// number closely will find them, in the same register as the "what is a zap?"
/// popover on the send sheet. Reachable, not recited.
struct ZappersSheet: View {
    let session: CommunitySession
    let messageID: String

    @Environment(\.dismiss) private var dismiss
    @State private var zappers: [Zapper] = []
    @State private var selected: ProfileTarget?

    private var totalSats: Int64 {
        zappers.reduce(0) { $0 + $1.amountMillisats } / 1000
    }

    var body: some View {
        NavigationStack {
            Group {
                if zappers.isEmpty {
                    ContentUnavailableView(
                        "No zaps yet",
                        systemImage: "bolt",
                        description: Text("Comb has not seen a receipt for this message.")
                    )
                } else {
                    list
                }
            }
            .background(Palette.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Zaps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            zappers = (try? session.store.zappers(for: messageID)) ?? []
        }
        .sheet(item: $selected) { target in
            ProfileSheet(session: session, pubkey: target.pubkey)
        }
    }

    private var list: some View {
        Form {
            Section {
                ForEach(zappers) { zapper in
                    Button {
                        selected = ProfileTarget(pubkey: zapper.pubkey)
                    } label: {
                        row(zapper)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens their profile")
                }
            } header: {
                Text("\(totalSats.formatted()) sats from \(zappers.count == 1 ? "1 person" : "\(zappers.count) people")")
            } footer: {
                // Three sentences, three separate limitations. None of them is
                // fixable in a client, so all three are said plainly rather
                // than softened into one vague caveat.
                Text("Zaps are counted from receipts published by recipients' wallets. Comb only sees the receipts this relay sends it, so the real total can be higher. A receipt says a wallet issued an invoice for a signed request; it does not prove the invoice was paid.")
            }
            .combRows()
        }
        .combForm()
    }

    private func row(_ zapper: Zapper) -> some View {
        HStack(spacing: Space.sm) {
            AvatarView(name: zapper.name, picture: zapper.picture)

            VStack(alignment: .leading, spacing: Space.hairline) {
                Text(zapper.name)
                    .textRole(.bodyStrong)
                    .lineLimit(1)
                if !zapper.comment.isEmpty {
                    Text(zapper.comment)
                        .textRole(.support)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            Text("\(zapper.amountSats.formatted())")
                .textRole(.count)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(zapper.name), \(zapper.amountSats) sats")
    }
}
