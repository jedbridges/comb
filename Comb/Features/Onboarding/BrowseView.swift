import CombNet
import SwiftUI

/// Community discovery, from the index the protocol refuses to provide.
///
/// Entries come from `communities/index.json` in the Comb repository: a
/// bundled seed instantly, the live copy over TLS behind it. Entries are never
/// auto-joined; a tap flows into the same join screen as a pasted invite.
struct BrowseView: View {
    let onJoined: (CommunitySession) -> Void

    @State private var entries: [CommunityIndex.Entry] = []
    @State private var hasLoaded = false
    @State private var selectedInvite: String?

    var body: some View {
        Backdrop {
            Group {
                if entries.isEmpty && hasLoaded {
                    emptyState
                } else {
                    list
                }
            }
        }
        .navigationTitle("Communities")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedInvite) { invite in
            JoinView(prefilledInvite: invite, onJoined: onJoined)
        }
        .task {
            let service = CommunityIndexService(bundledData: Self.bundledIndex)
            entries = service.seeded
            hasLoaded = true
            entries = await service.entries()
        }
    }

    private var list: some View {
        ScrollView {
            GlassCard(padding: Space.xs) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry)
                            .arrival(true, delay: Double(min(index, 8)) * 0.04)
                        if entry.id != entries.last?.id {
                            Divider().overlay(Palette.border.opacity(0.5))
                        }
                    }
                }
            }
            .padding(Space.lg)
        }
    }

    private func row(_ entry: CommunityIndex.Entry) -> some View {
        HStack(spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.hairline) {
                Text(entry.name)
                    .font(Typography.name)
                    .foregroundStyle(Palette.text)
                if let description = entry.description {
                    Text(description)
                        .font(Typography.secondary)
                        .foregroundStyle(Palette.subtext)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: Space.xs)

            // The join affordance stays honest to what the relay will allow.
            switch entry.join.kind {
            case "invite_url" where entry.join.url != nil:
                Button("Join") {
                    selectedInvite = entry.join.url?.absoluteString
                }
                .font(Typography.actionSecondary)
                .buttonStyle(.glass)
            default:
                Text("Invite only")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.subtext)
            }
        }
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.xs)
    }

    private var emptyState: some View {
        VStack(spacing: Space.md) {
            Mark()
                .frame(width: Sizing.inlineMark, height: Sizing.inlineMark)
                .opacity(0.5)
            Text("No communities listed yet")
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.text)
            Text("Communities appear here when they list themselves in Comb's public index. For now, ask yours for an invite link.")
                .font(Typography.secondary)
                .foregroundStyle(Palette.subtext)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xxl)
        }
        .arrival(true)
    }

    /// The seed shipped inside the app, so first launch has content offline.
    private static var bundledIndex: Data? {
        Bundle.main.url(forResource: "index", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
    }
}
