import CombCore
import CombStore
import SwiftUI

/// A channel's conversation, newest at the bottom, read from the store.
struct ChannelTimelineView: View {
    let session: CommunitySession
    let channel: ChannelSummary

    @State private var model: ChannelTimeline
    @State private var draft = ""
    @State private var zapTarget: ChannelTimeline.Entry?

    init(session: CommunitySession, channel: ChannelSummary) {
        self.session = session
        self.channel = channel
        _model = State(initialValue: ChannelTimeline(session: session, channel: channel.id))
    }

    var body: some View {
        ZStack {
            Palette.backgroundGradient.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.hairline) {
                    if model.canLoadOlder {
                        loadOlderControl
                    }

                    // Rendered oldest to newest; the query returns newest first.
                    ForEach(model.displayRows) { entry in
                        MessageRow(
                            entry: entry,
                            reactions: model.snapshot.reactions[entry.row.id] ?? [],
                            onReact: { emoji in
                                Task { await model.toggleReaction(emoji, on: entry.row.id) }
                            },
                            onRetry: { Task { await model.retry(entry.row.id) } },
                            onDiscard: { Task { await model.discard(entry.row.id) } },
                            onZap: entry.row.authorLightningAddress == nil
                                ? nil
                                : { zapTarget = entry }
                        )
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.sm)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) {
            ComposeBar(draft: $draft) {
                let text = draft
                draft = ""
                Task { await model.send(text) }
            }
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if channel.memberCount > 0 {
                    Label("\(channel.memberCount)", systemImage: "person.2")
                        .font(Typography.count)
                        .foregroundStyle(Palette.text)
                        .luminousChrome()
                }
            }
        }
        .task { await model.activate() }
        .sheet(item: $zapTarget) { entry in
            if let address = entry.row.authorLightningAddress,
               let recipient = PublicKey(hex: entry.row.pubkey) {
                ZapSheet(
                    session: session,
                    recipient: recipient,
                    lightningAddress: address,
                    messageID: entry.row.id,
                    recipientName: entry.row.displayName
                )
            }
        }
    }

    private var loadOlderControl: some View {
        HStack {
            Spacer()
            Button {
                Task { await model.loadOlder() }
            } label: {
                if model.isLoadingOlder {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Earlier messages")
                        .font(Typography.label)
                }
            }
            .buttonStyle(.glass)
            .disabled(model.isLoadingOlder)
            Spacer()
        }
        .padding(.vertical, Space.xs)
    }
}

/// One message, with the author header shown only at the start of a run.
private struct MessageRow: View {
    let entry: ChannelTimeline.Entry
    let reactions: [ReactionSummary]
    let onReact: (String) -> Void
    let onRetry: () -> Void
    let onDiscard: () -> Void
    let onZap: (() -> Void)?

    /// The quick palette. A full picker is later polish.
    private static let quickReactions = ["🐝", "👍", "❤️", "🔥", "😂"]

    /// Matches AvatarView's scaled frame so continuation lines in a run stay
    /// aligned with the first at every text size.
    @ScaledMetric(relativeTo: .subheadline) private var avatarWidth: CGFloat = Sizing.avatar

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            if entry.showsHeader {
                AvatarView(name: entry.row.displayName, picture: entry.row.authorPicture)
            } else {
                Color.clear.frame(width: avatarWidth, height: 1)
            }

            VStack(alignment: .leading, spacing: Space.hairline) {
                if entry.showsHeader {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(entry.row.displayName)
                            .font(Typography.name)
                            .foregroundStyle(Palette.text)
                        Text(entry.row.date, format: .dateTime.hour().minute())
                            .font(Typography.caption)
                            .foregroundStyle(Palette.subtext)
                            .luminousChrome()
                    }
                }

                content
                    .contextMenu { contextActions }

                if !reactions.isEmpty {
                    ReactionBar(reactions: reactions, onTap: onReact)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, entry.showsHeader ? Space.xs : 0)
        .opacity(entry.row.delivery == .pending ? 0.55 : 1)
        // VoiceOver reads the row as one sentence rather than walking five
        // separate fragments, and the reactions ride along as a summary.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// What VoiceOver says for this message, in the order a person would.
    private var accessibilityDescription: String {
        var parts = ["\(entry.row.displayName) said"]
        parts.append(entry.row.isDeleted ? "message deleted" : entry.row.content)
        parts.append(entry.row.date.formatted(date: .omitted, time: .shortened))

        if entry.row.isEdited { parts.append("edited") }
        switch entry.row.delivery {
        case .pending: parts.append("sending")
        case .failed(let reason): parts.append("failed to send. \(reason ?? "")")
        case .sent: break
        }
        if !reactions.isEmpty {
            let summary = reactions
                .map { "\($0.count) \($0.emoji)\($0.includesMe ? ", including yours" : "")" }
                .joined(separator: ", ")
            parts.append("Reactions: \(summary)")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var content: some View {
        if entry.row.isDeleted {
            Text("Message deleted")
                .font(Typography.secondary.italic())
                .foregroundStyle(Palette.subtext.opacity(0.7))
        } else {
            // Rich content (Buzz kind 40002) renders as its plain fallback for
            // now; a real renderer is later polish. The fallback rule is what
            // keeps the app whole on relays that never send it.
            Text("\(entry.row.content)\(editedMarker)")
                .font(Typography.body)
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
        }

        if case .failed(let reason) = entry.row.delivery {
            Label(reason ?? "Could not send", systemImage: "exclamationmark.circle")
                .font(Typography.caption)
                .foregroundStyle(Palette.danger)
        }
    }

    @ViewBuilder
    private var contextActions: some View {
        if case .failed = entry.row.delivery {
            Button("Try again", systemImage: "arrow.clockwise", action: onRetry)
            Button("Discard", systemImage: "trash", role: .destructive, action: onDiscard)
        } else if !entry.row.isDeleted {
            ForEach(Self.quickReactions, id: \.self) { emoji in
                Button(emoji) { onReact(emoji) }
            }
            if let onZap {
                Divider()
                Button("Zap", systemImage: "bolt.fill", action: onZap)
            }
        }
    }

    /// Styled inline rather than concatenated: `Text + Text` is deprecated on
    /// iOS 26 in favour of interpolation.
    private var editedMarker: Text {
        guard entry.row.isEdited else { return Text(verbatim: "") }
        return Text("  (edited)")
            .font(Typography.caption)
            .foregroundStyle(Palette.subtext)
    }
}

private struct ReactionBar: View {
    let reactions: [ReactionSummary]
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(reactions) { reaction in
                // Tapping a chip toggles: join the pile, or withdraw your own.
                Button { onTap(reaction.emoji) } label: { chip(reaction) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(reaction.emoji), \(reaction.count)"
                            + (reaction.includesMe ? ", including yours" : "")
                    )
                    .accessibilityHint(
                        reaction.includesMe ? "Removes your reaction" : "Adds your reaction"
                    )
            }
        }
        .padding(.top, Space.hairline)
    }

    private func chip(_ reaction: ReactionSummary) -> some View {
        HStack(spacing: Space.xxs) {
            Text(reaction.emoji).font(Typography.label)
            Text("\(reaction.count)")
                .font(Typography.count)
                .foregroundStyle(
                    reaction.includesMe ? Palette.oliveInk : Palette.subtext
                )
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.xxs)
        .background(
            reaction.includesMe
                ? Palette.chartreuse.opacity(0.45)
                : Palette.surface.opacity(0.5),
            in: .capsule
        )
    }
}

/// The message input, glass over the gradient.
private struct ComposeBar: View {
    @Binding var draft: String
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: Space.xs) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(Typography.body)
                .foregroundStyle(Palette.text)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                .background(Palette.surface.opacity(0.45), in: .rect(cornerRadius: Radii.card))

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(Typography.action)
                    .foregroundStyle(Palette.ink)
                    // 44pt is Apple's minimum comfortable target; the glyph
                    // stays visually small inside it.
                    .frame(width: Sizing.hitTarget, height: Sizing.hitTarget)
            }
            .accessibilityLabel("Send message")
            .buttonStyle(.glassProminent)
            .tint(Palette.chartreuse)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .glassEffect(in: .rect(cornerRadius: Radii.sheet))
        .padding(.horizontal, Space.xs)
        .padding(.bottom, Space.xxs)
    }
}

/// Feeds the timeline from store observation, and asks the session for older
/// history when the local page runs dry.
@MainActor
@Observable
final class ChannelTimeline {
    struct Entry: Identifiable, Equatable {
        let row: TimelineRow
        /// Whether this message starts a run: author changed or five minutes
        /// passed. Grouping is what keeps a busy channel readable.
        let showsHeader: Bool

        var id: String { row.id }
    }

    private(set) var snapshot = TimelineSnapshot.empty
    private(set) var isLoadingOlder = false
    private(set) var canLoadOlder = true

    private let session: CommunitySession
    private let channel: String
    private var visibleLimit = 80
    private var observation: Task<Void, Never>?

    init(session: CommunitySession, channel: String) {
        self.session = session
        self.channel = channel
    }

    /// Oldest first, with header grouping resolved.
    var displayRows: [Entry] {
        let ordered = snapshot.rows.reversed()
        var entries: [Entry] = []
        entries.reserveCapacity(snapshot.rows.count)

        var previous: TimelineRow?
        for row in ordered {
            let startsRun = previous.map {
                $0.pubkey != row.pubkey || row.createdAt - $0.createdAt > 300
            } ?? true
            entries.append(Entry(row: row, showsHeader: startsRun))
            previous = row
        }
        return entries
    }

    func activate() async {
        observe()
    }

    func send(_ text: String) async {
        await session.send(text, in: channel)
    }

    func toggleReaction(_ emoji: String, on messageID: String) async {
        await session.toggleReaction(emoji, on: messageID, in: channel)
    }

    func retry(_ messageID: String) async {
        await session.retrySend(messageID)
    }

    func discard(_ messageID: String) async {
        await session.discardSend(messageID)
    }

    func loadOlder() async {
        guard !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let oldest = snapshot.rows.last?.createdAt ?? Int64(Date().timeIntervalSince1970)
        visibleLimit += 80
        // Restart observation at the wider window first, so anything already
        // local appears instantly; the relay fetch fills in behind it.
        observe()

        if let fetched = try? await session.loadOlder(channel: channel, before: oldest) {
            // Nothing new from the relay and nothing more locally means the
            // channel's history is exhausted.
            if fetched == 0, snapshot.rows.count < visibleLimit {
                canLoadOlder = false
            }
        }
    }

    private func observe() {
        observation?.cancel()
        let store = session.store
        let limit = visibleLimit
        let channel = channel
        let me = session.me.hex

        observation = Task { [weak self] in
            do {
                for try await value in store.observeTimeline(
                    channel: channel,
                    limit: limit,
                    me: me
                ) {
                    guard !Task.isCancelled else { return }
                    self?.snapshot = value
                }
            } catch {
                // Database failure; the timeline stops updating rather than
                // crashing. The diagnostics screen is the place this surfaces.
            }
        }
    }
}
