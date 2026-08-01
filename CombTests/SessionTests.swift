@testable import Comb
import CombCore
import CombNet
import CombNetTesting
import CombStore
import Foundation
import Testing

/// The join between the socket and the store, with a scripted relay in place of
/// a real one.
///
/// This is the layer that had no test at all. `RelaySession` has always taken a
/// transport; `CommunitySession` simply never forwarded one, so every test of
/// it would have opened a real websocket. Forwarding it is the whole difference
/// between untestable and this file.
@Suite("Community session")
struct CommunitySessionTests {
    /// The path an arriving message actually takes: relay frame, sink,
    /// verified ingest, store. Every previous test of this ended at the sink,
    /// because that was as far as a test could reach.
    @Test("a message on the live subscription reaches the store")
    func liveMessageIsStored() async throws {
        let rig = try await Rig()

        let author = try PrivateKey()
        let message = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "arrived over the wire",
            tags: [["h", Rig.channel]],
            with: author
        )
        try await rig.transport.push(event: message, subscription: rig.liveSubscription)

        try await waitUntil("the message to be stored") {
            ((try? rig.store.timeline(channel: Rig.channel)) ?? []).count == 1
        }
        let stored = try rig.store.timeline(channel: Rig.channel)
        #expect(stored.first?.content == "arrived over the wire")

        await rig.session.stop()
    }

    /// The first half of the verification choke point: the id is a hash over
    /// the event's own contents, so changing the content breaks it.
    ///
    /// Named for what it covers rather than for what it looks like. An earlier
    /// version of this called itself a signature test and was not one: an event
    /// whose content changed is refused by the id check on the line before, and
    /// `isValid` begins with that same check, so the signature was never
    /// consulted. Deleting the entire signature guard from `ingest` left this
    /// case green. `signedByTheWrongKeyIsRejected` is the one that covers it.
    @Test("a message whose content changed after signing is not stored")
    func rewrittenMessageIsRejected() async throws {
        let rig = try await Rig()

        let author = try PrivateKey()
        var forged = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "innocuous",
            tags: [["h", Rig.channel]],
            with: author
        )
        // The content changes and the signature does not, which is exactly what
        // a relay rewriting a message in flight would produce.
        forged = NostrEvent(
            id: forged.id,
            pubkey: forged.pubkey,
            createdAt: forged.createdAt,
            kind: forged.kind,
            tags: forged.tags,
            content: "and now it says something else",
            sig: forged.sig
        )
        try await rig.transport.push(event: forged, subscription: rig.liveSubscription)

        // Nothing to wait for on the negative, so wait for a message that does
        // arrive and assert the forgery never joined it. A bare sleep would
        // pass just as well against a store that had stopped ingesting.
        let honest = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "honest",
            tags: [["h", Rig.channel]],
            with: author
        )
        try await rig.transport.push(event: honest, subscription: rig.liveSubscription)
        try await waitUntil("the honest message to be stored") {
            ((try? rig.store.timeline(channel: Rig.channel)) ?? []).count >= 1
        }

        let stored = try rig.store.timeline(channel: Rig.channel)
        #expect(stored.count == 1)
        #expect(stored.first?.content == "honest")

        await rig.session.stop()
    }

    /// What the session asks the relay for, as opposed to what it does with
    /// the answer.
    ///
    /// The scripted transport routes by subscription id and evaluates no
    /// filters, so it will hand back anything pushed at it regardless of what
    /// was requested: drop `.groupChatMessage` from the session's bootstrap
    /// kinds and every other case here still passes. `BuzzFake` answers a REQ
    /// with what the filters actually match, so this is the case that notices.
    @Test("the bootstrap query asks for the kinds the app renders")
    func bootstrapAsksForChatMessages() async throws {
        let relay = try BuzzFake()
        let key = try PrivateKey()
        let store = try EventStore()

        // History that predates the connection, which is what a bootstrap
        // query is for. Seeded rather than published, because the subject here
        // is the read path.
        let author = try PrivateKey()
        await relay.seed(group: BuzzFake.Group(
            id: Rig.channel,
            name: "Contract",
            members: [key.publicKey.hex, author.publicKey.hex]
        ))
        await relay.seed(events: [
            try NostrEvent.signed(
                kind: .groupChatMessage,
                content: "said before we arrived",
                tags: [["h", Rig.channel]],
                with: author
            ),
        ])

        let session = try CommunitySession(
            url: URL(string: "wss://fake.communities.buzz.xyz")!,
            key: key,
            store: store,
            transport: relay
        )
        try await session.start()

        let stored = try store.timeline(channel: Rig.channel)
        #expect(stored.map(\.content) == ["said before we arrived"])
        await session.stop()
    }

    /// The second half of the choke point, and the half that had no cover: an
    /// event whose id is a correct hash of its own contents, carrying a
    /// signature that is not over that id.
    ///
    /// This is what a relay swapping one member's message for another's
    /// produces, and it is the only shape that reaches the signature guard at
    /// all, because everything cruder is caught by the id check first.
    @Test("a message signed by the wrong key is not stored")
    func signedByTheWrongKeyIsRejected() async throws {
        let rig = try await Rig()

        let author = try PrivateKey()
        let honest = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "honest",
            tags: [["h", Rig.channel]],
            with: author
        )
        // A second, genuinely signed event, so the signature we borrow is a
        // real one over a different message rather than random bytes.
        let elsewhere = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "signed over something else",
            tags: [["h", Rig.channel]],
            with: author
        )
        let forged = NostrEvent(
            id: honest.id,
            pubkey: honest.pubkey,
            createdAt: honest.createdAt,
            kind: honest.kind,
            tags: honest.tags,
            content: honest.content,
            sig: elsewhere.sig
        )
        // The id checks out, which is the whole point: this one gets past the
        // guard that catches a rewritten message.
        #expect(forged.hasValidID)
        #expect(!forged.isValid)

        try await rig.transport.push(event: forged, subscription: rig.liveSubscription)

        let arrives = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "properly signed",
            tags: [["h", Rig.channel]],
            with: author
        )
        try await rig.transport.push(event: arrives, subscription: rig.liveSubscription)
        try await waitUntil("the properly signed message to be stored") {
            ((try? rig.store.timeline(channel: Rig.channel)) ?? []).count >= 1
        }

        let stored = try rig.store.timeline(channel: Rig.channel)
        #expect(stored.count == 1)
        #expect(stored.first?.content == "properly signed")

        await rig.session.stop()
    }

    /// Read state written by another client in the spec's shape reaches this
    /// one's store.
    ///
    /// Sequential rather than concurrent: one `BuzzFake` is one socket, and two
    /// sessions parked in `receive()` at once would take each other's frames.
    /// The desktop app this stands in for is a separate process anyway.
    @Test("a NIP-RS blob from another client moves this device's read line")
    func interopReadStateIsAdopted() async throws {
        let relay = try BuzzFake()
        let key = try PrivateKey()
        let url = URL(string: "wss://fake.communities.buzz.xyz")!
        await relay.seed(group: BuzzFake.Group(
            id: Rig.channel,
            name: "Contract",
            members: [key.publicKey.hex]
        ))

        // What another client would have published: the spec's `d`, the spec's
        // topic tag, the spec's payload, encrypted to this account's own key.
        let blob = ReadStateBlob(clientID: "buzz-desktop", contexts: [Rig.channel: 4000])
        let json = String(decoding: try JSONEncoder().encode(blob), as: UTF8.self)
        let signer = InMemorySigner(key)
        await relay.seed(events: [
            try await signer.sign(
                kind: .appData,
                content: try await signer.encryptToSelf(json),
                tags: [["d", "read-state:aaa111"], ["t", "read-state"]],
                createdAt: Date(timeIntervalSince1970: 9000)
            ),
        ])

        let store = try EventStore()
        let session = try CommunitySession(url: url, key: key, store: store, transport: relay)
        try await session.start()
        // After `start()`, not before: starting mirrors the persisted setting
        // from UserDefaults, which is off in a test bundle, so an earlier call
        // would be overwritten. This is also the order the app uses when the
        // switch is flipped on a running session.
        await session.setSyncsReadState(true)

        try await waitUntil("the read line to move") {
            ((try? store.readMarkers()) ?? []).contains { $0.channelID == Rig.channel }
        }
        let marker = try #require(store.readMarkers().first { $0.channelID == Rig.channel })
        #expect(marker.lastReadAt == 4000)
        // Stamped with the blob's own created_at, which is what lets a later
        // mark-unread on this device outrank it.
        #expect(marker.updatedAt == 9000)

        await session.stop()
    }

    /// What Comb puts on the wire is shaped the way the specification says.
    ///
    /// Asserted against the relay's stored events rather than against the code
    /// that built them, because the tags are the whole interoperability
    /// surface: a blob without its topic tag is invisible to the `#t` fetch
    /// every other client uses, and would look fine from in here.
    @Test("the published blob carries the tags other clients search by")
    func publishesAConformantBlob() async throws {
        let relay = try BuzzFake()
        let key = try PrivateKey()
        let store = try EventStore()
        await relay.seed(group: BuzzFake.Group(
            id: Rig.channel,
            name: "Contract",
            members: [key.publicKey.hex]
        ))
        // A recent read line, because publishing prunes anything older than the
        // spec's seven-day horizon. An epoch-era timestamp is pruned to nothing
        // and publishes no blob at all, which is correct and made the first
        // version of this test fail for a reason that had nothing to do with
        // tags.
        let readAt = Int64(Date().timeIntervalSince1970) - 60
        try await store.mergeReadMarkers([
            ReadMarker(channelID: Rig.channel, lastReadAt: readAt, updatedAt: readAt),
        ])

        let session = try CommunitySession(
            url: URL(string: "wss://fake.communities.buzz.xyz")!,
            key: key,
            store: store,
            transport: relay
        )
        try await session.start()
        // Enabling publishes immediately rather than waiting out the debounce.
        await session.setSyncsReadState(true)

        let published = await relay.stored.filter { event in
            event.tags.contains { $0.first == "d" && $0.count > 1 && $0[1].hasPrefix("read-state:") }
        }
        let blob = try #require(published.first, "a spec-shaped blob should have been published")
        #expect(
            blob.tags.contains { $0 == ["t", "read-state"] },
            "without the topic tag no other client's fetch will find this"
        )

        let json = try await InMemorySigner(key).decryptFromSelf(blob.content)
        let decoded = try #require(
            JSONDecoder().decode(ReadStateBlob.self, from: Data(json.utf8)).validated()
        )
        #expect(decoded.contexts[Rig.channel] == readAt)

        await session.stop()
    }

    /// The deviation from the specification, end to end.
    ///
    /// NIP-RS merges by plain maximum, which would silently undo a deliberate
    /// mark-unread. Comb stamps an incoming blob with its own `created_at` and
    /// lets last-writer-wins decide, so a blob written before the reader's
    /// decision loses to it. The store-level test covers the rule; this covers
    /// the wiring that carries `created_at` into it.
    @Test("a blob written before a mark-unread does not undo it")
    func staleBlobDoesNotUndoMarkUnread() async throws {
        let relay = try BuzzFake()
        let key = try PrivateKey()
        let store = try EventStore()
        let other = "another-channel"
        await relay.seed(group: BuzzFake.Group(
            id: Rig.channel,
            name: "Contract",
            members: [key.publicKey.hex]
        ))

        // The reader marked this unread at 9000, well after the blob below was
        // written.
        try await store.mergeReadMarkers([
            ReadMarker(channelID: Rig.channel, lastReadAt: 10, updatedAt: 9000),
        ])

        let signer = InMemorySigner(key)
        func blob(_ contexts: [String: Int64], at createdAt: Int64, from client: String) async throws -> NostrEvent {
            let json = String(
                decoding: try JSONEncoder().encode(ReadStateBlob(clientID: client, contexts: contexts)),
                as: UTF8.self
            )
            return try await signer.sign(
                kind: .appData,
                content: try await signer.encryptToSelf(json),
                tags: [["d", "read-state:\(client)"], ["t", "read-state"]],
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt))
            )
        }

        // One blob, two contexts. The witness channel has no local marker, so
        // its arrival proves this exact blob was decrypted and merged; the
        // other context is the one that must lose.
        //
        // An earlier version used two separate blobs and could not tell "the
        // stale blob arrived and lost" from "the stale blob never arrived at
        // all", so it passed even when incoming blobs were deliberately stamped
        // with the wrong clock. Waiting on a different blob proves nothing
        // about this one.
        await relay.seed(events: [
            try await blob([Rig.channel: 8000, other: 7000], at: 1000, from: "stale"),
        ])

        let session = try CommunitySession(
            url: URL(string: "wss://fake.communities.buzz.xyz")!,
            key: key,
            store: store,
            transport: relay
        )
        try await session.start()
        await session.setSyncsReadState(true)

        try await waitUntil("the witness context to arrive, proving the blob was merged") {
            ((try? store.readMarkers()) ?? []).contains { $0.channelID == other }
        }

        let marker = try #require(store.readMarkers().first { $0.channelID == Rig.channel })
        #expect(marker.lastReadAt == 10, "a stale blob must not undo a deliberate mark-unread")
        // Distinguishes "the blob arrived and lost" from "the blob never
        // arrived". Without this the case would pass just as happily against a
        // session that had stopped consuming read state altogether.
        #expect(marker.updatedAt == 9000, "the local decision should still be the newest writer")
        await session.stop()
    }

    /// A session wired to a scripted relay, started and authenticated, with its
    /// live subscription id already picked out.
    private struct Rig: Sendable {
        static let channel = "channel-under-test"

        let session: CommunitySession
        let transport: MockTransport
        let store: EventStore
        let liveSubscription: String

        init() async throws {
            let transport = MockTransport()
            await transport.setBehaviour(TransportFixture.answersEverything())
            let store = try EventStore()
            let session = try CommunitySession(
                url: URL(string: "wss://relay.test.invalid")!,
                key: try PrivateKey(),
                store: store,
                transport: transport
            )
            self.transport = transport
            self.store = store
            self.session = session

            // start() does not return until the bootstrap query has, and the
            // bootstrap query does not return until the relay has issued its
            // challenge, so the two have to overlap.
            let started = Task { try await session.start() }
            await transport.push("[\"AUTH\",\"challenge-for-the-session\"]")
            try await started.value

            // Two REQs: the one-shot bootstrap, then the live subscription the
            // app keeps open. It is the second one that carries new traffic.
            let requests = await transport.sent(ofType: "REQ")
            guard let live = requests.last?.subscriptionID, requests.count >= 2 else {
                throw RigError.noLiveSubscription(requests.count)
            }
            liveSubscription = live
        }

        enum RigError: Error, CustomStringConvertible {
            case noLiveSubscription(Int)

            var description: String {
                switch self {
                case .noLiveSubscription(let count):
                    "the session sent \(count) REQ(s) and never opened a live subscription"
                }
            }
        }
    }
}

/// What a strict relay does to the conversation.
///
/// Build 12 shipped with every live filter in one REQ. A relay refuses a REQ by
/// closing the *subscription*, not the offending filter, so the one ask Comb has
/// to make unscoped — zap receipts, which carry no `h` tag because a wallet
/// publishes them — took the whole live feed down with it. Messages stopped
/// arriving, reactions stopped appearing, and nothing said why.
///
/// These are the cases that would have caught it.
@Suite("Live subscription isolation")
struct SubscriptionIsolationTests {
    private static let channel = "room-under-test"

    private func session(
        rules: BuzzFake.Rules,
        key: PrivateKey,
        store: EventStore
    ) async throws -> (CommunitySession, BuzzFake) {
        let relay = try BuzzFake(rules: rules)
        await relay.seed(group: BuzzFake.Group(
            id: Self.channel,
            name: "Contract",
            members: [key.publicKey.hex]
        ))
        let session = try CommunitySession(
            url: URL(string: "wss://fake.communities.buzz.xyz")!,
            key: key,
            store: store,
            transport: relay
        )
        return (session, relay)
    }

    /// The exact shape of the shipped bug.
    @Test("a relay that refuses the unscoped receipt filter still delivers messages")
    func groupScopedRelayKeepsTheConversation() async throws {
        var rules = BuzzFake.Rules()
        rules.refusesKinds = [.zapReceipt]

        let key = try PrivateKey()
        let store = try EventStore()
        let (session, relay) = try await self.session(rules: rules, key: key, store: store)
        try await session.start()

        // Arrives after the connection, so it can only come down a live
        // subscription that survived.
        let author = try PrivateKey()
        await relay.deliver(try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "the conversation continues",
            tags: [["h", Self.channel]],
            with: author
        ))
        try await Task.sleep(for: .milliseconds(200))

        #expect(
            try store.timeline(channel: Self.channel).map(\.content)
                == ["the conversation continues"],
            "an unscoped zap filter must not cost the conversation"
        )
        await session.stop()
    }

    /// The other way the same mistake could be made: Comb's own kinds are not
    /// kinds any relay is obliged to accept.
    @Test("a relay that refuses unknown kinds still delivers messages")
    func unknownKindsDoNotCostTheConversation() async throws {
        var rules = BuzzFake.Rules()
        rules.refusesKinds = [.buzzZapAttestation, .buzzZapIntent]

        let key = try PrivateKey()
        let store = try EventStore()
        let (session, relay) = try await self.session(rules: rules, key: key, store: store)
        try await session.start()

        let author = try PrivateKey()
        await relay.deliver(try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "still here",
            tags: [["h", Self.channel]],
            with: author
        ))
        try await Task.sleep(for: .milliseconds(200))

        #expect(
            try store.timeline(channel: Self.channel).map(\.content) == ["still here"],
            "kinds 40004 and 40005 are unproven, so they must not ride with the conversation"
        )
        await session.stop()
    }

    /// A reaction is the symptom the report led with, and it travels the same
    /// live subscription a message does.
    @Test("reactions still arrive on a relay that refuses the receipt filter")
    func reactionsSurvive() async throws {
        var rules = BuzzFake.Rules()
        rules.refusesKinds = [.zapReceipt]

        let key = try PrivateKey()
        let store = try EventStore()
        let (session, relay) = try await self.session(rules: rules, key: key, store: store)
        try await session.start()

        let author = try PrivateKey()
        let message = try NostrEvent.signed(
            kind: .groupChatMessage, content: "worth a reaction",
            tags: [["h", Self.channel]], with: author
        )
        await relay.deliver(message)
        await relay.deliver(try NostrEvent.signed(
            kind: .reaction, content: "🐝",
            tags: [["e", message.id], ["h", Self.channel]], with: author
        ))
        try await Task.sleep(for: .milliseconds(250))

        let reactions = try store.reactions(for: [message.id], me: key.publicKey.hex)
        #expect(reactions[message.id]?.first?.emoji == "🐝")
        await session.stop()
    }
}
