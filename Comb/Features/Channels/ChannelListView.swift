import CombNet
import CombStore
import SwiftUI

/// The community's channels, live from the store.
struct ChannelListView: View {
    let session: CommunitySession
    let onDisconnect: () -> Void
    /// Every community on this device, and how to move between them. Buzz
    /// cannot supply this list: it lives locally, exactly as Buzz's own desktop
    /// client keeps it in localStorage.
    var communities: [JoinedCommunity] = []
    var onSwitch: (JoinedCommunity) -> Void = { _ in }
    var onAddCommunity: () -> Void = {}

    @State private var model: ChannelListModel
    @State private var isShowingSettings = false
    @State private var connection: ConnectionState = .idle
    #if DEBUG
    @State private var autoOpened: ChannelSummary?
    #endif

    init(
        session: CommunitySession,
        communities: [JoinedCommunity] = [],
        onSwitch: @escaping (JoinedCommunity) -> Void = { _ in },
        onAddCommunity: @escaping () -> Void = {},
        onDisconnect: @escaping () -> Void
    ) {
        self.session = session
        self.communities = communities
        self.onSwitch = onSwitch
        self.onAddCommunity = onAddCommunity
        self.onDisconnect = onDisconnect
        _model = State(initialValue: ChannelListModel(
            store: session.store,
            me: session.me.hex
        ))
    }

    /// The open community's name, derived from its host.
    private var currentName: String {
        JoinedCommunity.derivedName(from: session.relayURL.host ?? "")
    }

    var body: some View {
        ZStack {
            Palette.backgroundGradient.ignoresSafeArea()

            if model.channels.isEmpty {
                emptyState
            } else {
                channelList
            }
        }
        .safeAreaInset(edge: .top) {
            ConnectionBanner(state: connection)
                .animation(Motion.standard, value: connection)
        }
        .task {
            for await state in await session.connectionStates() {
                connection = state
            }
        }
        .navigationTitle(currentName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                communityMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(Typography.actionSecondary)
                        .foregroundStyle(Palette.text)
                        .luminousChrome()
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(session: session, onSignOut: onDisconnect)
        }
        .navigationDestination(for: ChannelSummary.self) { channel in
            ChannelTimelineView(session: session, channel: channel)
        }
        .task { await model.activate() }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--open-settings") {
                isShowingSettings = true
            }
        }
        .onChange(of: model.channels) { _, channels in
            if AppModel.LaunchFlags.opensFirstChannel, autoOpened == nil, let first = channels.first {
                autoOpened = first
            }
        }
        .navigationDestination(item: $autoOpened) { channel in
            ChannelTimelineView(session: session, channel: channel)
        }
        #endif
    }

    /// Switching and adding. A menu rather than a sheet: the list is short, and
    /// this is a jump between places, not a task.
    private var communityMenu: some View {
        Menu {
            if communities.count > 1 {
                Section("Communities") {
                    ForEach(communities) { community in
                        Button {
                            onSwitch(community)
                        } label: {
                            if community.host == session.relayURL.host {
                                Label(community.displayName, systemImage: "checkmark")
                            } else {
                                Text(community.displayName)
                            }
                        }
                    }
                }
            }
            Button("Add community", systemImage: "plus", action: onAddCommunity)
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(Typography.actionSecondary)
                .foregroundStyle(Palette.text)
                .luminousChrome()
        }
        .accessibilityLabel("Communities")
        .accessibilityHint("Switch between communities or add another")
    }

    private var channelList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.channels.enumerated()), id: \.element.id) { index, channel in
                    NavigationLink(value: channel) {
                        ChannelRow(channel: channel)
                    }
                    .buttonStyle(.plain)
                    .arrival(true, delay: Double(min(index, 8)) * 0.04)

                    if channel.id != model.channels.last?.id {
                        Divider()
                            .overlay(Palette.border.opacity(0.5))
                            .padding(.leading, Space.md + Sizing.channelCell + Space.xs)
                    }
                }
            }
            .padding(.vertical, Space.xxs)
            .glassEffect(in: .rect(cornerRadius: Radii.card))
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Mark()
                .frame(width: Sizing.inlineMark, height: Sizing.inlineMark)
                .opacity(0.5)
                .accessibilityHidden(true)
            Text("No channels yet")
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.text)
            Text("Channels appear here as soon as this community shares them.")
                .font(Typography.secondary)
                .foregroundStyle(Palette.subtext)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
        }
    }
}

/// One channel: name, member count, last message preview.
private struct ChannelRow: View {
    let channel: ChannelSummary

    @ScaledMetric(relativeTo: .subheadline) private var cellSize: CGFloat = Sizing.channelCell

    var body: some View {
        HStack(spacing: Space.sm) {
            cell

            VStack(alignment: .leading, spacing: Space.hairline) {
                HStack(alignment: .firstTextBaseline) {
                    Text(channel.name)
                        // Unread channels carry more weight, which is the
                        // scanning cue: you should find what is new without
                        // reading a single word.
                        .font(channel.hasUnread ? Typography.bodyEmphasis : Typography.name)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)

                    Spacer(minLength: Space.xs)

                    if let when = channel.lastActivityDate {
                        Text(when, format: .relative(presentation: .named))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.subtext)
                            .luminousChrome()
                    }
                }

                HStack(spacing: Space.xxs) {
                    if let preview {
                        Text(preview)
                            .font(Typography.secondary)
                            .foregroundStyle(channel.hasUnread ? Palette.text : Palette.subtext)
                            .lineLimit(1)
                    } else {
                        Text("No messages yet")
                            .font(Typography.secondary.italic())
                            .foregroundStyle(Palette.subtext.opacity(0.7))
                    }

                    Spacer(minLength: Space.xs)

                    if channel.hasUnread {
                        UnreadBadge(count: channel.unreadCount)
                    } else if channel.memberCount > 0 {
                        Label("\(channel.memberCount)", systemImage: "person.2")
                            .font(Typography.count)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Palette.subtext)
                            .luminousChrome()
                    }
                }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [channel.name]
        if channel.hasUnread {
            parts.append("\(channel.unreadCount) unread")
        }
        if channel.memberCount > 0 { parts.append("\(channel.memberCount) members") }
        if let preview { parts.append("Latest: \(preview)") }
        else { parts.append("No messages yet") }
        return parts.joined(separator: ", ")
    }

    private var preview: String? {
        guard let message = channel.lastMessage else { return nil }
        let flattened = message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return nil }
        if let author = channel.lastAuthor, !author.isEmpty {
            return "\(author): \(flattened)"
        }
        return flattened
    }

    /// A rounded comb cell carrying a symbol chosen from the channel's name.
    /// An initial only repeats the title beside it; a symbol says what the
    /// room is for.
    private var cell: some View {
        ChannelGlyph(name: channel.name, size: cellSize)
    }
}

/// The count of what is new, in the brand's one loud colour.
private struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(Typography.count)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 2)
            .background(Palette.chartreuse, in: .capsule)
            // Chartreuse earns its place here: "what is new" is the most
            // important thing on this screen.
            .accessibilityHidden(true)
    }
}

/// Feeds the channel list from store observation. No polling, no socket.
@MainActor
@Observable
final class ChannelListModel {
    private(set) var channels: [ChannelSummary] = []
    private let store: EventStore
    private let me: String

    init(store: EventStore, me: String) {
        self.store = store
        self.me = me
    }

    func activate() async {
        do {
            for try await summaries in store.observeChannelSummaries(me: me) {
                channels = summaries
            }
        } catch {
            // Observation only fails if the database does, which the app
            // cannot recover from mid-flight. The list simply stops updating.
        }
    }
}
