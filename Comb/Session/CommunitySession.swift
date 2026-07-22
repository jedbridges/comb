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
        _ = try await store.ingest(bootstrap)

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

    // MARK: - Sending

    /// Signs, queues, and delivers a message. The queued row appears in the
    /// timeline immediately through observation; delivery updates its state.
    func send(_ text: String, in channel: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            let event = try await signer.sign(
                kind: .groupChatMessage,
                content: trimmed,
                tags: [["h", channel]]
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

/// Forwards relay events into verified ingest. Ephemeral kinds are diverted
/// inside the store and simply dropped here until presence lands.
private struct StoreSink: EventSink {
    let store: EventStore

    func ingest(_ events: [NostrEvent], subscription: String) async {
        _ = try? await store.ingest(events)
    }

    func endOfStoredEvents(subscription: String) async {}
}
