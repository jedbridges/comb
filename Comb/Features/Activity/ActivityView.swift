import CombCore
import CombStore
import SwiftUI

/// Everything addressed to you, across every channel.
///
/// The channel list answers "where is there anything new". This answers the
/// narrower question people actually open an app for: what of it was meant for
/// me. Mentions already wake a notification; replies and reactions to your own
/// messages had nowhere to be seen at all.
///
/// Not a feed. The order is the order things happened, there is nothing
/// promoted, and nothing here was chosen for you.
struct ActivityView: View {
    let session: CommunitySession
    /// Opens the message an item is about, in the community it belongs to.
    ///
    /// The host travels with the target because an item may well be from a
    /// community that is not the open one, and switching first is the whole
    /// difference between routing and guessing.
    let onOpen: (MessageLink.Target, String) -> Void

    @State private var model: ActivityModel
    @Environment(\.dismiss) private var dismiss

    init(
        session: CommunitySession,
        onOpen: @escaping (MessageLink.Target, String) -> Void
    ) {
        self.session = session
        self.onOpen = onOpen
        _model = State(initialValue: ActivityModel(session: session))
    }

    var body: some View {
        Group {
            if model.items.isEmpty && model.hasLoaded {
                empty
            } else {
                list
            }
        }
        .background(Palette.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .font(Typography.actionSecondary)
                    .foregroundStyle(Palette.chrome)
            }
        }
        .task { await model.activate() }
    }

    private var list: some View {
        List(model.items) { entry in
            Button {
                onOpen(
                    MessageLink.Target(
                        channelID: entry.item.channelID,
                        messageID: entry.item.targetID,
                        threadRootID: nil
                    ),
                    entry.host
                )
                dismiss()
            } label: {
                ActivityRow(
                    item: entry.item,
                    // Named only when there is more than one community in the
                    // list. On a device with a single community it would be the
                    // same word on every row, which is noise rather than
                    // context.
                    community: model.spansCommunities ? entry.communityName : nil
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var empty: some View {
        // Says what would appear here rather than that there is nothing, so an
        // empty screen reads as a state and not as a failure to load.
        ContentUnavailableView {
            Label("Nothing yet", systemImage: "bell")
        } description: {
            Text("Mentions, replies to you, and reactions to your messages show up here.")
        }
    }
}

/// One thing that happened, said in a sentence.
private struct ActivityRow: View {
    let item: ActivityItem
    /// Set only when the list spans more than one community.
    var community: String?

    /// The channel, prefixed by its community when there is more than one.
    /// Written as one string rather than two views so it wraps and truncates
    /// as the single piece of context it is.
    private var place: String {
        guard let community else { return item.channelName }
        return "\(community) · \(item.channelName)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            AvatarView(name: item.actorName, picture: item.actorPicture, pubkey: item.actorPubkey)

            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    headline

                    Spacer(minLength: Space.xxs)

                    Text(item.date, format: .relative(presentation: .named))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.subtext)
                        .lineLimit(1)
                        // Never squeezed: the headline is the part that can
                        // afford to truncate, and a half-written timestamp is
                        // worth less than a half-written name.
                        .layoutPriority(1)
                        .luminousChrome()
                }

                // The channel and then the message, or the emoji that landed on
                // it. Second, and quieter: the line above is what happened,
                // this is only what it happened to. The channel lives here
                // rather than in the headline, which had to truncate to hold
                // both a name and a room on a narrow screen.
                if item.kind == .reaction {
                    reactionLine
                } else {
                    Text("\(place)  \(item.text)")
                        .font(Typography.secondary)
                        .foregroundStyle(Palette.subtext)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, Space.xxs)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var headline: some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: symbol)
                .font(Typography.caption)
                .foregroundStyle(Palette.chartreuse)
            Text("\(item.actorName) \(verb)")
                .font(Typography.name)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
        }
    }

    private var reactionLine: some View {
        HStack(spacing: Space.xs) {
            if let url = item.emojiURL {
                CustomEmojiImage(url: url)
            } else {
                // Clamped like the timeline's chips, and for the same reason:
                // reaction content is written by anyone.
                Text(String(item.text.prefix(2)))
                    .font(Typography.emoji)
            }
            Text(place)
                .font(Typography.secondary)
                .foregroundStyle(Palette.subtext)
                .lineLimit(1)
        }
    }

    private var symbol: String {
        switch item.kind {
        case .mention: "at"
        case .reply: "arrowshape.turn.up.left"
        case .reaction: "heart"
        }
    }

    private var verb: String {
        switch item.kind {
        case .mention: "mentioned you"
        case .reply: "replied to you"
        case .reaction: "reacted to you"
        }
    }
}

/// One item, and which community it happened in.
struct CommunityActivity: Identifiable, Equatable {
    let item: ActivityItem
    let host: String
    let communityName: String

    /// Scoped by host: two communities can hold events with the same id, and
    /// an id alone would make SwiftUI treat them as one row.
    var id: String { "\(host)/\(item.id)" }
}

/// Feeds the activity list from every community this device has joined.
///
/// Deliberately not scoped to the community that happens to be open. "What was
/// addressed to me" is a question about a person, not about a room, and being
/// in the wrong community is exactly when you would most want to be told that
/// another one is waiting on you.
///
/// The stores stay separate, which is what makes this awkward and also what
/// makes it safe: one SQLite file per community, and a different identity in
/// each, because keys are held per host. So each community is asked about its
/// own pubkey, and the answers are merged here.
@MainActor
@Observable
final class ActivityModel {
    private(set) var items: [CommunityActivity] = []
    private(set) var hasLoaded = false
    /// Whether anything beyond the open community contributed, which decides
    /// whether a row needs to name where it came from.
    private(set) var spansCommunities = false

    private let session: CommunitySession
    /// Everything except the open community, read once when the screen opens.
    private var elsewhere: [CommunityActivity] = []

    init(session: CommunitySession) {
        self.session = session
    }

    /// Reads the other communities once, then follows the open one live.
    ///
    /// The split is on purpose. The community you are in is the one whose
    /// activity can change while you are looking at this screen, so it is worth
    /// an observation; the others are a snapshot of what was true when you
    /// opened it, which is what a list you read for ten seconds needs.
    func activate() async {
        elsewhere = await Self.loadOtherCommunities(excluding: session.relayURL.host ?? "")
        spansCommunities = !elsewhere.isEmpty

        let host = session.relayURL.host ?? ""
        let name = CommunityRegistry.all().first { $0.host == host }?.displayName ?? host

        do {
            for try await current in session.store.observeActivity(for: session.me.hex) {
                merge(current.map {
                    CommunityActivity(item: $0, host: host, communityName: name)
                })
                hasLoaded = true
            }
        } catch {
            // Observation only fails if the database does, which the app cannot
            // recover from mid-flight. Whatever was already read stays on
            // screen rather than being blanked.
            merge([])
            hasLoaded = true
        }
    }

    private func merge(_ current: [CommunityActivity]) {
        items = (current + elsewhere).sorted { $0.item.createdAt > $1.item.createdAt }
    }

    /// Opens each other community's store just long enough to ask it.
    ///
    /// Off the main actor, because this opens SQLite files and runs a union
    /// query against each. A community whose key has been removed is skipped
    /// rather than guessed at: without the right pubkey the question "what was
    /// addressed to me" has no answer, and answering it with somebody else's
    /// key would be worse than staying quiet.
    private nonisolated static func loadOtherCommunities(
        excluding openHost: String
    ) async -> [CommunityActivity] {
        let communities = await MainActor.run {
            CommunityRegistry.all().filter { $0.host != openHost }
        }
        guard !communities.isEmpty else { return [] }

        return await Task.detached(priority: .userInitiated) {
            var result: [CommunityActivity] = []
            for community in communities {
                guard let key = try? KeychainStore.load(host: community.host),
                      let store = try? CommunitySession.openStore(host: community.host),
                      let found = try? store.activity(for: key.publicKey.hex)
                else { continue }

                result.append(contentsOf: found.map {
                    CommunityActivity(
                        item: $0,
                        host: community.host,
                        communityName: community.displayName
                    )
                })
            }
            return result
        }.value
    }
}
