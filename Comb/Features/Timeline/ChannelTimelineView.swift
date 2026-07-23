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
    @State private var reactingTo: TimelineRow?
    @FocusState private var isComposing: Bool
    @State private var scrollPosition = ScrollPosition()
    @State private var isAwayFromBottom = false
    @State private var arrivalsWhileAway = 0

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
                // Space.xs between messages rather than a hairline: the
                // design brief asks for comfortable over compact, and rows
                // separated by 2pt read as one wall of text.
                LazyVStack(alignment: .leading, spacing: Space.xs) {
                    // Hidden when the channel is empty: a backfill button over
                    // a void promises history that does not exist.
                    if model.canLoadOlder, !model.displayRows.isEmpty {
                        loadOlderControl
                    }

                    // Rendered oldest to newest; the query returns newest first.
                    ForEach(model.displayRows) { entry in
                        if entry.showsDayBreak {
                            DayBreak(date: entry.row.date)
                        }
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
                            onDelete: ownMessageAction(entry.row) { deleting = entry.row },
                            onPickEmoji: entry.row.isDeleted ? nil : { reactingTo = entry.row }
                        )
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.sm)
                // Taps that miss a message dismiss the keyboard. Rows carry
                // their own tap gesture and win, being innermost, so opening a
                // thread still works while typing.
                .frame(maxWidth: .infinity, minHeight: 0)
                .contentShape(.rect)
                .onTapGesture { isComposing = false }
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .softScrollEdges()
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
                    - geometry.visibleRect.maxY
                    + geometry.contentInsets.bottom
            } action: { _, distanceFromBottom in
                isAwayFromBottom = distanceFromBottom > 300
            }
            .onChange(of: model.displayRows.last?.id) { previous, current in
                // A message landing while the reader is up in history: count it
                // on the pill rather than yanking them down.
                guard isAwayFromBottom, previous != nil, previous != current else { return }
                arrivalsWhileAway += 1
            }
            .onChange(of: isAwayFromBottom) { _, away in
                if !away { arrivalsWhileAway = 0 }
            }
            .overlay(alignment: .bottomTrailing) {
                if isAwayFromBottom {
                    jumpToBottom
                }
            }

            if model.displayRows.isEmpty {
                emptyChannel
            }
        }
        .safeAreaInset(edge: .bottom) {
            ComposeBar(
                draft: $draft,
                attachments: tray,
                editingPreview: editing?.displayContent,
                onCancelEdit: {
                    editing = nil
                    draft = ""
                },
                mentionSuggestions: model.mentionSuggestions,
                onPickMention: { profile in
                    draft = model.completeMention(in: draft, with: profile)
                },
                focus: $isComposing
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
            .onChange(of: draft) { _, new in
                model.updateMentionSuggestions(for: new)
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
        .sheet(item: $reactingTo) { row in
            EmojiPicker { emoji in
                Task { await model.toggleReaction(emoji, on: row.id) }
            }
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

    /// The way back to now, present only once the reader has left it.
    private var jumpToBottom: some View {
        Button {
            withAnimation(Motion.standard) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        } label: {
            HStack(spacing: Space.xxs) {
                Image(systemName: "chevron.down")
                if arrivalsWhileAway > 0 {
                    Text("\(arrivalsWhileAway) new")
                        .font(Typography.count)
                }
            }
            .font(Typography.actionSecondary)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, Space.sm)
            .frame(minHeight: Sizing.hitTarget)
        }
        .buttonStyle(.glass)
        .padding(.trailing, Space.sm)
        .padding(.bottom, Space.sm)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityLabel(
            arrivalsWhileAway > 0
                ? "\(arrivalsWhileAway) new messages. Jump to latest."
                : "Jump to latest"
        )
    }

    /// The first-visit state: an invitation, not a void. The compose bar
    /// right below it is the call to action.
    private var emptyChannel: some View {
        VStack(spacing: Space.sm) {
            ChannelGlyph(name: channel.name, size: 64)
            Text("Nothing here yet")
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.text)
            Text("Say the first thing.")
                .font(Typography.secondary)
                .foregroundStyle(Palette.subtext)
        }
        .arrival(true)
        .accessibilityElement(children: .combine)
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
    /// Roster names, so `@mentions` in the body can be highlighted.
    var mentionNames: [String] = []
    /// Whether this message names the reader, which earns it a wash of the
    /// accent down the leading edge.
    var mentionsMe: Bool = false
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
    /// Opens the full emoji picker for this message.
    var onPickEmoji: (() -> Void)?

    /// The quick palette, shared with the reaction bar's add button so the
    /// two ways to react can never disagree. A full picker is later polish.
    static let quickReactions = ["🐝", "👍", "❤️", "🔥", "😂"]

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

            VStack(alignment: .leading, spacing: Space.xxs) {
                // Only the author, time and text are merged. Combining the whole
                // row would swallow the reaction and thread buttons: `.combine`
                // flattens its children into one element, and a control inside
                // it stops being reachable by VoiceOver.
                VStack(alignment: .leading, spacing: Space.xxs) {
                    if entry.showsHeader {
                        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                            Button(action: onOpenAuthor) {
                                // One line: a 200-character display name is
                                // someone else's choice, and it must not shove
                                // the timestamp off the screen.
                                Text(entry.row.displayName)
                                    .font(Typography.name)
                                    .foregroundStyle(Palette.text)
                                    .lineLimit(1)
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
                .accessibilityHint(onOpenThread == nil ? "" : "Opens the thread")
                .contentShape(.rect)
                // Tap opens the thread whether or not one exists yet: a
                // message is the start of a conversation that has not happened
                // yet, and requiring a long-press to discover that hid the
                // feature behind knowledge.
                .onTapGesture { onOpenThread?() }
                .contextMenu { contextActions }

                if !reactions.isEmpty {
                    ReactionBar(
                        reactions: reactions,
                        onTap: onReact,
                        onPickEmoji: onPickEmoji
                    )
                }

                if entry.row.hasThread, let onOpenThread {
                    ThreadAffordance(count: entry.row.replyCount, action: onOpenThread)
                }
            }

            Spacer(minLength: 0)
        }
        // A new speaker gets real air above them; a continuation line stays
        // close to what it continues.
        .padding(.top, entry.showsHeader ? Space.sm : 0)
        .padding(.vertical, mentionsMe ? Space.xs : 0)
        .background {
            // Being named is the one thing worth finding while scanning, so
            // it gets a wash rather than only a coloured word inside the
            // text. Chartreuse at low opacity: the accent stays scarce.
            if mentionsMe {
                RoundedRectangle(cornerRadius: Radii.bubble)
                    .fill(Palette.chartreuse.opacity(0.10))
            }
        }
        .opacity(entry.row.delivery == .pending ? 0.55 : 1)
    }

    /// What VoiceOver says for this message, in the order a person would.
    private var accessibilityDescription: String {
        // Announced first: it is the reason to care about this row at all.
        var parts = mentionsMe
            ? ["Mentions you.", "\(entry.row.displayName) said"]
            : ["\(entry.row.displayName) said"]
        if entry.row.isDeleted {
            parts.append("message deleted")
        } else {
            let text = entry.row.displayContent
            parts.append(text.isEmpty ? "sent a picture" : text)
        }
        // Day included: VoiceOver users scroll history too, and "4:56 PM"
        // with no day is the same disorientation the date pills fix visually.
        parts.append(entry.row.date.formatted(date: .abbreviated, time: .shortened))

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
                // Linkified: a designers community trades in links, and dead
                // URLs were the first papercut in every share. Tapping opens
                // Safari through the standard openURL path.
                Text("\(Text(MessageLinks.attributed(text, mentionNames: mentionNames)))\(editedMarker)")
                    .font(Typography.body)
                    .foregroundStyle(Palette.text)
                    // Light text on a dark ground reads thinner than it is and
                    // wants more leading, which is also the design brief's
                    // stated rule for this exact case.
                    .lineSpacing(2)
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
            if let onPickEmoji {
                Button("More reactions…", systemImage: "face.smiling", action: onPickEmoji)
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
/// Deliberately not chartreuse. The accent already marks unread channels and
/// messages that name you; a third use on one screen is the point where none
/// of them mean anything. This is navigation, not an alert, so it takes the
/// same neutral lift as every other chip.
///
/// No timestamp either: the message above already carries a time, and "22
/// hours ago" beside "1 reply" answered a question nobody is asking at the
/// moment they decide whether to tap.
/// A date pill between calendar days, so scrolled history stays anchored in
/// time. "Today" and "Yesterday" by name; further back, the day and date.
struct DayBreak: View {
    let date: Date

    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(Palette.subtext)
                .combChip()
            Spacer()
        }
        .padding(.vertical, Space.xs)
        .accessibilityAddTraits(.isHeader)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }

        // The year appears only once it stops being obvious.
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

private struct ThreadAffordance: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xxs) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(Typography.icon)
                Text(count == 1 ? "1 reply" : "\(count) replies")
                    .font(Typography.label)
                Image(systemName: "chevron.right")
                    .font(Typography.icon)
                    .foregroundStyle(Palette.subtext)
            }
            .foregroundStyle(Palette.text)
            .combChip()
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
    /// Opens the full picker. The quick palette is a menu when absent.
    var onPickEmoji: (() -> Void)?

    var body: some View {
        HStack(spacing: Space.xs) {
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

            // The visible way in, once a pile exists. Before this, reacting
            // was long-press-only, which is knowledge rather than an
            // affordance. Straight to the full picker: the quick palette is
            // already one long-press away, so a menu here would be a second
            // hop to reach the same five.
            Button {
                onPickEmoji?()
            } label: {
                Image(systemName: "plus")
                    .font(Typography.label)
                    .foregroundStyle(Palette.subtext)
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, Space.xxs)
                    .background(Palette.surface.opacity(0.5), in: .capsule)
                    .luminousChrome()
            }
            .buttonStyle(.plain)
            .disabled(onPickEmoji == nil)
            .accessibilityLabel("Add a reaction")
        }
        .padding(.top, Space.xxs)
    }

    private func chip(_ reaction: ReactionSummary) -> some View {
        HStack(spacing: Space.xxs) {
            // Clamped: reaction content arrives from anyone, and rendering a
            // paragraph-long "emoji" would hand every member a banner ad slot.
            // Two grapheme clusters cover every real emoji including flags and
            // family sequences.
            Text(String(reaction.emoji.prefix(2)))
                .font(Typography.emoji)
                .lineLimit(1)
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
    /// Mention suggestions for the token being typed, and what to do with a
    /// pick. Empty when the draft has no open mention.
    var mentionSuggestions: [ProfileSummary] = []
    var onPickMention: (ProfileSummary) -> Void = { _ in }
    /// Owned by the screen, not the bar: the timeline needs to dismiss the
    /// keyboard when someone taps away from it. Declared before `onSend` so
    /// the trailing closure still binds to the send action.
    var focus: FocusState<Bool>.Binding
    let onSend: () -> Void

    @State private var picked: [PhotosPickerItem] = []

    /// Over the relay's 64 KB content ceiling. Practically unreachable by
    /// typing, very reachable by pasting; without this gate the message fails
    /// after a round trip instead of before it.
    private var isTooLong: Bool {
        draft.utf8.count > CommunitySession.maxMessageBytes
    }

    private var canSend: Bool {
        guard attachments?.isUploading != true, !isTooLong else { return false }
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

            if !mentionSuggestions.isEmpty {
                MentionSuggestions(suggestions: mentionSuggestions, onPick: onPickMention)
            }

            if let attachments, !attachments.isEmpty {
                AttachmentTrayView(tray: attachments)
            }

            if isTooLong {
                Label(
                    "Too long for one message. Trim it or split it up.",
                    systemImage: "exclamationmark.circle"
                )
                .font(Typography.caption)
                .foregroundStyle(Palette.danger)
                .padding(.horizontal, Space.sm)
                .padding(.top, Space.xxs)
            }

            // Text on its own row, controls beneath. One surface rather than
            // a field-pill nested inside a bar-pill: the nesting forced the
            // text into a narrow slot between two buttons, and two concentric
            // rounded rectangles a few points apart never stop looking like
            // an accident.
            VStack(alignment: .leading, spacing: Space.xs) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .font(Typography.body)
                    .foregroundStyle(Palette.text)
                    .textFieldStyle(.plain)
                    .focused(focus)
                    .padding(.horizontal, Space.xs)
                    .padding(.top, Space.xxs)
                    // The field is one line tall inside a two-row bar, so
                    // most of the bar is not the field. Without this, tapping
                    // the obvious place to type does nothing.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture { focus.wrappedValue = true }

                HStack(spacing: Space.xs) {
                    if attachments != nil {
                        PhotosPicker(
                            selection: $picked,
                            maxSelectionCount: 4,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            // No `luminousChrome()` here: the picker's label
                            // closure is not main-actor isolated.
                            Image(systemName: "plus")
                                .font(Typography.actionSecondary)
                                .foregroundStyle(Palette.text)
                                .frame(width: Sizing.compactControl, height: Sizing.compactControl)
                                .background(Palette.surface.opacity(0.5), in: .circle)
                                .contentShape(.circle)
                        }
                        .accessibilityLabel("Add a photo")
                    }

                    Spacer(minLength: 0)

                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(Typography.actionSecondary)
                            .foregroundStyle(canSend ? Palette.ink : Palette.subtext)
                            .frame(width: Sizing.compactControl, height: Sizing.compactControl)
                            .background(
                                canSend ? Palette.chartreuse : Palette.surface.opacity(0.5),
                                in: .circle
                            )
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .animation(Motion.fast, value: canSend)
                    .accessibilityLabel("Send message")
                    .disabled(!canSend)
                }
                // Both controls keep a full 44pt target while drawing at 32,
                // so the row stays compact without shrinking what a thumb has
                // to hit.
                .frame(minHeight: Sizing.hitTarget)
            }
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.xxs)
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
                    .font(Typography.action)
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
        /// Whether a new calendar day starts here, which draws a date pill
        /// above the row. Without these, Tuesday reads as today.
        let showsDayBreak: Bool

        var id: String { row.id }
    }

    /// Builds display entries from rows ordered oldest first. Shared with the
    /// thread model so runs and day breaks can never behave differently in
    /// the two places a message renders.
    static func makeEntries(orderedOldestFirst rows: some Sequence<TimelineRow>) -> [Entry] {
        let calendar = Calendar.current
        var entries: [Entry] = []
        var previous: TimelineRow?

        for row in rows {
            let startsRun = previous.map {
                $0.pubkey != row.pubkey || row.createdAt - $0.createdAt > 300
            } ?? true
            let breaksDay = previous.map {
                !calendar.isDate($0.date, inSameDayAs: row.date)
            } ?? true
            entries.append(Entry(row: row, showsHeader: startsRun, showsDayBreak: breaksDay))
            previous = row
        }
        return entries
    }

    private(set) var snapshot = TimelineSnapshot.empty
    private(set) var isLoadingOlder = false
    private(set) var canLoadOlder = true

    private let session: CommunitySession
    private let channel: String
    private var visibleLimit = 80
    private var observation: Task<Void, Never>?
    private let mentions: MentionComposer

    init(session: CommunitySession, channel: String) {
        self.session = session
        self.channel = channel
        self.mentions = MentionComposer(store: session.store, channelID: channel)
    }

    var mentionSuggestions: [ProfileSummary] { mentions.suggestions }
    /// Every roster name, for highlighting mentions in rendered messages.
    var mentionNames: [String] { mentions.candidates.map(\.name) }

    func updateMentionSuggestions(for draft: String) {
        mentions.update(for: draft)
    }

    func completeMention(in draft: String, with profile: ProfileSummary) -> String {
        mentions.complete(draft, with: profile)
    }

    /// Oldest first, with run grouping and day breaks resolved.
    var displayRows: [Entry] {
        Self.makeEntries(orderedOldestFirst: snapshot.rows.reversed())
    }

    func activate() async {
        observe()
        mentions.loadCandidates()
        await markRead()
    }

    /// Marks the channel read on open, and again whenever new messages land
    /// while it is on screen, so a channel you are reading never accumulates a
    /// badge behind your back.
    func markRead() async {
        try? await session.store.markRead(channel: channel)
    }

    func send(_ text: String, attachments: [Blossom.Descriptor] = []) async {
        await session.send(
            text,
            in: channel,
            attachments: attachments,
            mentioning: mentions.mentionedPubkeys(in: text)
        )
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
