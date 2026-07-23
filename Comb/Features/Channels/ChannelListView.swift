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
    /// Set right after joining, so a new member lands in a conversation rather
    /// than on a list of mostly-empty rooms.
    var openOnArrival: ChannelSummary?
    var onArrivalConsumed: () -> Void = {}
    var communities: [JoinedCommunity] = []
    var onSwitch: (JoinedCommunity) -> Void = { _ in }
    /// A community joined from the in-app browse sheet, adopted without
    /// passing through the welcome flow.
    var onJoined: (CommunitySession) -> Void = { _ in }
    /// An invite link tapped while this community is open. Routes into the
    /// join sheet rather than being silently dropped.
    @Binding var pendingInvite: String?
    /// A message to open, from a deep link or a mention notification. Resolved
    /// to a channel and pushed, with the timeline scrolling to it.
    var pendingMessage: MessageLink.Target?
    var onMessageConsumed: () -> Void = {}

    @State private var model: ChannelListModel
    @State private var isShowingSettings = false
    @State private var connection: ConnectionState = .idle
    @State private var query = ""
    @State private var messageHits: [SearchResult] = []
    @State private var isBrowsing = false
    @State private var isAddingByInvite = false
    @State private var arrivalChannel: ChannelSummary?
    @State private var deepLink: DeepLinkChannel?

    /// A resolved deep-link destination: the channel to push, and the message
    /// to scroll to once it is on screen.
    struct DeepLinkChannel: Hashable, Identifiable {
        let channel: ChannelSummary
        let messageID: String
        var id: String { channel.id + messageID }
    }

    init(
        session: CommunitySession,
        openOnArrival: ChannelSummary? = nil,
        onArrivalConsumed: @escaping () -> Void = {},
        communities: [JoinedCommunity] = [],
        onSwitch: @escaping (JoinedCommunity) -> Void = { _ in },
        onJoined: @escaping (CommunitySession) -> Void = { _ in },
        pendingInvite: Binding<String?> = .constant(nil),
        pendingMessage: MessageLink.Target? = nil,
        onMessageConsumed: @escaping () -> Void = {},
        onDisconnect: @escaping () -> Void
    ) {
        self.session = session
        self.openOnArrival = openOnArrival
        self.onArrivalConsumed = onArrivalConsumed
        self.communities = communities
        self.onSwitch = onSwitch
        self.onJoined = onJoined
        self._pendingInvite = pendingInvite
        self.pendingMessage = pendingMessage
        self.onMessageConsumed = onMessageConsumed
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

            if !query.isEmpty {
                searchResults
            } else if !model.hasLoaded {
                // Nothing, deliberately. The store answers from disk in
                // milliseconds, so a spinner here would flash rather than
                // inform, and the empty state would be a lie for one frame.
                Color.clear
            } else if model.channels.isEmpty {
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
        // In place rather than behind a toolbar button and a sheet: search is
        // a way of looking at this screen's own contents, not a separate
        // place to go.
        .searchable(text: $query, prompt: "Search channels and messages")
        .onChange(of: query) { _, new in
            messageHits = (try? session.store.search(new)) ?? []
        }
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
                        .foregroundStyle(Palette.chrome)
                }
                .accessibilityLabel("Settings")
            }
        }
        // The same screen onboarding shows, one tap from anywhere: discovery
        // is not something you should have to sign out to reach.
        .sheet(isPresented: $isBrowsing) {
            NavigationStack {
                BrowseView(onJoined: { joined in
                    isBrowsing = false
                    onJoined(joined)
                })
            }
        }
        // A sheet over the current community, not a trip through the welcome
        // flow: adding a community must never look like being signed out of
        // the one you are in.
        .sheet(isPresented: $isAddingByInvite) {
            NavigationStack {
                JoinView(prefilledInvite: pendingInvite, onJoined: { joined in
                    isAddingByInvite = false
                    onJoined(joined)
                })
            }
        }
        .onChange(of: pendingInvite) { _, invite in
            guard invite != nil else { return }
            isAddingByInvite = true
        }
        .onChange(of: isAddingByInvite) { _, presented in
            if !presented { pendingInvite = nil }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(session: session, onSignOut: onDisconnect)
        }
        .navigationDestination(for: ChannelSummary.self) { channel in
            ChannelTimelineView(session: session, channel: channel)
        }
        .task { await model.activate() }
        // The single programmatic route into a channel: joining lands here, and
        // in DEBUG the screenshot flag reuses it. Declaring a second
        // navigationDestination for ChannelSummary would crash the stack.
        .navigationDestination(item: $arrivalChannel) { channel in
            ChannelTimelineView(session: session, channel: channel)
        }
        .navigationDestination(item: $deepLink) { link in
            ChannelTimelineView(
                session: session,
                channel: link.channel,
                scrollToMessageID: link.messageID
            )
        }
        .onAppear {
            guard let openOnArrival, arrivalChannel == nil else { return }
            arrivalChannel = openOnArrival
            onArrivalConsumed()
        }
        .onChange(of: pendingMessage) { _, target in
            resolveDeepLink(target)
        }
        .onChange(of: model.channels) { _, _ in
            // The channel may not have loaded when the link arrived on a cold
            // launch; retry the resolve once the list populates.
            if deepLink == nil { resolveDeepLink(pendingMessage) }
        }
        .task { resolveDeepLink(pendingMessage) }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--open-settings") {
                isShowingSettings = true
            }
        }
        .onChange(of: model.channels) { _, channels in
            if AppModel.LaunchFlags.opensFirstChannel, arrivalChannel == nil,
               let first = channels.first {
                arrivalChannel = first
            }
        }
        #endif
    }

    /// Turns a pending message target into a pushed channel, once the channel
    /// it names is known to the store.
    ///
    /// Best-effort by design: a link to a channel this device has never seen
    /// resolves to nothing rather than pushing an empty screen, and the target
    /// is consumed either way so a dead link does not retry forever. A pop back
    /// to a channel already showing the message is left alone.
    private func resolveDeepLink(_ target: MessageLink.Target?) {
        guard let target, deepLink == nil else { return }
        guard let channel = model.channels.first(where: { $0.id == target.channelID }) else {
            // The list has not loaded this channel yet. Leave the target
            // pending; the onChange(of: model.channels) above retries. Only
            // give up once the list has loaded and still lacks it.
            if model.hasLoaded {
                onMessageConsumed()
            }
            return
        }
        deepLink = DeepLinkChannel(channel: channel, messageID: target.messageID)
        onMessageConsumed()
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
            Button("Browse communities", systemImage: "square.grid.2x2") {
                isBrowsing = true
            }
            Button("I have an invite link", systemImage: "plus") {
                isAddingByInvite = true
            }
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(Typography.actionSecondary)
                .foregroundStyle(Palette.chrome)
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
        .softScrollEdges()
    }

    /// Channels whose name matches, and messages whose text does.
    private var matchingChannels: [ChannelSummary] {
        model.channels.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private var searchResults: some View {
        if matchingChannels.isEmpty && messageHits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.md) {
                    if !matchingChannels.isEmpty {
                        resultSection("Channels") {
                            ForEach(matchingChannels) { channel in
                                NavigationLink(value: channel) {
                                    ChannelRow(channel: channel)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !messageHits.isEmpty {
                        resultSection("Messages") {
                            ForEach(messageHits) { hit in
                                messageHitRow(hit)
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
            }
            .softScrollEdges()
        }
    }

    private func resultSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .font(Typography.eyebrow)
                .kerning(Kerning.eyebrow)
                .foregroundStyle(Palette.subtext)
                .padding(.leading, Space.xs)

            VStack(spacing: 0) { content() }
                .glassEffect(in: .rect(cornerRadius: Radii.card))
        }
    }

    private func messageHitRow(_ hit: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                Text(hit.channelName)
                    .font(Typography.eyebrow)
                    .kerning(Kerning.eyebrow)
                    .foregroundStyle(Palette.subtext)
                Spacer(minLength: Space.xs)
                Text(hit.date, format: .dateTime.month().day())
                    .font(Typography.caption)
                    .foregroundStyle(Palette.subtext)
            }
            Text(hit.content)
                .font(Typography.secondary)
                .foregroundStyle(Palette.text)
                .lineLimit(3)
            Text(hit.author)
                .font(Typography.caption)
                .foregroundStyle(Palette.subtext)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.sm)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            WelcomeSymbol()
                .frame(width: Sizing.inlineMark, height: Sizing.inlineMark)
                .opacity(0.5)
                .accessibilityHidden(true)
            Text("No channels yet")
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.text)
            Text("Channels will appear here once this community adds them.")
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

    /// How alive a channel is, which decides how much room its row takes.
    ///
    /// A list where every row has the same height and the same parts makes a
    /// dead channel look exactly like a busy one, and nine rooms that have
    /// never been used each repeat an identical "No messages yet". Giving the
    /// three states different shapes is what lets the eye find the conversation
    /// without reading anything.
    private enum Activity {
        /// Something new is waiting.
        case unread
        /// Has been talked in, and you are caught up.
        case settled
        /// Never used. Present so it can be opened, and otherwise out of the way.
        case quiet
    }

    private var activity: Activity {
        if channel.hasUnread { return .unread }
        return preview == nil ? .quiet : .settled
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            // Same size in every state, so the left edge stays a straight line
            // down the list and only the weight changes.
            ChannelGlyph(name: channel.name, size: cellSize)
                .opacity(activity == .quiet ? 0.45 : 1)

            VStack(alignment: .leading, spacing: Space.hairline) {
                titleLine
                // A quiet channel drops its second line entirely rather than
                // filling it with a sentence saying there is nothing to say.
                if activity != .quiet { previewLine }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, activity == .quiet ? Space.xs : Space.sm)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Name and trailing metadata, side by side while they fit and stacked
    /// once they do not.
    ///
    /// At accessibility text sizes the side-by-side version collapses badly:
    /// a channel name truncates to "wel…" while "10 hours ago" takes four
    /// lines beside it. `ViewThatFits` picks the stacked version instead, so
    /// the name stays readable and the metadata sits under it.
    private var titleLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                title
                Spacer(minLength: Space.xs)
                trailingMeta
            }

            VStack(alignment: .leading, spacing: Space.xxs) {
                title
                trailingMeta
            }
        }
    }

    private var title: some View {
        Text(channel.name)
            // Weight is the scanning cue: you should find what is new
            // without reading a single word.
            .font(activity == .unread ? Typography.bodyEmphasis : Typography.name)
            .foregroundStyle(activity == .quiet ? Palette.subtext : Palette.text)
            .lineLimit(1)
    }

    @ViewBuilder
    private var trailingMeta: some View {
        switch activity {
        case .unread, .settled:
            if let when = channel.lastActivityDate {
                Text(when, format: .relative(presentation: .named))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.subtext)
                    // One line always: a relative date that wraps to four
                    // lines is worse than one that is simply shorter.
                    .lineLimit(1)
                    .luminousChrome()
            }
        case .quiet:
            // With no second line, the member count rides up here rather
            // than costing the row another whole line of height.
            memberCount
        }
    }

    private var previewLine: some View {
        HStack(spacing: Space.xxs) {
            Text(preview ?? "")
                .font(Typography.secondary)
                .foregroundStyle(activity == .unread ? Palette.text : Palette.subtext)
                .lineLimit(1)

            Spacer(minLength: Space.xs)

            if channel.hasUnread {
                UnreadBadge(count: channel.unreadCount)
            } else {
                memberCount
            }
        }
    }

    /// Never wraps: a count split across two lines stops being a number.
    private var memberCountLabel: some View {
        Label("\(channel.memberCount)", systemImage: "person.2")
            .font(Typography.count)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder
    private var memberCount: some View {
        if channel.memberCount > 0 {
            memberCountLabel
                .foregroundStyle(Palette.subtext.opacity(activity == .quiet ? 0.7 : 1))
                .luminousChrome()
        }
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
            // Rolls as messages land, so a badge climbing while you watch
            // reads as activity rather than a redraw.
            .contentTransition(.numericText())
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.hairline)
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
    /// Whether the store has reported once.
    ///
    /// Without this the list rendered its empty state for the frame before the
    /// first snapshot arrived and then swapped to the real rows, which read as
    /// the screen rearranging itself on every open.
    private(set) var hasLoaded = false
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
                hasLoaded = true
            }
        } catch {
            // Observation only fails if the database does, which the app
            // cannot recover from mid-flight. The list simply stops updating.
        }
    }
}
