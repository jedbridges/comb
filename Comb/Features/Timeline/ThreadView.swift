import CombCore
import CombStore
import SwiftUI

/// One thread: the message that opened it, then every reply in order.
///
/// A separate screen rather than an inline expansion, matching Buzz, which
/// routes threads to their own view. The channel stays a list of conversations
/// instead of becoming a transcript of every aside inside them.
struct ThreadView: View {
    let session: CommunitySession
    let channel: ChannelSummary
    /// The message the thread hangs off. Passed in so the opener renders
    /// immediately, before the thread query returns.
    let root: TimelineRow

    @State private var model: ThreadModel
    @State private var draft = ""
    @State private var profileTarget: ProfileTarget?
    @State private var zapTarget: TimelineRow?

    init(session: CommunitySession, channel: ChannelSummary, root: TimelineRow) {
        self.session = session
        self.channel = channel
        self.root = root
        _model = State(initialValue: ThreadModel(session: session, channel: channel.id, root: root))
    }

    var body: some View {
        ZStack {
            Palette.backgroundGradient.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.hairline) {
                    ForEach(model.entries) { entry in
                        // The opener is separated from its replies by a rule
                        // carrying the count, so it is obvious which message
                        // everything below is answering.
                        if entry.row.id == root.id {
                            messageRow(entry)
                            replyDivider
                        } else {
                            messageRow(entry)
                        }
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.sm)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) {
            ComposeBar(draft: $draft, placeholder: "Reply") {
                let text = draft
                draft = ""
                Task { await model.reply(text) }
            }
        }
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.activate() }
        .sheet(item: $profileTarget) { target in
            ProfileSheet(session: session, pubkey: target.pubkey)
        }
        .sheet(item: $zapTarget) { row in
            if let address = row.authorLightningAddress,
               let recipient = PublicKey(hex: row.pubkey) {
                ZapSheet(
                    session: session,
                    recipient: recipient,
                    lightningAddress: address,
                    messageID: row.id,
                    recipientName: row.displayName
                )
            }
        }
    }

    private func messageRow(_ entry: ChannelTimeline.Entry) -> some View {
        MessageRow(
            entry: entry,
            reactions: model.snapshot.reactions[entry.row.id] ?? [],
            onReact: { emoji in
                Task { await model.toggleReaction(emoji, on: entry.row.id) }
            },
            onRetry: { Task { await model.retry(entry.row.id) } },
            onDiscard: { Task { await model.discard(entry.row.id) } },
            onZap: entry.row.authorLightningAddress == nil ? nil : { zapTarget = entry.row },
            onOpenAuthor: { profileTarget = ProfileTarget(pubkey: entry.row.pubkey) }
            // No `onOpenThread` or `onReply`: this is already the thread, and
            // threads do not nest. The compose bar below is the way to reply.
        )
    }

    private var replyDivider: some View {
        HStack(spacing: Space.xs) {
            Text(model.replyCount == 1 ? "1 reply" : "\(model.replyCount) replies")
                .font(Typography.caption)
                .foregroundStyle(Palette.subtext)
                .luminousChrome()
            Rectangle()
                .fill(Palette.border)
                .frame(height: 0.5)
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }
}

/// Feeds a thread from store observation, and sends replies into it.
@MainActor
@Observable
final class ThreadModel {
    private(set) var snapshot = TimelineSnapshot.empty

    private let session: CommunitySession
    private let channel: String
    private let root: TimelineRow
    private var observation: Task<Void, Never>?

    init(session: CommunitySession, channel: String, root: TimelineRow) {
        self.session = session
        self.channel = channel
        self.root = root
    }

    /// Everything but the opener.
    var replyCount: Int { max(snapshot.rows.count - 1, 0) }

    /// Oldest first, already the query's order, with header grouping resolved
    /// the same way the channel does it.
    var entries: [ChannelTimeline.Entry] {
        var result: [ChannelTimeline.Entry] = []
        var previous: TimelineRow?
        for row in snapshot.rows {
            let startsRun = previous.map {
                $0.pubkey != row.pubkey || row.createdAt - $0.createdAt > 300
            } ?? true
            result.append(ChannelTimeline.Entry(row: row, showsHeader: startsRun))
            previous = row
        }
        return result
    }

    func activate() async {
        observe()
    }

    /// Replies to the thread's opener, which is what keeps every reply under one
    /// root instead of chaining each onto the last and splintering the thread.
    func reply(_ text: String) async {
        await session.send(
            text,
            in: channel,
            replyingTo: ReplyContext(startingThreadOn: root)
        )
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

    private func observe() {
        observation?.cancel()
        let store = session.store
        let rootID = root.id
        let me = session.me.hex

        observation = Task { [weak self] in
            do {
                for try await value in store.observeThread(root: rootID, me: me) {
                    guard !Task.isCancelled else { return }
                    self?.snapshot = value
                }
            } catch {
                // Database failure; the thread stops updating rather than
                // crashing, same as the channel timeline.
            }
        }
    }
}
