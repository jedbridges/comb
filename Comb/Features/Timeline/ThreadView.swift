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
    @State private var reactingTo: TimelineRow?
    @FocusState private var isComposing: Bool
    @State private var tray: AttachmentTray
    @State private var loader: MediaLoader

    init(session: CommunitySession, channel: ChannelSummary, root: TimelineRow) {
        self.session = session
        self.channel = channel
        self.root = root
        _model = State(initialValue: ThreadModel(session: session, channel: channel.id, root: root))
        _tray = State(initialValue: AttachmentTray(session: session))
        _loader = State(initialValue: MediaLoader(session: session))
    }

    var body: some View {
        ZStack {
            Palette.backgroundGradient.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.hairline) {
                    ForEach(model.entries) { entry in
                        if entry.showsDayBreak, entry.row.id != root.id {
                            DayBreak(date: entry.row.date)
                        }
                        // The opener is separated from its replies by a rule
                        // carrying the count, so it is obvious which message
                        // everything below is answering.
                        if entry.row.id == root.id {
                            messageRow(entry)
                            replyDivider
                        } else {
                            // Replies sit behind a rail, which is the standing
                            // signal that everything below the divider belongs
                            // to the message above it rather than to the
                            // channel.
                            messageRow(entry)
                                .padding(.leading, Space.sm)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(Palette.hairlineOnGradient)
                                        .frame(width: 2)
                                }
                        }
                    }

                    if model.replyCount == 0 {
                        emptyThread
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.sm)
                .frame(maxWidth: .infinity, minHeight: 0)
                .contentShape(.rect)
                .onTapGesture { isComposing = false }
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .softScrollEdges()
        }
        .safeAreaInset(edge: .bottom) {
            ComposeBar(
                draft: $draft,
                placeholder: "Reply",
                attachments: tray,
                mentionSuggestions: model.mentionSuggestions,
                onPickMention: { profile in
                    draft = model.completeMention(in: draft, with: profile)
                },
                focus: $isComposing
            ) {
                let text = draft
                let media = tray.readyDescriptors
                draft = ""
                tray.clear()
                Task { await model.reply(text, attachments: media) }
            }
            .onChange(of: draft) { _, new in
                model.updateMentionSuggestions(for: new)
            }

        }
        .navigationTitle("Thread with \(root.displayName)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.activate() }
        .sheet(item: $profileTarget) { target in
            ProfileSheet(session: session, pubkey: target.pubkey)
        }
        .sheet(item: $reactingTo) { row in
            EmojiPicker { emoji in
                Task { await model.toggleReaction(emoji, on: row.id) }
            }
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
            loader: loader,
            mentionNames: model.mentionNames,
            mentionsMe: entry.row.mentions(session.me.hex),
            onReact: { emoji in
                Task { await model.toggleReaction(emoji, on: entry.row.id) }
            },
            onRetry: { Task { await model.retry(entry.row.id) } },
            onDiscard: { Task { await model.discard(entry.row.id) } },
            onZap: entry.row.authorLightningAddress == nil ? nil : { zapTarget = entry.row },
            onOpenAuthor: { profileTarget = ProfileTarget(pubkey: entry.row.pubkey) },
            onPickEmoji: entry.row.isDeleted ? nil : { reactingTo = entry.row }
            // No `onOpenThread` or `onReply`: this is already the thread, and
            // threads do not nest. The compose bar below is the way to reply.
        )
    }

    /// A thread nobody has answered yet. Reached by tapping any message, so
    /// this is a common state, not an edge case.
    private var emptyThread: some View {
        VStack(spacing: Space.xxs) {
            Text("No replies yet")
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.text)
            Text("Start the thread below.")
                .font(Typography.secondary)
                .foregroundStyle(Palette.subtext)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
        .accessibilityElement(children: .combine)
    }

    private var replyDivider: some View {
        HStack(spacing: Space.xs) {
            Text(replyLabel)
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

    /// "Thread" when empty, so the divider still says what the section is.
    private var replyLabel: String {
        switch model.replyCount {
        case 0: "Thread"
        case 1: "1 reply"
        default: "\(model.replyCount) replies"
        }
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
    private let mentions: MentionComposer

    init(session: CommunitySession, channel: String, root: TimelineRow) {
        self.session = session
        self.channel = channel
        self.root = root
        self.mentions = MentionComposer(store: session.store, channelID: channel)
    }

    var mentionSuggestions: [ProfileSummary] { mentions.suggestions }
    var mentionNames: [String] { mentions.candidates.map(\.name) }

    func updateMentionSuggestions(for draft: String) {
        mentions.update(for: draft)
    }

    func completeMention(in draft: String, with profile: ProfileSummary) -> String {
        mentions.complete(draft, with: profile)
    }

    /// Everything but the opener.
    var replyCount: Int { max(snapshot.rows.count - 1, 0) }

    /// Oldest first, already the query's order, built by the same helper as
    /// the channel so runs and day breaks can never disagree between the two.
    var entries: [ChannelTimeline.Entry] {
        ChannelTimeline.makeEntries(orderedOldestFirst: snapshot.rows)
    }

    func activate() async {
        observe()
        mentions.loadCandidates()
    }

    /// Replies to the thread's opener, which is what keeps every reply under one
    /// root instead of chaining each onto the last and splintering the thread.
    func reply(_ text: String, attachments: [Blossom.Descriptor] = []) async {
        // The thread's opener is always tagged: answering someone is itself a
        // mention, and normalization dedupes it against any @name in the body.
        await session.send(
            text,
            in: channel,
            replyingTo: ReplyContext(startingThreadOn: root),
            attachments: attachments,
            mentioning: mentions.mentionedPubkeys(in: text)
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
