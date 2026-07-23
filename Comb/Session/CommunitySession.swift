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

    /// `store` is injectable for the debug demo, which needs an in-memory
    /// store: the demo seeds fresh random identities every launch, so a
    /// persistent store would accumulate a duplicate cast each time.
    init(url: URL, key: PrivateKey, store: EventStore? = nil) throws {
        self.relayURL = url
        self.me = key.publicKey
        let resolvedStore = try store ?? Self.openStore(host: url.host ?? "unknown")
        self.store = resolvedStore
        self.signer = InMemorySigner(key)
        self.relay = RelaySession(
            url: url,
            signer: signer,
            sink: StoreSink(store: resolvedStore)
        )
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

    func stop() async {
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

        liveSubscription = try await relay.subscribe([filter], label: "live")
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
        attachments: [Blossom.Descriptor] = []
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
    func toggleReaction(_ emoji: String, on targetID: String, in channel: String) async {
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
        } catch {
            // Dropped on failure, by design. The next tap tries again.
        }
    }

    /// Publishes the user's profile. Kind 0 is replaceable per pubkey, so this
    /// overwrites any previous name; both `name` and `display_name` are set
    /// because clients disagree about which one they read.
    func setProfile(displayName: String) async {
        let content: [String: String] = ["name": displayName, "display_name": displayName]
        guard let data = try? JSONEncoder().encode(content),
              let event = try? await signer.sign(
                  kind: .metadata,
                  content: String(decoding: data, as: UTF8.self)
              )
        else { return }

        try? await relay.publish(event)
        _ = try? await store.ingest([event])
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

/// Forwards relay events into verified ingest. Ephemeral kinds are diverted
/// inside the store and simply dropped here until presence lands.
private struct StoreSink: EventSink {
    let store: EventStore

    func ingest(_ events: [NostrEvent], subscription: String) async {
        _ = try? await store.ingest(events)
    }

    func endOfStoredEvents(subscription: String) async {}
}
