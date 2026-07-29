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

    /// The verification choke point, reached the way a hostile relay would
    /// reach it, rather than by calling `ingest` directly.
    @Test("a message whose signature does not check is not stored")
    func forgedMessageIsRejected() async throws {
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
