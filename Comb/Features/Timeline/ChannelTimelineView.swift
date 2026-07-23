import CombCore
import CombStore
import PhotosUI
import SwiftUI

/// A channel's conversation, newest at the bottom, read from the store.
struct ChannelTimelineView: View {
    let session: CommunitySession
    let channel: ChannelSummary

    @State private var model: ChannelTimeline
    @State private var draft = ""
    @State private var zapTarget: ChannelTimeline.Entry?
    @State private var profileTarget: ProfileTarget?
    @State private var threadRoot: TimelineRow?
    @State private var tray: AttachmentTray
    @State private var loader: MediaLoader
    @State private var editing: TimelineRow?
    @State private var deleting: TimelineRow?

    init(session: CommunitySession, channel: ChannelSummary) {
        self.session = session
        self.channel = channel
        _model = State(initialValue: ChannelTimeline(session: session, channel: channel.id))
        _tray = State(initialValue: AttachmentTray(session: session))
        _loader = State(initialValue: MediaLoader(session: session))
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
                            loader: loader,
                            onReact: { emoji in
                                Task { await model.toggleReaction(emoji, on: entry.row.id) }
                            },
                            onRetry: { Task { await model.retry(entry.row.id) } },
                            onDiscard: { Task { await model.discard(entry.row.id) } },
                            onZap: entry.row.authorLightningAddress == nil
                                ? nil
                                : { zapTarget = entry },
                            onOpenAuthor: { profileTarget = ProfileTarget(pubkey: entry.row.pubkey) },
                            onOpenThread: { threadRoot = entry.row },
                            // Replying opens the thread rather than composing in
                            // place: the reply belongs there, and landing in the
                            // thread shows what is already being said.
                            onReply: entry.row.isDeleted ? nil : { threadRoot = entry.row },
                            onEdit: ownMessageAction(entry.row) {
                                editing = entry.row
                                draft = entry.row.displayContent
                            },
                            onDelete: ownMessageAction(entry.row) { deleting = entry.row }
                        )
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.sm)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .softScrollEdges()
        }
        .safeAreaInset(edge: .bottom) {
            ComposeBar(
                draft: $draft,
                attachments: tray,
                editingPreview: editing?.displayContent,
                onCancelEdit: {
                    editing = nil
                    draft = ""
                }
            ) {
                let text = draft
                draft = ""
                if let editing {
                    self.editing = nil
                    Task { await model.edit(editing.id, to: text) }
                } else {
                    let media = tray.readyDescriptors
                    tray.clear()
                    Task { await model.send(text, attachments: media) }
                }
            }
        }
        .confirmationDialog(
            "Delete this message?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete message", role: .destructive) {
                if let deleting {
                    Task { await model.deleteMessage(deleting.id) }
                }
                deleting = nil
            }
        } message: {
            Text("It disappears for everyone in the channel, though people may already have read it.")
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if channel.memberCount > 0 {
                    NavigationLink {
                        MemberListView(
                            session: session,
                            channelID: channel.id,
                            channelName: channel.name
                        )
                    } label: {
                        Label("\(channel.memberCount)", systemImage: "person.2")
                            .font(Typography.count)
                            .foregroundStyle(Palette.text)
                            .luminousChrome()
                    }
                    .accessibilityLabel("\(channel.memberCount) members")
                }
            }
        }
        .task { await model.activate() }
        .navigationDestination(item: $threadRoot) { root in
            ThreadView(session: session, channel: channel, root: root)
        }
        .sheet(item: $profileTarget) { target in
            ProfileSheet(session: session, pubkey: target.pubkey)
        }
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

    /// The action, only when the message is the viewer's own and not deleted.
    private func ownMessageAction(
        _ row: TimelineRow,
        _ action: @escaping () -> Void
    ) -> (() -> Void)? {
        guard row.pubkey == session.me.hex, !row.isDeleted else { return nil }
        return action
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
struct MessageRow: View {
    let entry: ChannelTimeline.Entry
    let reactions: [ReactionSummary]
    let loader: MediaLoader
    let onReact: (String) -> Void
    let onRetry: () -> Void
    let onDiscard: () -> Void
    let onZap: (() -> Void)?
    let onOpenAuthor: () -> Void
    /// Opens the thread this message started. Absent inside a thread, where
    /// there is nowhere further to go.
    var onOpenThread: (() -> Void)?
    var onReply: (() -> Void)?
    /// Present only on the viewer's own messages.
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    /// The quick palette. A full picker is later polish.
    private static let quickReactions = ["🐝", "👍", "❤️", "🔥", "😂"]

    /// Matches AvatarView's scaled frame so continuation lines in a run stay
    /// aligned with the first at every text size.
    @ScaledMetric(relativeTo: .subheadline) private var avatarWidth: CGFloat = Sizing.avatar

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            if entry.showsHeader {
                Button(action: onOpenAuthor) {
                    AvatarView(name: entry.row.displayName, picture: entry.row.authorPicture)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.row.displayName)'s profile")
            } else {
                Color.clear.frame(width: avatarWidth, height: 1)
            }

            VStack(alignment: .leading, spacing: Space.hairline) {
                // Only the author, time and text are merged. Combining the whole
                // row would swallow the reaction and thread buttons: `.combine`
                // flattens its children into one element, and a control inside
                // it stops being reachable by VoiceOver.
                VStack(alignment: .leading, spacing: Space.hairline) {
                    if entry.showsHeader {
                        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                            Button(action: onOpenAuthor) {
                                Text(entry.row.displayName)
                                    .font(Typography.name)
                                    .foregroundStyle(Palette.text)
                            }
                            .buttonStyle(.plain)
                            Text(entry.row.date, format: .dateTime.hour().minute())
                                .font(Typography.caption)
                                .foregroundStyle(Palette.subtext)
                                .luminousChrome()
                        }
                    }

                    content

                    if !entry.row.attachments.isEmpty, !entry.row.isDeleted {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            ForEach(entry.row.attachments) { attachment in
                                AttachmentView(attachment: attachment, loader: loader)
                            }
                        }
                        .padding(.top, Space.xxs)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityDescription)
                .contextMenu { contextActions }

                if !reactions.isEmpty {
                    ReactionBar(reactions: reactions, onTap: onReact)
                }

                if entry.row.hasThread, let onOpenThread {
                    ThreadAffordance(
                        count: entry.row.replyCount,
                        lastReply: entry.row.lastReplyDate,
                        action: onOpenThread
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, entry.showsHeader ? Space.xs : 0)
        .opacity(entry.row.delivery == .pending ? 0.55 : 1)
    }

    /// What VoiceOver says for this message, in the order a person would.
    private var accessibilityDescription: String {
        var parts = ["\(entry.row.displayName) said"]
        if entry.row.isDeleted {
            parts.append("message deleted")
        } else {
            let text = entry.row.displayContent
            parts.append(text.isEmpty ? "sent a picture" : text)
        }
        parts.append(entry.row.date.formatted(date: .omitted, time: .shortened))

        if entry.row.isEdited { parts.append("edited") }
        switch entry.row.delivery {
        case .pending: parts.append("sending")
        case .failed(let reason): parts.append("failed to send. \(reason ?? "")")
        case .sent: break
        }
        // Reactions and the thread affordance are their own elements now, each
        // with its own label, so repeating them here would read them twice.
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
            let text = entry.row.displayContent
            if !text.isEmpty {
                Text("\(text)\(editedMarker)")
                    .font(Typography.body)
                    .foregroundStyle(Palette.text)
                    .textSelection(.enabled)
            }
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
            if let onReply {
                Divider()
                Button("Reply in thread", systemImage: "arrowshape.turn.up.left", action: onReply)
            }
            if let onZap {
                Button("Zap", systemImage: "bolt.fill", action: onZap)
            }
            if onEdit != nil || onDelete != nil {
                Divider()
            }
            if let onEdit {
                Button("Edit", systemImage: "pencil", action: onEdit)
            }
            if let onDelete {
                // Destructive is earned here, unlike sign-out: the message
                // really is removed for everyone.
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
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

/// The way into a thread, shown under the message that started it.
///
/// Carries the reply count and how recently the thread moved, because those are
/// the two things that decide whether it is worth opening.
private struct ThreadAffordance: View {
    let count: Int
    let lastReply: Date?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xxs) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(Typography.count)
                Text(count == 1 ? "1 reply" : "\(count) replies")
                    .font(Typography.label)
                if let lastReply {
                    Text(lastReply, format: .relative(presentation: .named))
                        .font(Typography.caption)
                        .foregroundStyle(Palette.subtext)
                }
            }
            .foregroundStyle(Palette.oliveInk)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
            .background(Palette.chartreuse.opacity(0.18), in: .capsule)
        }
        .buttonStyle(.plain)
        .padding(.top, Space.xxs)
        .accessibilityLabel(count == 1 ? "1 reply" : "\(count) replies")
        .accessibilityHint("Opens the thread")
    }
}

struct ReactionBar: View {
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
struct ComposeBar: View {
    @Binding var draft: String
    var placeholder: String = "Message"
    /// Attachment state, owned by the caller so the send action can clear it.
    var attachments: AttachmentTray?
    /// A preview of the message being edited, when the bar is in edit mode.
    var editingPreview: String?
    var onCancelEdit: () -> Void = {}
    let onSend: () -> Void

    @State private var picked: [PhotosPickerItem] = []

    private var canSend: Bool {
        guard attachments?.isUploading != true else { return false }
        // Keyed on what would actually be sent, not on the tray being
        // non-empty: an attachment that failed to upload contributes nothing,
        // and enabling Send for it gives a button that does nothing.
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || attachments?.readyDescriptors.isEmpty == false
    }

    var body: some View {
        VStack(spacing: Space.xs) {
            if let editingPreview {
                HStack(spacing: Space.xs) {
                    Image(systemName: "pencil")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.chartreuse)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Editing")
                            .font(Typography.captionEmphasis)
                            .foregroundStyle(Palette.text)
                        Text(editingPreview)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.subtext)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Space.xs)
                    Button {
                        onCancelEdit()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.subtext)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel editing")
                }
                .padding(.horizontal, Space.sm)
                .padding(.top, Space.xxs)
            }

            if let attachments, !attachments.isEmpty {
                AttachmentTrayView(tray: attachments)
            }

            // Centred, not bottom-aligned: the glass button style pads its
            // label, so the send circle renders taller than the field, and
            // bottom alignment visibly hangs the field off its foot. Centring
            // absorbs the style's extra height evenly on both sides.
            HStack(alignment: .center, spacing: Space.xs) {
                if attachments != nil {
                    PhotosPicker(
                        selection: $picked,
                        maxSelectionCount: 4,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        // No `luminousChrome()` here: the picker's label
                        // closure is not main-actor isolated.
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(Typography.actionSecondary)
                            .foregroundStyle(Palette.subtext)
                            .frame(width: Sizing.hitTarget, height: Sizing.hitTarget)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Add a photo")
                }

                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(Typography.body)
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, Space.sm)
                    // The field matches the buttons' height exactly, so all
                    // three sit on one line instead of a small field floating
                    // beside a larger button.
                    .frame(minHeight: Sizing.hitTarget)
                    .background(
                        Palette.surface.opacity(0.45),
                        in: .rect(cornerRadius: Radii.composeField)
                    )

                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(Typography.action)
                        .foregroundStyle(Palette.ink)
                        .frame(width: Sizing.hitTarget, height: Sizing.hitTarget)
                }
                .accessibilityLabel("Send message")
                .buttonStyle(.glassProminent)
                // Circular rather than the style's default capsule: a 44pt
                // capsule around a 44pt frame reads as a lozenge next to a
                // rounded field, and the circle is what makes the send action
                // the one distinct shape in the bar.
                .buttonBorderShape(.circle)
                .tint(Palette.chartreuse)
                .disabled(!canSend)
            }
        }
        // Space.xs all round, which is what makes the field's corner
        // concentric with the shell's: 24 outer, 8 padding, 16 inner. The
        // same 8pt then separates the bar from the screen edge, so the bar
        // does not sit hard against the home indicator.
        .padding(Space.xs)
        .glassEffect(in: .rect(cornerRadius: Radii.sheet))
        .padding(.horizontal, Space.sm)
        .padding(.bottom, Space.xs)
        .onChange(of: picked) { _, items in
            guard let attachments, !items.isEmpty else { return }
            picked = []
            Task { await attachments.add(items) }
        }
    }
}

/// The strip of pending attachments above the input.
private struct AttachmentTrayView: View {
    let tray: AttachmentTray

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.xs) {
                ForEach(tray.items) { item in
                    thumbnail(item)
                }
            }
            .padding(.horizontal, Space.xxs)
        }
        .scrollIndicators(.hidden)
        .frame(height: 72)
    }

    private func thumbnail(_ item: AttachmentTray.Item) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: item.preview)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(.rect(cornerRadius: Radii.control))
                .overlay {
                    switch item.state {
                    case .uploading:
                        ZStack {
                            Color.black.opacity(0.45)
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        .clipShape(.rect(cornerRadius: Radii.control))
                    case .failed:
                        ZStack {
                            Color.black.opacity(0.5)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Palette.danger)
                        }
                        .clipShape(.rect(cornerRadius: Radii.control))
                    case .ready:
                        EmptyView()
                    }
                }

            Button {
                tray.remove(item.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(2)
            .accessibilityLabel("Remove attachment")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.hasFailed ? "Attachment failed to upload" : "Attachment")
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
        await markRead()
    }

    /// Marks the channel read on open, and again whenever new messages land
    /// while it is on screen, so a channel you are reading never accumulates a
    /// badge behind your back.
    func markRead() async {
        try? await session.store.markRead(channel: channel)
    }

    func send(_ text: String, attachments: [Blossom.Descriptor] = []) async {
        await session.send(text, in: channel, attachments: attachments)
    }

    func edit(_ messageID: String, to newText: String) async {
        await session.edit(messageID, to: newText, in: channel)
    }

    func deleteMessage(_ messageID: String) async {
        await session.deleteMessage(messageID, in: channel)
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
                    await self?.markRead()
                }
            } catch {
                // Database failure; the timeline stops updating rather than
                // crashing. The diagnostics screen is the place this surfaces.
            }
        }
    }
}
