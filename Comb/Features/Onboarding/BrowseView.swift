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
    @State private var joinRequest: JoinRequest?

    /// What the join screen needs to know about where the tap came from.
    struct JoinRequest: Hashable, Identifiable {
        let invite: String
        let communityName: String?
        let communityDescription: String?
        var id: String { invite + (communityName ?? "") }
    }
    @State private var order: Order = .newest
    @State private var query = ""
    @Environment(\.openURL) private var openURL

    /// The index file, opened for editing on GitHub.
    private static let listingURL = URL(
        string: "https://github.com/jedbridges/comb/edit/main/communities/index.json"
    )!

    /// Every sort the data can truthfully support. Member counts and activity
    /// are deliberately hidden by the relays, so recency of listing, name, and
    /// joinability are the meaningful axes that exist.
    enum Order: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case name = "Name"
        case joinable = "Open to join"

        var id: String { rawValue }
    }

    /// Entries matching the search, across every field a person might
    /// remember: name, what it is about, and its tags.
    private var matching: [CommunityIndex.Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            entry.name.localizedCaseInsensitiveContains(needle)
                || entry.description?.localizedCaseInsensitiveContains(needle) == true
                || entry.tags.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var sorted: [CommunityIndex.Entry] {
        switch order {
        case .newest:
            // Descending by listed date, undated entries last, ties by name.
            matching.sorted {
                ($0.listedAt ?? "") == ($1.listedAt ?? "")
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : ($0.listedAt ?? "") > ($1.listedAt ?? "")
            }
        case .name:
            matching.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .joinable:
            matching.sorted {
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
                } else if sorted.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    list
                }
            }
        }
        .navigationTitle("Communities")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search communities")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
        }
        .navigationDestination(item: $joinRequest) { request in
            JoinView(
                prefilledInvite: request.invite.isEmpty ? nil : request.invite,
                communityName: request.communityName,
                communityDescription: request.communityDescription,
                onJoined: onJoined
            )
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
                .foregroundStyle(Palette.chrome)
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
                    HStack(spacing: Space.xxs) {
                        ForEach(entry.tags, id: \.self) { tag in
                            Text(tag)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.subtext)
                                .combChip()
                        }
                    }
                    .padding(.top, Space.xxs)
                    // One element: VoiceOver reads "bitcoin, lightning" rather
                    // than walking each pill.
                    .accessibilityElement(children: .combine)
                }
            }

            Spacer(minLength: Space.xs)

            // The affordance stays honest to what the relay will allow.
            if entry.isJoinableNow {
                Button("Join") {
                    joinRequest = JoinRequest(
                        invite: entry.join.url?.absoluteString ?? "",
                        communityName: entry.name,
                        communityDescription: entry.description
                    )
                }
                .font(Typography.actionSecondary)
                .buttonStyle(.glass)
            } else {
                // A chevron, not just grey text. "Invite only" alone read as a
                // locked door, but the row leads somewhere useful: the join
                // screen, which now shows the community and says how to get in.
                // The affordance has to promise that.
                HStack(spacing: Space.xxs) {
                    Text("Invite only")
                        .font(Typography.caption)
                    Image(systemName: "chevron.right")
                        .font(Typography.icon)
                }
                .foregroundStyle(Palette.subtext)
            }
        }
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.xs)
        .contentShape(.rect)
        // The whole row leads somewhere either way. A dead row under a finger
        // reads as broken; an invite-only community opens the join screen,
        // where the field is waiting for the invite a member sends.
        .onTapGesture {
            joinRequest = JoinRequest(
                invite: entry.isJoinableNow ? (entry.join.url?.absoluteString ?? "") : "",
                communityName: entry.name,
                communityDescription: entry.description
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(
            entry.isJoinableNow ? "Joins this community" : "Invite only. Opens the join screen."
        )
    }

    /// The growth loop, and deliberately loud: every listed community makes
    /// this screen worth opening for the next person.
    private var listYourCommunity: some View {
        GlassCard(padding: Space.md) {
            listYourCommunityContent
        }
    }

    private var listYourCommunityContent: some View {
        VStack(spacing: Space.sm) {
            Text("Run a community?")
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.text)
            // Says exactly what the button does and where it goes: out to
            // GitHub, add your name and address, submit. No mystery about
            // leaving the app or what happens after the tap.
            Text("Get it listed here. The button opens this list on GitHub: add your community's name and address, then submit the change.")
                .font(Typography.secondary)
                .foregroundStyle(Palette.subtext)
                .multilineTextAlignment(.center)

            // Safari, deliberately: listing is a pull request, and pretending
            // it can happen inside the app would be a lie with a spinner.
            //
            // PrimaryButton rather than a hand-rolled Link: this is the one
            // important action on the screen, and it should be exactly the
            // size and weight of the primary action on every other screen.
            PrimaryButton(title: "List your community") {
                openURL(Self.listingURL)
            }
        }
        // No extra padding: the GlassCard wrapping this supplies it.
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
                joinRequest = JoinRequest(invite: "", communityName: nil, communityDescription: nil)
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
