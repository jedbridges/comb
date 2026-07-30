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
        .buzzEdit, .buzzRichContent, .buzzZapAttestation,
    ]
    private static let stateKinds: [EventKind] = [
        .metadata, .groupMetadata, .groupMembers,
    ]
    /// Zap receipts, kept out of `contentKinds` deliberately.
    ///
    /// A kind 9735 is not a group event. It carries no `h` tag, because it is
    /// published by the recipient's wallet rather than by a member, so it can
    /// only be asked for unscoped. A NIP-29 relay that insists every filter name
    /// a group will refuse that, and if it were folded into the main filter the
    /// refusal would take the entire live feed with it. In its own filter, the
    /// worst case is a community with no zap totals, which is the correct
    /// degraded state.
    private static let receiptKinds: [EventKind] = [.zapReceipt]
    /// Kinds that are never stored, so nothing here is ever backfilled and the
    /// store's newest timestamp says nothing about them. Kept separate from the
    /// stored kinds for that reason, and because forgetting to list a kind here
    /// is invisible: the pipeline still runs, it just never receives anything.
    private static let ephemeralKinds: [EventKind] = [
        .buzzTyping, .buzzPresence,
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
    ///
    /// `transport` is injectable for tests. `RelaySession` has always taken
    /// one; this was the layer that never forwarded it, and that omission is
    /// the whole reason the join between relay and store had no test. The
    /// default is the real socket, so no call site in the app changes.
    init(
        url: URL,
        key: PrivateKey,
        store: EventStore? = nil,
        transport: any WebSocketTransport = URLSessionTransport()
    ) throws {
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
        let readState = EphemeralBox()
        self.readStateBox = readState
        self.relay = RelaySession(
            url: url,
            signer: signer,
            sink: StoreSink(
                store: resolvedStore,
                onEphemeral: { box.emit($0) },
                onMembershipChange: { membership.fire() },
                onReadState: { readState.emit($0) }
            ),
            transport: transport
        )
        membership.handler = { [weak self] in
            Task { await self?.refreshGroupState() }
        }
    }

    /// The long-lived work this session owns, started with it and stopped with
    /// it.
    ///
    /// This used to be an unstructured `Task` spawned in `init`, which meant a
    /// session that was never started still had a loop running, and `stop()`
    /// did not stop it. Held here instead, so the lifecycle is one the caller
    /// can see.
    private var readStateTask: Task<Void, Never>?

    private func activate() {
        guard readStateTask == nil else { return }
        let readState = readStateBox
        readStateTask = Task { [weak self] in
            for await events in readState.stream() {
                await self?.receiveReadState(events)
            }
        }
    }

    private let readStateBox: EphemeralBox

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
        _ = try? await relay.publish(event)
    }

    /// Publishes a presence heartbeat: kind 20001, empty content, no tags.
    /// Fire and forget, like typing.
    func sendPresence() async {
        guard let event = try? await signer.sign(
            kind: .buzzPresence,
            content: "",
            tags: []
        ) else { return }
        _ = try? await relay.publish(event)
    }

    /// A per-community on-disk store, so history reads offline and a second
    /// community can never bleed into this one.
    ///
    /// Not private: the activity list reads across every community this device
    /// has joined, and the separation that makes each store safe is the same
    /// separation that means there is no single place to read them all from.
    static func openStore(host: String) throws -> EventStore {
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
        activate()

        // Read here rather than at init, so every entry point (launch, join,
        // pair, community switch) picks it up without each remembering to.
        let sync = await MainActor.run {
            (
                SyncSettings.syncsReadState,
                SyncSettings.readStateSlot,
                SyncSettings.readStateClientID
            )
        }
        syncsReadState = sync.0
        readStateSlot = sync.1
        readStateClientID = sync.2

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
                Filter(kinds: Self.receiptKinds, limit: 200),
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

        // Zaps whose receipts never came. Read paths already ignore an expired
        // attempt, so this is only housekeeping, but without it the table grows
        // forever with rows nothing will ever look at again.
        _ = try? await store.pruneZapAttempts()

        // Only now, at the end: `resume` uses this to tell a reconnect it can
        // replay from a subscription table that exists from one that has to
        // build it from nothing.
        hasStarted = true
    }

    /// Whether a full start has ever completed for this session.
    private var hasStarted = false

    /// Opens a direct message conversation with the given people, and returns
    /// the channel it lands in.
    ///
    /// Kind 41010 is a command, not a message: the relay creates the group,
    /// names it, adds everyone, and answers with the channel id in the OK. So
    /// this publishes and then reads the reply, which is the one place in the
    /// app where an OK carries something worth keeping.
    ///
    /// Idempotent at the relay, which keys on the set of participants: asking
    /// twice returns the same conversation rather than making a second one.
    ///
    /// A Buzz extension with no NIP-29 equivalent, so a plain relay will simply
    /// reject it. That is why the caller is told the reason rather than shown a
    /// spinner that never ends.
    func openDirectMessage(with pubkeys: [String]) async throws -> String {
        let others = Set(pubkeys).subtracting([me.hex]).sorted()
        guard !others.isEmpty else { throw DirectMessageFailure.noRecipients }

        let event = try await signer.sign(
            kind: .buzzOpenDirectMessage,
            content: "",
            tags: others.map { ["p", $0] }
        )
        let response = try await relay.publish(event)

        guard let channelID = CommandResponse.channelID(in: response) else {
            // Accepted but unanswered. The conversation may well exist now, but
            // without the id there is nowhere to send the reader, and guessing
            // would drop them into the wrong room.
            DiagnosticsBuffer.report("session", "dm open returned no channel id: \(response)")
            throw DirectMessageFailure.noChannelReturned
        }

        // The group's metadata is relay-signed and channel-scoped, so it never
        // arrives on the live subscription. Without this the conversation
        // exists but has no name, no roster, and no row in the list.
        await refreshGroupState()
        return channelID
    }

    enum DirectMessageFailure: Error, Equatable {
        case noRecipients
        case noChannelReturned
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

    /// Puts the connection down while the app is in the background.
    ///
    /// The retry loop is cancelled too: a session that went to the background
    /// mid-reconnect would otherwise keep waking to dial a relay nobody is
    /// listening to, which is the shape of a background battery drain.
    func suspend() async {
        connectTask?.cancel()
        connectTask = nil
        await relay.suspend()
    }

    /// Brings it back when the app returns to the foreground.
    ///
    /// No bootstrap and no second `subscribeLive`: the relay replays every
    /// subscription from just before the last event it saw, so whatever landed
    /// during the background arrives through the subscription that was already
    /// open. Bootstrap's wide `limit` backfill earns its cost on a cold start
    /// with nothing to resume from, not here.
    ///
    /// Queued sends go out once the socket is actually back, which is what
    /// waiting on `resume` buys: anything written offline is still in the
    /// outbox, and this is the first moment it can leave.
    func resume() async {
        // Backgrounded before the first connection ever finished, so there is
        // no subscription table to replay and nothing was ever bootstrapped.
        // That needs the full start, not a reconnect.
        guard hasStarted else {
            startResilient()
            return
        }

        await relay.resume()
        await retryPendingSends()
    }

    /// Puts everything this session owns down: the connect retry, both
    /// unstructured tasks, and the socket.
    ///
    /// `hasStarted` is cleared too, and that is not tidiness. `resume()` reads
    /// it to decide between a reconnect and a full start, and a reconnect on a
    /// stopped session does nothing: the relay is not suspended, so its resume
    /// no-ops, and `activate()` is never reached, so the read-state loop stays
    /// gone. A stopped session that came back would have been permanently deaf
    /// on that path. No caller does that today; the point is that `stop()` must
    /// not leave a state only `start()` can undo without saying so.
    func stop() async {
        connectTask?.cancel()
        connectTask = nil
        readStateTask?.cancel()
        readStateTask = nil
        // The debounced read-state publish is the other unstructured task here.
        // Left running, it wakes three seconds after the user switched
        // community, on a session nobody holds, to sign an event for a socket
        // that is closed.
        readStatePublish?.cancel()
        readStatePublish = nil
        hasStarted = false
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

        // Separate for the same reason it is separate in the bootstrap: an
        // unscoped filter is the only way to ask for receipts, and a relay that
        // rejects it should cost only this.
        var receipts = Filter(kinds: Self.receiptKinds)
        receipts.since = newest - 5

        var filters = [filter, ephemeral, membership, receipts]

        // Only this identity's own app data, and only when the feature is on:
        // a subscription is a statement to the relay about what interests you,
        // and there is no reason to make it while the answer is unused.
        if syncsReadState {
            filters.append(Filter(authors: [me.hex], kinds: [.appData]))
        }

        liveSubscription = try await relay.subscribe(filters, label: "live")
    }

    // MARK: - Read state sync

    /// Publishes this device's read markers for its other devices, coalesced.
    ///
    /// Called from every `markRead`, which fires on every scroll to the bottom
    /// of a channel, so it cannot publish eagerly: the debounce turns a burst of
    /// reading into one event. The relay keeps only the newest kind 30078 for a
    /// given `d` tag anyway, so the intermediate ones would be written and
    /// immediately discarded.
    func publishReadState() {
        guard syncsReadState else { return }

        readStatePublish?.cancel()
        readStatePublish = Task { [weak self] in
            try? await Task.sleep(for: Self.readStateDebounce)
            guard !Task.isCancelled else { return }
            await self?.sendReadState()
        }
    }

    /// Publishes this device's read line in both shapes, from one flush.
    ///
    /// Comb's own payload carries an `updatedAt` per marker and so can express
    /// "I marked this unread"; NIP-RS is a grow-only maximum and cannot. Sending
    /// both means another Comb device gets the whole decision and Buzz Desktop
    /// gets the read line, and neither has to be told about the other: the spec
    /// says to ignore any `d` that is not `read-state:`-prefixed, and Comb only
    /// reads its own.
    private func sendReadState() async {
        guard let markers = try? store.readMarkers(), !markers.isEmpty else { return }

        do {
            let payload = ReadStatePayload(markers: markers)
            let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
            let event = try await signer.sign(
                kind: .appData,
                content: try await signer.encryptToSelf(json),
                tags: [["d", ReadStateSync.dTag]]
            )
            try await relay.publish(event)
        } catch {
            // Fire and forget, like the other unqueued publishes: a read marker
            // that did not land is re-sent by the next thing you read, and an
            // alert about it would be about nothing the reader can act on.
            DiagnosticsBuffer.report("session", "read state publish failed: \(error)")
        }

        await sendInteropReadState(markers)
    }

    /// The NIP-RS half.
    ///
    /// Separate from the publish above rather than folded into it, because a
    /// failure in either must not take the other down: they are two claims to
    /// two audiences, and Comb's own devices should not lose sync because a
    /// spec-shaped event was rejected.
    private func sendInteropReadState(_ markers: [ReadMarker]) async {
        let blob = ReadStateBlob(
            clientID: readStateClientID,
            markers: markers,
            now: Int64(Date().timeIntervalSince1970)
        )
        // Everything aged out of the horizon, so there is nothing to say.
        guard !blob.contexts.isEmpty else { return }

        do {
            let json = String(decoding: try JSONEncoder().encode(blob), as: UTF8.self)
            // The specification's clock-skew rule: a blob for our own slot must
            // never carry a `created_at` at or below one we have already
            // published, or a relay applying addressable-replacement keeps the
            // older event and this device stops being able to update itself.
            let now = Int64(Date().timeIntervalSince1970)
            let stamp = now > lastInteropPublishedAt ? now : lastInteropPublishedAt + 1
            let event = try await signer.sign(
                kind: .appData,
                content: try await signer.encryptToSelf(json),
                tags: [
                    ["d", ReadStateSync.interopDTag(slot: readStateSlot)],
                    ["t", ReadStateSync.interopTopic],
                ],
                createdAt: Date(timeIntervalSince1970: TimeInterval(stamp))
            )
            try await relay.publish(event)
            lastInteropPublishedAt = stamp
        } catch {
            DiagnosticsBuffer.report("session", "interop read state publish failed: \(error)")
        }
    }

    /// The newest `created_at` this session has published for its own slot.
    private var lastInteropPublishedAt: Int64 = 0

    /// Folds markers from another device into this one's read state.
    ///
    /// Events not authored by this identity are ignored outright. The
    /// subscription already scopes by author, but a relay is not a thing to be
    /// trusted about whose state this is: read state decides what you are shown
    /// as having already seen, and accepting a stranger's would let them hide
    /// messages from you.
    private func receiveReadState(_ events: [NostrEvent]) async {
        guard syncsReadState else { return }

        for event in events where event.pubkey == me.hex {
            guard let slot = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1]
            else { continue }

            // This subscription is `d`-blind, so both shapes arrive here and so
            // does every other client's unrelated kind 30078. The tag decides
            // which reader, if either, is being addressed.
            if slot == ReadStateSync.dTag {
                await receiveOwnReadState(event)
            } else if slot.hasPrefix(ReadStateSync.interopPrefix) {
                await receiveInteropReadState(event)
            }
        }
    }

    private func receiveOwnReadState(_ event: NostrEvent) async {
        guard let json = try? await signer.decryptFromSelf(event.content),
              let payload = try? JSONDecoder().decode(
                  ReadStatePayload.self, from: Data(json.utf8)
              ),
              payload.version == ReadStatePayload.currentVersion
        else { return }

        // Nothing republished on a merge that changed something: the device
        // that sent this already holds the newer markers, and answering
        // every sync with a sync is how two clients talk forever.
        _ = try? await store.mergeReadMarkers(payload.markers)
    }

    /// A NIP-RS blob, from Buzz Desktop or any other client speaking the spec.
    ///
    /// Stamped with the event's own `created_at`, which is what makes a
    /// deliberate mark-unread survive: Comb's merge is last-writer-wins, so a
    /// blob written before the reader marked something unread loses, and one
    /// written after wins. The spec's own merge is a plain maximum and would
    /// undo the reader's decision.
    private func receiveInteropReadState(_ event: NostrEvent) async {
        guard event.tags.contains(where: {
            $0.count >= 2 && $0[0] == "t" && $0[1] == ReadStateSync.interopTopic
        }) else { return }

        guard let json = try? await signer.decryptFromSelf(event.content),
              let decoded = try? JSONDecoder().decode(ReadStateBlob.self, from: Data(json.utf8)),
              let blob = decoded.validated()
        else { return }

        // Our own echo, coming back off the live subscription. Merging it would
        // be harmless today and is exactly the loop the client id exists to
        // prevent, so it stops here rather than relying on the merge to be a
        // no-op.
        guard blob.clientID != readStateClientID else { return }

        _ = try? await store.mergeReadMarkers(blob.markers(publishedAt: event.createdAt))
    }

    /// Mirrored here rather than read per call, because the setting lives in
    /// UserDefaults on the main actor and this is not it.
    private var syncsReadState = false

    /// This installation's NIP-RS identity, mirrored for the same reason.
    private var readStateSlot = ""
    private var readStateClientID = ""

    /// Applies a change to the setting without waiting for a relaunch.
    ///
    /// Turning it on re-opens the live subscription, because the filter for
    /// this identity's own app data is only sent while the feature is on, and a
    /// subscription that was never made cannot start delivering.
    func setSyncsReadState(_ enabled: Bool) async {
        guard enabled != syncsReadState else { return }
        syncsReadState = enabled

        if let liveSubscription {
            await relay.unsubscribe(liveSubscription)
            self.liveSubscription = nil
        }
        try? await subscribeLive()

        // Whatever this device already knows goes out immediately, rather than
        // waiting for the next thing the user happens to read.
        if enabled { await sendReadState() }
    }

    private var readStatePublish: Task<Void, Never>?
    /// Long enough to swallow a scroll through several channels, short enough
    /// that putting the phone down syncs before the other device is picked up.
    private static let readStateDebounce: Duration = .seconds(3)

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
    ///
    /// The community's own URL goes in, and the fetch refuses anything else. An
    /// attachment names its host in an `imeta` tag written by whoever sent the
    /// message, so without this a single message could point every reader at a
    /// host of the sender's choosing, carrying an authorization signed with the
    /// reader's key.
    func mediaData(for attachment: Blossom.Attachment) async throws -> Data {
        try await BlossomClient().data(for: attachment, servedBy: relayURL, signer: signer)
    }


    // MARK: - Zaps

    /// A payable invoice, plus what is needed to remember the attempt.
    ///
    /// `issuer` is the key the recipient's endpoint signs receipts with. It is
    /// obtainable only by asking that endpoint, and it is the one thing a
    /// receipt cannot be checked without, so it is carried out of here rather
    /// than discarded as it used to be.
    public struct PreparedZap: Equatable, Sendable {
        public let invoice: String
        public let requestID: String
        public let targetID: String?
        public let recipient: String
        public let issuer: String
        public let amountMillisats: Int64
        /// LUD-21, where the host will say whether this invoice was paid.
        ///
        /// Nil on most hosts, since plenty do not implement it. Where it is
        /// present it is the only way a `lightning:` handoff ever learns its
        /// own preimage, and without a preimage there is nothing to attest to.
        public let verify: URL?
        /// The signed kind 9734, kept because an attestation has to embed the
        /// same one the invoice was requested for. Rebuilding it later would
        /// produce a different event id and a different signature.
        public let request: NostrEvent
    }

    public enum ZapPreparation {
        /// A payable invoice, ready to hand to a Lightning wallet.
        case prepared(PreparedZap)
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
            let (invoice, issuer) = try await LNURLClient().prepareZap(
                to: address,
                amountMillisats: amountSats * 1000,
                zapRequest: request
            )
            return .prepared(PreparedZap(
                invoice: invoice.bolt11,
                requestID: request.id,
                targetID: messageID,
                recipient: recipient.hex,
                issuer: issuer.hex,
                amountMillisats: amountSats * 1000,
                verify: invoice.verify,
                request: request
            ))
        } catch let failure as LNURLClient.Failure {
            guard let message = Self.describe(failure, host: address.host) else {
                return .unsupported
            }
            return .failed(message)
        } catch {
            // Signing or encoding the request, which never leaves the device.
            return .failed("Comb could not prepare the zap.")
        }
    }

    /// Fetches one person's profile on demand.
    ///
    /// The bootstrap asks for 500 profiles once, which covers a community until
    /// it does not: someone who joined afterwards, or the five-hundred-and-first
    /// member, has no kind 0 here at all. Every screen then quietly treats them
    /// as someone who set nothing up, and the zap button disappears without
    /// saying why.
    ///
    /// Called when the reader acts on a specific person, never on scroll. One
    /// request for one key is a very different thing from a request per row.
    @discardableResult
    func fetchProfile(pubkey: String) async -> Bool {
        guard let events = try? await relay.query([
            Filter(authors: [pubkey], kinds: [.metadata], limit: 1)
        ]), !events.isEmpty else { return false }

        return (try? await store.ingest(events)) != nil
    }

    /// Remembers that an invoice reached a wallet, and starts watching for it
    /// to settle.
    ///
    /// Called after the OS confirms a wallet took the `lightning:` link, not
    /// when the invoice was made: an invoice nobody opened is not an attempt at
    /// anything. Even then this records only that the handoff happened. Whether
    /// the payment went through is a question only a preimage answers.
    func recordZapHandoff(_ zap: PreparedZap) async {
        do {
            try await store.recordZapAttempt(
                requestID: zap.requestID,
                targetID: zap.targetID,
                recipient: zap.recipient,
                issuer: zap.issuer,
                amountMillisats: zap.amountMillisats
            )
        } catch {
            // A missing pending marker is a worse-looking zap, not a failed one.
            // The payment is already in the wallet's hands either way.
        }

        await attest(zap)
    }

    // MARK: - Paying in place

    /// The wallet connection for this community, when the reader has set one up.
    ///
    /// Injected rather than read, so nothing below the UI reaches into
    /// `UserDefaults` or the Keychain. Nil is the ordinary case and means the
    /// `lightning:` handoff, which is still the only path most readers have.
    private var wallet: NWC.Connection?

    func setWallet(_ connection: NWC.Connection?) {
        wallet = connection
    }

    var hasWallet: Bool { wallet != nil }

    /// What happened when Comb asked a wallet to pay.
    enum ZapPayment {
        /// Settled, with the preimage that proves it. The first time this app
        /// has ever been able to say a zap was paid and mean it.
        case paid
        /// The wallet answered and declined, in words the reader can act on.
        case refused(String)
        /// No answer inside the deadline, or the wallet could not be reached.
        /// Deliberately not a refusal: the payment may have happened, and the
        /// pending marker is the honest state for that.
        case unknown(String)
    }

    /// Pays a prepared zap through the connected wallet.
    ///
    /// Records the attempt first, exactly as the handoff path does. If the app
    /// dies between asking and hearing back, the marker is what stops the zap
    /// vanishing without trace, and a marker for a payment that then failed
    /// simply expires.
    func payZap(_ zap: PreparedZap) async -> ZapPayment {
        guard let wallet else { return .unknown("No wallet is connected.") }

        do {
            try await store.recordZapAttempt(
                requestID: zap.requestID,
                targetID: zap.targetID,
                recipient: zap.recipient,
                issuer: zap.issuer,
                amountMillisats: zap.amountMillisats
            )
        } catch {
            // Same reasoning as the handoff: a missing marker is a worse-looking
            // zap, never a failed one.
        }

        let outcome: NWC.Outcome
        do {
            outcome = try await NWCSession(connection: wallet).pay(zap.invoice)
        } catch let failure as NWCSession.Failure {
            return .unknown(Self.describe(failure))
        } catch NWC.ResponseError.missingPreimage {
            // The wallet says it paid and offers nothing to prove it. Not
            // treated as paid, because Comb would then publish a claim it cannot
            // back, and not as a refusal either, because the money may be gone.
            return .unknown("Your wallet said it paid but did not prove it, so Comb cannot confirm this.")
        } catch {
            return .unknown("Comb could not read your wallet's answer.")
        }

        switch outcome {
        case .paid(let preimage, _):
            // The preimage in hand is exactly what the group needs to verify
            // this, so attest immediately rather than waiting on a receipt that
            // a gated relay will never carry.
            await attest(zap, preimage: preimage)
            return .paid
        case .refused(let code, let message):
            return .refused(NWC.describe(code: code, message: message))
        case .answered:
            return .unknown("Your wallet answered something Comb did not ask.")
        }
    }

    private static func describe(_ failure: NWCSession.Failure) -> String {
        switch failure {
        case .cannotReachRelay:
            "Comb could not reach your wallet."
        case .timedOut:
            "Your wallet did not answer. It may still have paid."
        case .connectionLost:
            "The connection to your wallet dropped. It may still have paid."
        case .encryptionUnsupported:
            "Your wallet cannot talk to Comb securely enough. Reconnect it in Settings."
        case .noWalletFound:
            "Comb could not find your wallet. Reconnect it in Settings."
        }
    }

    /// Turns a settled invoice into an attestation the group can verify.
    ///
    /// Two ways in, one event out. A wallet paid through NIP-47 hands back the
    /// preimage directly, so `preimage` is already known and nothing is polled.
    /// A `lightning:` handoff knows nothing, so the recipient's host is asked
    /// via LUD-21, and where it does not implement that the zap stays a pending
    /// marker until it expires, which is what happens today for every zap.
    ///
    /// Every failure here is silent and costs only the tally. The payment
    /// happened or it did not, entirely between the reader's wallet and the
    /// recipient's, and an error about bookkeeping would be Comb claiming a
    /// part in something it had no part in.
    private func attest(_ zap: PreparedZap, preimage known: String? = nil) async {
        guard let channel = zap.targetID.flatMap(channelOf) else { return }

        let preimage: String
        if let known {
            preimage = known
        } else {
            guard let verify = zap.verify,
                  case .settled(let polled) = await LNURLClient().awaitSettlement(of: verify)
            else { return }
            preimage = polled
        }

        do {
            let attestation = try await Zap.attestation(
                request: zap.request,
                bolt11: zap.invoice,
                preimage: preimage,
                groupID: channel,
                with: signer
            )
            // Verified before publishing, against the same function every other
            // client will run. Publishing an attestation that does not check
            // out would put a claim in the log that every reader silently
            // drops, which looks exactly like the payment never happening.
            _ = try Zap.verifyAttestation(attestation)

            _ = try await relay.publish(attestation)
            _ = try await store.ingest([attestation])
        } catch {
            // Left as a pending marker, which then expires. Honest either way.
        }
    }

    /// The channel a message was posted in, read from the log.
    private nonisolated func channelOf(_ messageID: String) -> String? {
        try? store.channel(ofEvent: messageID)
    }

    /// What the recipient's endpoint will actually accept.
    public enum ZapLimits {
        case limits(low: Int64, high: Int64, commentLength: Int)
        case unsupported
        case failed(String)
    }

    /// Asks the recipient's endpoint what it accepts, before the reader commits
    /// to an amount.
    ///
    /// Without this the amounts on offer are guesses: a recipient whose minimum
    /// sits above every preset cannot be zapped at all, and the reader only
    /// finds out after choosing. The cost is that opening the sheet now touches
    /// the recipient's wallet host, which is a request Comb did not previously
    /// make until the reader committed.
    func zapLimits(toLightningAddress addressString: String) async -> ZapLimits {
        guard let address = Zap.LightningAddress(addressString) else {
            return .unsupported
        }
        do {
            let endpoint = try await LNURLClient().endpoint(for: address)
            guard endpoint.supportsNostrZaps else { return .unsupported }
            return .limits(
                low: endpoint.minSendable,
                high: endpoint.maxSendable,
                commentLength: endpoint.allowedCommentLength
            )
        } catch let failure as LNURLClient.Failure {
            guard let message = Self.describe(failure, host: address.host) else {
                return .unsupported
            }
            return .failed(message)
        } catch {
            return .failed("Comb could not reach \(address.host).")
        }
    }

    /// Turns an LNURL failure into a sentence the reader can act on. Returns nil
    /// when the failure means "this recipient cannot receive zaps", which the
    /// caller reports as a state rather than an error.
    ///
    /// Worth being exhaustive rather than defaulting: the case this replaced
    /// reported an amount rejection, which carries the exact bounds it should
    /// have printed, as "could not reach the recipient's wallet". Naming the
    /// host matters too, since it is the recipient's wallet provider and not
    /// Comb or the relay that is failing.
    private static func describe(
        _ failure: LNURLClient.Failure,
        host: String
    ) -> String? {
        switch failure {
        case .noLightningAddress, .zapsUnsupported:
            return nil

        case .amountOutOfRange(let low, let high):
            return "\(host) accepts between \((low / 1000).formatted()) and "
                + "\((high / 1000).formatted()) sats."

        case .endpointUnreachable, .invoiceUnreachable:
            return "Could not reach \(host)."

        case .endpointRejected(let status), .invoiceRejected(let status):
            return "\(host) answered with an error (\(status))."

        // The host's own words. Sanitised in LNURLClient, and rendered as plain
        // text, never as markup.
        case .endpointError(let reason), .invoiceError(let reason):
            return "\(host) said: \(reason)"

        case .malformedEndpoint, .malformedInvoice:
            return "\(host) answered with something Comb could not read."
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
    let onReadState: @Sendable ([NostrEvent]) -> Void

    func ingest(_ events: [NostrEvent], subscription: String) async {
        guard let result = try? await store.ingest(events) else { return }
        if !result.ephemeral.isEmpty { onEphemeral(result.ephemeral) }

        // Handed over whether or not the store considered them new: a kind
        // 30078 is addressable, so a replay after a reconnect carries the same
        // event id the log already holds, and the markers inside it are still
        // the newest another device published.
        let readState = events.filter { $0.kind == .appData }
        if !readState.isEmpty { onReadState(readState) }

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
