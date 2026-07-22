import CombStore
import SwiftUI

/// The community's channels, live from the store.
struct ChannelListView: View {
    let session: CommunitySession
    let onDisconnect: () -> Void

    @State private var model: ChannelListModel
    @State private var isShowingSettings = false
    #if DEBUG
    @State private var autoOpened: ChannelSummary?
    #endif

    init(session: CommunitySession, onDisconnect: @escaping () -> Void) {
        self.session = session
        self.onDisconnect = onDisconnect
        _model = State(initialValue: ChannelListModel(store: session.store))
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
        .navigationTitle("Channels")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(Typography.actionSecondary)
                        .foregroundStyle(Palette.subtext)
                }
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
        VStack(spacing: 12) {
            Mark().frame(width: Sizing.inlineMark, height: Sizing.inlineMark).opacity(0.5)
            Text("No channels yet")
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.subtext)
        }
    }
}

/// One channel: name, member count, last message preview.
private struct ChannelRow: View {
    let channel: ChannelSummary

    var body: some View {
        HStack(spacing: Space.sm) {
            cell

            VStack(alignment: .leading, spacing: Space.hairline) {
                HStack(alignment: .firstTextBaseline) {
                    Text(channel.name)
                        .font(Typography.name)
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)

                    Spacer(minLength: Space.xs)

                    if let when = channel.lastActivityDate {
                        Text(when, format: .relative(presentation: .named))
                            .font(Typography.caption)
                            .foregroundStyle(Palette.subtext)
                    }
                }

                HStack(spacing: Space.xxs) {
                    if let preview {
                        Text(preview)
                            .font(Typography.secondary)
                            .foregroundStyle(Palette.subtext)
                            .lineLimit(1)
                    } else {
                        Text("No messages yet")
                            .font(Typography.secondary.italic())
                            .foregroundStyle(Palette.subtext.opacity(0.7))
                    }

                    Spacer(minLength: Space.xs)

                    if channel.memberCount > 0 {
                        Label("\(channel.memberCount)", systemImage: "person.2")
                            .font(Typography.count)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Palette.subtext.opacity(0.8))
                    }
                }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .contentShape(.rect)
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

    /// A comb cell with the channel's initial. Channel icons come later;
    /// this keeps rows scannable until then.
    private var cell: some View {
        ZStack {
            Mark().frame(width: Sizing.channelCell, height: Sizing.channelCell).opacity(0.9)
            Text(channel.name.prefix(1).uppercased())
                .font(Typography.name)
                .foregroundStyle(Palette.chartreuse)
        }
    }
}

/// Feeds the channel list from store observation. No polling, no socket.
@MainActor
@Observable
final class ChannelListModel {
    private(set) var channels: [ChannelSummary] = []
    private let store: EventStore

    init(store: EventStore) {
        self.store = store
    }

    func activate() async {
        do {
            for try await summaries in store.observeChannelSummaries() {
                channels = summaries
            }
        } catch {
            // Observation only fails if the database does, which the app
            // cannot recover from mid-flight. The list simply stops updating.
        }
    }
}
