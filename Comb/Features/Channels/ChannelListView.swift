import CombStore
import SwiftUI

/// The community's channels, live from the store.
struct ChannelListView: View {
    let session: CommunitySession
    let onDisconnect: () -> Void

    @State private var model: ChannelListModel
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
                Button("Disconnect", action: onDisconnect)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.subtext)
            }
        }
        .navigationDestination(for: ChannelSummary.self) { channel in
            ChannelTimelineView(session: session, channel: channel)
        }
        .task { await model.activate() }
        #if DEBUG
        .onChange(of: model.channels) { _, channels in
            if LaunchFlags.opensFirstChannel, autoOpened == nil, let first = channels.first {
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
                            .padding(.leading, 60)
                    }
                }
            }
            .padding(.vertical, 6)
            .glassEffect(in: .rect(cornerRadius: 16))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Mark().frame(width: 48, height: 48).opacity(0.5)
            Text("No channels yet")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.subtext)
        }
    }
}

/// One channel: name, member count, last message preview.
private struct ChannelRow: View {
    let channel: ChannelSummary

    var body: some View {
        HStack(spacing: 12) {
            cell

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(channel.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let when = channel.lastActivityDate {
                        Text(when, format: .relative(presentation: .named))
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.subtext)
                    }
                }

                HStack(spacing: 4) {
                    if let preview {
                        Text(preview)
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.subtext)
                            .lineLimit(1)
                    } else {
                        Text("No messages yet")
                            .font(.system(size: 14).italic())
                            .foregroundStyle(Palette.subtext.opacity(0.7))
                    }

                    Spacer(minLength: 8)

                    if channel.memberCount > 0 {
                        Label("\(channel.memberCount)", systemImage: "person.2")
                            .font(.system(size: 11).monospacedDigit())
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Palette.subtext.opacity(0.8))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            Mark().frame(width: 38, height: 38).opacity(0.9)
            Text(channel.name.prefix(1).uppercased())
                .font(.system(size: 15, weight: .bold))
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
