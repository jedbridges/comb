import CombCore
import CombNet
import CombStore
import Foundation

/// One community: a relay session and its store, wired together.
///
/// This is the seam the plan promised: CombNet never imports CombStore, so the
/// app owns the join. Events flow relay → sink → verified ingest → observation
/// → UI, and the UI never touches the socket.
actor CommunitySession {
    /// The relay's own content ceiling (64 KB, `check_content` in Buzz's
    /// SDK). Enforced client-side too, so an over-long message is stopped at
    /// the send button instead of failing after a round trip.
    static let maxMessageBytes = 64 * 1024

    /// Accessible without await: an actor's immutable Sendable storage crosses
    /// isolation freely, and the store is itself an actor.
    nonisolated let store: EventStore
    nonisolated let me: PublicKey
    nonisolated let relayURL: URL

    private let relay: RelaySession
    private let signer: InMemorySigner
    private var liveSubscription: String?

    /// Kinds the app renders. One place, so the bootstrap query and the live
    /// subscription can never drift apart.
    private static let contentKinds: [EventKind] = [
        .groupChatMessage, .reaction, .deletion, .groupDeleteEvent,
        .buzzEdit, .buzzRichContent,
    ]
    private static let stateKinds: [EventKind] = [
        .metadata, .groupMetadata, .groupMembers,
    ]
    /// Kinds that are never stored, so nothing here is ever backfilled and the
    /// store's newest timestamp says nothing about them. Kept separate from the
    /// stored kinds for that reason, and because forgetting to list a kind here
    /// is invisible: the pipeline still runs, it just never receives anything.
    private static let ephemeralKinds: [EventKind] = [
        .buzzTyping,
    ]
    /// Relay-signed notices that this account's membership changed.
    ///
    /// These are how a new channel is learned about while the app is running.
    /// The group state events that describe the channel (39000, 39002) are
    /// stored channel-scoped by Buzz and so never reach a live subscription;
    /// they are only ever answered to a historical query. Without these, being
    /// added to a channel is invisible until the next bootstrap.
    private static let membershipKinds: [EventKind] = [
        .buzzMemberAdded, .buzzMemberRemoved,
    ]

    static func isMembershipChange(_ kind: EventKind) -> Bool {
        membershipKinds.contains(kind)
    }

    /// `store` is injectable for the debug demo, which needs an in-memory
    /// store: the demo seeds fresh random identities every launch, so a
    /// persistent store would accumulate a duplicate cast each time.
    init(url: URL, key: PrivateKey, store: EventStore? = nil) throws {
        self.relayURL = url
        self.me = key.publicKey
        let resolvedStore = try store ?? Self.openStore(host: url.host ?? "unknown")
        self.store = resolvedStore
        self.signer = InMemorySigner(key)

        // The boxes are captured by the sink closures rather than `self`, which
        // does not exist yet during init.
        let box = EphemeralBox()
        self.ephemeralBox = box
        let membership = CallbackBox()
        self.membershipBox = membership
        self.relay = RelaySession(
            url: url,
            signer: signer,
            sink: StoreSink(
                store: resolvedStore,
                onEphemeral: { box.emit($0) },
                onMembershipChange: { membership.fire() }
            )
        )
        membership.handler = { [weak self] in
            Task { await self?.refreshGroupState() }
        }
    }

    private let ephemeralBox: EphemeralBox
    private let membershipBox: CallbackBox

    /// Live ephemeral events (typing, presence), never stored.
    nonisolated func ephemeralEvents() -> AsyncStream<[NostrEvent]> {
        ephemeralBox.stream()
    }

    /// Publishes a typing indicator: kind 20002, empty content, `h` tag,
    /// matching Buzz. Fire and forget and deliberately unqueued: a lost one
    /// is invisible, and a retried one would announce typing that stopped.
    func sendTyping(in channel: String) async {
        guard let event = try? await signer.sign(
            kind: .buzzTyping,
            content: "",
            tags: [["h", channel]]
        ) else { return }
        try? await relay.publish(event)
    }

    /// A per-community on-disk store, so history reads offline and a second
    /// community can never bleed into this one.
    private static func openStore(host: String) throws -> EventStore {
        let directory = URL.applicationSupportDirectory
            .appending(path: "Communities/\(host)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )
        return try EventStore(path: directory.appending(path: "comb.sqlite").path)
    }

    // MARK: - Lifecycle

    func start() async throws {
        Log.session.info("connecting to \(self.relayURL.host ?? "?", privacy: .public)")
        DiagnosticsBuffer.report("session", "connecting to \(relayURL.host ?? "?")")
        try await relay.start()

        // Bootstrap: one round trip, several filters. Group state, profiles,
        // and enough recent traffic that the first paint has substance.
        let bootstrap = try await relay.query(
            [
                Filter(kinds: [.groupMetadata], limit: 200),
                Filter(kinds: [.groupMembers], limit: 200),
                Filter(kinds: [.metadata], limit: 500),
                Filter(kinds: Self.contentKinds, limit: 500),
            ],
            timeout: .seconds(25)
        )
        let result = try await store.ingest(bootstrap)
        Log.session.info("bootstrap ingested \(result.inserted.count) events, \(result.rejected.count) rejected")
        DiagnosticsBuffer.report("session", "bootstrap: \(result.inserted.count) stored, \(result.rejected.count) rejected")

        try await subscribeLive()

        // Anything queued before the app last stopped goes out now. Rows still
        // marked sending are included: that state means we never heard back, and
        // resending is safe because the relay deduplicates by event id.
        await retryPendingSends()
    }

    /// Re-reads the channels this account can see.
    ///
    /// Called when a membership notice says the answer just changed. Buzz
    /// stores group state channel-scoped, so a live subscription never carries
    /// it and a query is the only way to learn a new channel's name and roster.
    /// Failure is not surfaced: the next reconnect bootstraps the same state,
    /// and a toast about a refetch the user never asked for would be noise.
    private func refreshGroupState() async {
        guard let events = try? await relay.query(
            [
                Filter(kinds: [.groupMetadata], limit: 200),
                Filter(kinds: [.groupMembers], limit: 200),
            ],
            timeout: .seconds(15)
        ) else {
            DiagnosticsBuffer.report("session", "membership refresh failed")
            return
        }

        let result = try? await store.ingest(events)
        DiagnosticsBuffer.report(
            "session",
            "membership changed: refreshed \(result?.inserted.count ?? 0) group events"
        )
    }

    /// Connects without holding up the caller, retrying until it works or
    /// the session stops.
    ///
    /// This is what makes launch instant: the store is on disk and every
    /// screen reads from it, so nothing on the critical path needs the
    /// network. The connection banner narrates the attempt, and the built-in
    /// reconnect machinery takes over once a connection has been established
    /// at least once. The retry loop here exists because an *initial* failure
    /// (launching in airplane mode, a dead spot) never reaches that
    /// machinery; without it, one failed first attempt would leave the app
    /// silently offline forever.
    func startResilient() {
        guard connectTask == nil else { return }
        connectTask = Task { [weak self] in
            // Modest and capped: waking from airplane mode should reconnect
            // within seconds, and a dead relay should not be hammered.
            let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(15)]
            var attempt = 0

            while !Task.isCancelled {
                do {
                    try await self?.start()
                    return
                } catch {
                    DiagnosticsBuffer.report(
                        "session",
                        "connect attempt \(attempt + 1) failed: \(error)"
                    )
                    let delay = delays[min(attempt, delays.count - 1)]
                    attempt += 1
                    try? await Task.sleep(for: delay)
                }
            }
        }
    }

    private var connectTask: Task<Void, Never>?

    func stop() async {
        connectTask?.cancel()
        connectTask = nil
        await relay.stop()
    }

    /// Everything the app renders, resuming just before the newest stored
    /// event so nothing between bootstrap and now is missed. Overlap is free:
    /// the store keys on event id.
    private func subscribeLive() async throws {
        let newest = (try? store.newestEventTimestamp())
            ?? Int64(Date().timeIntervalSince1970)
        var filter = Filter(kinds: Self.contentKinds + Self.stateKinds)
        filter.since = newest - 5

        // A second filter rather than more kinds on the first: `since` resumes
        // the stored kinds from where the log left off, and applying that same
        // bound to kinds that are never stored would be meaningless.
        let ephemeral = Filter(kinds: Self.ephemeralKinds)

        // The `p` scope is mandatory, not a courtesy: the relay rejects a
        // subscription to these kinds that does not constrain them to the
        // authenticated pubkey, because otherwise it would leak other people's
        // membership changes.
        let membership = Filter(kinds: Self.membershipKinds).taggingPubkey(me.hex)

        liveSubscription = try await relay.subscribe(
            [filter, ephemeral, membership], label: "live"
        )
    }

    /// Live connection state, for the UI's status indicator.
    func connectionStates() async -> AsyncStream<ConnectionState> {
        await relay.connectionStates()
    }

    // MARK: - Sending

    /// Signs, queues, and delivers a message. The queued row appears in the
    /// timeline immediately through observation; delivery updates its state.
    ///
    /// A reply carries NIP-10 marked tags. Both markers are written even when
    /// replying straight to a thread's opener, where root and parent are the
    /// same event: Buzz reads the `reply` marker to decide something is a reply
    /// at all, so omitting it would post the message flat into the channel.
    func send(
        _ text: String,
        in channel: String,
        replyingTo reply: ReplyContext? = nil,
        attachments: [Blossom.Descriptor] = [],
        mentioning mentionedPubkeys: [String] = []
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An attachment is a message on its own; requiring a caption to send a
        // picture would be a strange rule.
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        var tags = [["h", channel]]
        if let reply {
            tags.append(["e", reply.rootID, "", "root"])
            tags.append(["e", reply.parentID, "", "reply"])
            // So the person being answered can be notified.
            tags.append(["p", reply.authorPubkey])
        }
        tags.append(contentsOf: attachments.map(Blossom.imetaTag))

        // Normalized the way the relay will normalize it anyway: lowercased,
        // deduplicated, self dropped, capped. A reply already tags the person
        // being answered, so that pubkey is in the pool and dedup keeps it
        // from being tagged twice.
        let mentions = Mentions.normalize(mentionedPubkeys, sender: me.hex)
        tags.append(contentsOf: mentions.map { ["p", $0] })

        // The markdown link goes in the body as well as the tag, matching Buzz:
        // a client that does not read NIP-92 still shows a usable link instead
        // of a message that looks empty.
        let body = trimmed + attachments.map(Blossom.markdown).joined()

        do {
            let event = try await signer.sign(
                kind: .groupChatMessage,
                content: body,
                tags: tags
            )
            try await store.enqueue(event, channel: channel)
            await deliver(event)
        } catch {
            // Signing can only fail on a corrupt key, which connect() vetted.
        }
    }

    /// Adds or withdraws a reaction. Toggling off publishes a deletion of our
    /// own reaction event.
    ///
    /// Reactions are fire-and-forget rather than queued: the outbox renders its
    /// rows as timeline messages, and a lost reaction is an annoyance where a
    /// lost message is a betrayal.
    /// Returns whether the relay accepted it, so the caller can say so. A
    /// reaction that silently never landed looks identical to one that did.
    @discardableResult
    func toggleReaction(_ emoji: String, on targetID: String, in channel: String) async -> Bool {
        do {
            if let existing = try store.ownReactionID(
                target: targetID,
                emoji: emoji,
                pubkey: me.hex
            ) {
                let deletion = try await signer.sign(
                    kind: .deletion,
                    content: "",
                    tags: [["e", existing]]
                )
                try await relay.publish(deletion)
                _ = try await store.ingest([deletion])
            } else {
                let reaction = try await signer.sign(
                    kind: .reaction,
                    content: emoji,
                    tags: [["e", targetID], ["h", channel]]
                )
                try await relay.publish(reaction)
                _ = try await store.ingest([reaction])
            }
            return true
        } catch {
            DiagnosticsBuffer.report("session", "reaction failed: \(error)")
            return false
        }
    }

    /// Rewrites one of our own messages, Buzz-style: a kind 40003 event whose
    /// content replaces the target's. The original stays in the log and the
    /// timeline renders the newest edit, so this cannot lose history.
    ///
    /// Published directly rather than queued: an outbox row renders as a
    /// timeline message, so a queued edit would appear as a phantom message
    /// while in flight.
    @discardableResult
    func edit(_ messageID: String, to newText: String, in channel: String) async -> Bool {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        do {
            let event = try await signer.sign(
                kind: .buzzEdit,
                content: trimmed,
                tags: [["h", channel], ["e", messageID]]
            )
            try await relay.publish(event)
            _ = try await store.ingest([event])
            return true
        } catch {
            // Nothing is lost: nothing was replaced locally until the relay
            // accepted it. But the user asked for a change and did not get one,
            // so the caller says so rather than leaving the old text to look
            // like a rendering delay.
            DiagnosticsBuffer.report("session", "edit failed: \(error)")
            return false
        }
    }

    /// Removes one of our own messages: a kind 5 deletion carrying the `h` tag
    /// Buzz requires so channel-scoped subscriptions observe it. The timeline
    /// shows "Message deleted" rather than closing the hole, which is honest:
    /// others may have read it already.
    @discardableResult
    func deleteMessage(_ messageID: String, in channel: String) async -> Bool {
        do {
            let deletion = try await signer.sign(
                kind: .deletion,
                content: "",
                tags: [["h", channel], ["e", messageID]]
            )
            try await relay.publish(deletion)
            _ = try await store.ingest([deletion])
            return true
        } catch {
            // The most important of these to report: someone who believes a
            // message is gone will act as though it is.
            DiagnosticsBuffer.report("session", "delete failed: \(error)")
            return false
        }
    }

    /// Reports a message to whoever moderates the community.
    ///
    /// A NIP-56 kind 1984, published to the community's own relay: the standard
    /// every Nostr moderation tool already reads. Comb runs no moderation
    /// service and will not invent one, so this is a message to the relay's
    /// operators rather than an action with a guaranteed outcome, and the UI
    /// says so.
    ///
    /// Both the message and its author are tagged, because a report about a
    /// person and a report about one thing they said want different responses.
    /// Returns whether the report reached the relay. Telling someone their
    /// report was filed when it never left the device is the worst failure in
    /// this file: they stop expecting anything further and nobody was told.
    @discardableResult
    func report(
        _ messageID: String,
        author: String,
        reason: Report.Reason,
        in channel: String
    ) async -> Bool {
        var tags: [[String]] = [["h", channel]]
        if let type = reason.nip56Type {
            tags.append(["e", messageID, "", type])
            tags.append(["p", author, type])
        } else {
            tags.append(["e", messageID])
            tags.append(["p", author])
        }

        do {
            let report = try await signer.sign(
                kind: .report,
                // Free text is where NIP-56 puts the human explanation, and
                // "other" has no tag type of its own to carry it.
                content: reason.label,
                tags: tags
            )
            try await relay.publish(report)
            // Deliberately not ingested: a report is not part of the
            // conversation and has no business appearing in anyone's timeline.
            return true
        } catch {
            // Blocking already took effect locally, which is the part the
            // reporter can actually rely on, and the sheet says which half
            // worked rather than claiming both did.
            Log.session.error("report failed")
            DiagnosticsBuffer.report("session", "report failed: \(error)")
            return false
        }
    }

    /// Publishes the user's profile.
    ///
    /// Kind 0 replaces the whole document rather than patching it, so the
    /// rename has to carry everything else forward or it deletes it. See
    /// `ProfileDocument.rename(to:preserving:)`, which owns that rule and is
    /// tested against it.
    @discardableResult
    func setProfile(displayName: String) async -> Bool {
        let content = ProfileDocument.rename(
            to: displayName,
            preserving: try? store.profile(pubkey: me.hex)
        )

        guard let data = try? JSONEncoder().encode(content),
              let event = try? await signer.sign(
                  kind: .metadata,
                  content: String(decoding: data, as: UTF8.self)
              )
        else { return false }

        do {
            try await relay.publish(event)
            _ = try await store.ingest([event])
            return true
        } catch {
            // Ingested anyway: the name is what this device believes it is
            // called, and showing the old one back would read as the edit being
            // rejected rather than undelivered.
            _ = try? await store.ingest([event])
            DiagnosticsBuffer.report("session", "profile update failed: \(error)")
            return false
        }
    }

    /// Re-delivers a failed message from its stored payload. No re-signing:
    /// the same event goes out, so the id cannot change under the timeline.
    func retrySend(_ eventID: String) async {
        guard let entry = try? store.pendingSends().first(where: { $0.id == eventID }) else {
            return
        }
        await deliver(entry.event)
    }

    /// Abandons a failed message, removing it from the timeline.
    func discardSend(_ eventID: String) async {
        try? await store.discard(eventID)
    }

    private func deliver(_ event: NostrEvent) async {
        try? await store.markSending(event.id)
        do {
            try await relay.publish(event)
            try await store.confirmSent(event)
        } catch RelayError.publishRejected(let reason) {
            try? await store.markFailed(event.id, error: reason)
        } catch {
            // Connection trouble rather than rejection: retryable, and retried
            // automatically on the next start().
            try? await store.markFailed(event.id, error: nil)
        }
    }

    private func retryPendingSends() async {
        for entry in (try? store.pendingSends()) ?? [] {
            await deliver(entry.event)
        }
    }

    // MARK: - Media

    /// Uploads a file to this community's media store.
    ///
    /// Media lives on the community's own relay, not on a third-party host, so
    /// a picture shared in a private community stays inside it.
    func upload(_ data: Data, mimeType: String) async throws -> Blossom.Descriptor {
        try await BlossomClient().upload(
            data,
            mimeType: mimeType,
            to: relayURL,
            signer: signer
        )
    }

    /// Fetches an attachment's bytes, with the signed header the relay requires.
    func mediaData(for attachment: Blossom.Attachment) async throws -> Data {
        try await BlossomClient().data(for: attachment, signer: signer)
    }

    // MARK: - Zaps

    public enum ZapPreparation {
        /// A payable invoice, ready to hand to a Lightning wallet.
        case invoice(String)
        /// The recipient has no Lightning address, or none that supports
        /// verifiable Nostr zaps.
        case unsupported
        case failed(String)
    }

    /// Turns a zap into a payable Lightning invoice, without ever touching
    /// funds. Builds the signed request, resolves the recipient's LNURL
    /// endpoint, and returns a bolt11 for the OS to route to a wallet.
    func prepareZap(
        toLightningAddress addressString: String,
        recipient: PublicKey,
        amountSats: Int64,
        comment: String,
        messageID: String?
    ) async -> ZapPreparation {
        guard let address = Zap.LightningAddress(addressString) else {
            return .unsupported
        }

        do {
            let request = try await Zap.request(
                amountMillisats: amountSats * 1000,
                recipient: recipient,
                relays: [relayURL],
                comment: comment,
                eventID: messageID,
                with: signer
            )
            let (invoice, _) = try await LNURLClient().prepareZap(
                to: address,
                amountMillisats: amountSats * 1000,
                zapRequest: request
            )
            return .invoice(invoice)
        } catch LNURLClient.Failure.zapsUnsupported {
            return .unsupported
        } catch {
            return .failed("Could not reach the recipient's Lightning wallet.")
        }
    }

    // MARK: - History

    /// Pulls a page of history older than the given moment into the store.
    /// Returns how many events were new, so the caller can stop when the
    /// channel's history is exhausted.
    @discardableResult
    func loadOlder(channel: String, before: Int64) async throws -> Int {
        let older = try await relay.query([
            Filter(kinds: [.groupChatMessage], until: before, limit: 100)
                .inGroup(channel),
        ])
        return try await store.ingest(older).inserted.count
    }
}

/// Fans ephemeral events out to whoever is listening.
///
/// A separate object rather than the session itself: the sink closure is
/// built during `init` before `self` exists, and ephemeral delivery must not
/// hop onto the session actor while the socket is reading.
private final class CallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable () -> Void)?

    var handler: (@Sendable () -> Void)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func fire() {
        lock.withLock { stored }?()
    }
}

private final class EphemeralBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<[NostrEvent]>.Continuation] = [:]

    func stream() -> AsyncStream<[NostrEvent]> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { _ = continuations.removeValue(forKey: id) }
            }
        }
    }

    func emit(_ events: [NostrEvent]) {
        let live = lock.withLock { Array(continuations.values) }
        for continuation in live { continuation.yield(events) }
    }
}

/// What a reply needs to know about the message it answers.
struct ReplyContext: Sendable, Equatable {
    /// The message being answered directly.
    let parentID: String
    /// The message that opened the thread. Equal to `parentID` when answering
    /// the opener itself.
    let rootID: String
    /// The author being answered, tagged so they can be notified.
    let authorPubkey: String

    /// Replying to a message in the channel: it becomes the thread's root.
    init(startingThreadOn row: TimelineRow) {
        self.parentID = row.id
        self.rootID = row.id
        self.authorPubkey = row.pubkey
    }

    /// Replying inside an existing thread, keeping the original root so the
    /// whole thread stays one conversation rather than splintering.
    init(replyingTo row: TimelineRow, inThreadRootedAt root: String) {
        self.parentID = row.id
        self.rootID = root
        self.authorPubkey = row.pubkey
    }
}

/// Forwards relay events into verified ingest, and hands ephemeral kinds to
/// whoever is listening.
///
/// Ephemerals are diverted inside the store rather than written: a typing
/// indicator is false ten seconds later, and storing it would grow the log
/// forever with facts nobody can use. Ingest returns them so they can be
/// broadcast to live listeners and then forgotten.
private struct StoreSink: EventSink {
    let store: EventStore
    let onEphemeral: @Sendable ([NostrEvent]) -> Void
    let onMembershipChange: @Sendable () -> Void

    func ingest(_ events: [NostrEvent], subscription: String) async {
        guard let result = try? await store.ingest(events) else { return }
        if !result.ephemeral.isEmpty { onEphemeral(result.ephemeral) }

        // Keyed on what was newly stored rather than on what arrived, so a
        // relay replaying an old notice after a reconnect does not trigger a
        // refetch of every channel each time.
        let stored = Set(result.inserted)
        if events.contains(where: {
            CommunitySession.isMembershipChange($0.kind) && stored.contains($0.id)
        }) {
            onMembershipChange()
        }
    }

    func endOfStoredEvents(subscription: String) async {}
}
