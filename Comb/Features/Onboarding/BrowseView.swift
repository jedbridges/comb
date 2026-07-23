import CombNet
import SwiftUI

/// Community discovery, from the index the protocol refuses to provide.
///
/// Entries come from `communities/index.json` in the Comb repository: a
/// bundled seed instantly, the live copy over TLS behind it. Entries are never
/// auto-joined; a tap flows into the same join screen as a pasted invite.
///
/// What the index can honestly offer: Buzz invites are relay-minted tokens
/// with a 30-day ceiling, so a static file cannot hold a forever-valid join
/// link. An entry either carries a live invite URL its operator keeps fresh,
/// or it is a listing: proof the community exists, what it is about, and its
/// address, with the invite arriving from a member. Both are shown, labelled
/// truthfully.
struct BrowseView: View {
    let onJoined: (CommunitySession) -> Void

    @State private var entries: [CommunityIndex.Entry] = []
    @State private var hasLoaded = false
    @State private var selectedInvite: String?
    @State private var order: Order = .newest

    /// Every sort the data can truthfully support. Member counts and activity
    /// are deliberately hidden by the relays, so recency of listing, name, and
    /// joinability are the meaningful axes that exist.
    enum Order: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case name = "Name"
        case joinable = "Open to join"

        var id: String { rawValue }
    }

    private var sorted: [CommunityIndex.Entry] {
        switch order {
        case .newest:
            // Descending by listed date, undated entries last, ties by name.
            entries.sorted {
                ($0.listedAt ?? "") == ($1.listedAt ?? "")
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : ($0.listedAt ?? "") > ($1.listedAt ?? "")
            }
        case .name:
            entries.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .joinable:
            entries.sorted {
                $0.isJoinableNow == $1.isJoinableNow
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : $0.isJoinableNow
            }
        }
    }

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
        }
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

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $order) {
                ForEach(Order.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(Typography.actionSecondary)
                .foregroundStyle(Palette.text)
                .luminousChrome()
        }
        .accessibilityLabel("Sort communities")
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: Space.md) {
                GlassCard(padding: Space.xs) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(sorted.enumerated()), id: \.element.id) { index, entry in
                            row(entry)
                                .arrival(true, delay: Double(min(index, 8)) * 0.04)
                            if entry.id != sorted.last?.id {
                                Divider().overlay(Palette.border.opacity(0.5))
                            }
                        }
                    }
                }

                listYourCommunity
            }
            .padding(Space.lg)
        }
        .softScrollEdges()
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
                if !entry.tags.isEmpty {
                    Text(entry.tags.joined(separator: " · "))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.subtext.opacity(0.8))
                        .luminousChrome()
                }
            }

            Spacer(minLength: Space.xs)

            // The affordance stays honest to what the relay will allow.
            if entry.isJoinableNow {
                Button("Join") {
                    selectedInvite = entry.join.url?.absoluteString ?? ""
                }
                .font(Typography.actionSecondary)
                .buttonStyle(.glass)
            } else {
                Text("Invite only")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.subtext)
            }
        }
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.xs)
        .accessibilityElement(children: .combine)
    }

    /// The growth loop, and deliberately loud: every listed community makes
    /// this screen worth opening for the next person.
    private var listYourCommunity: some View {
        VStack(spacing: Space.sm) {
            Text("Run a community?")
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.text)
            Text("Add it to this list so people can find it. Listing is a small change to a public file, and takes a few minutes.")
                .font(Typography.secondary)
                .foregroundStyle(Palette.subtext)
                .multilineTextAlignment(.center)

            // Safari, deliberately: listing is a pull request, and pretending
            // it can happen inside the app would be a lie with a spinner.
            Link(destination: URL(string: "https://github.com/jedbridges/comb/edit/main/communities/index.json")!) {
                Text("List your community")
                    .font(Typography.action)
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: Sizing.hitTarget)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.chartreuse)
        }
        .padding(Space.md)
    }

    /// A dead end otherwise: it says to get an invite link and then offers no
    /// way to use one. The button is the whole point of the state.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No communities listed yet", systemImage: "square.grid.2x2")
        } description: {
            Text("Communities show up here once they add themselves to Comb's public index. Most are invite only.")
        } actions: {
            Button("I have an invite link") {
                // Empty rather than nil: nil means "no destination" to
                // `navigationDestination(item:)`, so this opens the join
                // screen with the field blank and focused.
                selectedInvite = ""
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.chartreuse)
            .foregroundStyle(Palette.ink)
        }
        .arrival(true)
    }

    /// The seed shipped inside the app, so first launch has content offline.
    private static var bundledIndex: Data? {
        Bundle.main.url(forResource: "index", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
    }
}
