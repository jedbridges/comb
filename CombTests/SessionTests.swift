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
