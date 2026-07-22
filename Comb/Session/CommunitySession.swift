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
        self.relay = RelaySession(
            url: url,
            signer: InMemorySigner(key),
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
