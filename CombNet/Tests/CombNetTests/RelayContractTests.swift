import CombCore
import Foundation
import Testing
@testable import CombNet
import CombNetTesting

/// What Comb assumes a Buzz relay does, asserted against a relay that actually
/// does it.
///
/// `MockTransport` answers OK to everything and evaluates no filters, so every
/// existing session test would pass against a relay that had changed its rules
/// underneath us. These cases run against `BuzzFake`, which enforces them, and
/// are written through the client's own API so the same cases can be pointed at
/// a real relay in Docker without being rewritten.
///
/// Each case that asserts a refusal is followed by its own falsification: the
/// same case against a relay with that one rule switched off, expecting the
/// opposite outcome. A conformance suite that cannot fail is decoration, and
/// the only proof that a case tests the rule it names is watching it change
/// answer when the rule goes away.
@Suite("Relay contract")
struct RelayContractTests {
    static let channel = "channel-under-contract"

    // MARK: - NIP-42

    @Test("a session authenticates against a relay that checks the challenge, the URL and the clock")
    func authenticates() async throws {
        let relay = try RelayUnderTest.fake()
        let (session, _) = try await relay.connect(as: try PrivateKey())
        #expect(await session.state == .ready)
        await session.stop()
    }

    /// Driven at the transport rather than through `RelaySession`, because the
    /// client always answers correctly: the only way to reach the relay's own
    /// checks is to answer the way an attacker would. What is being pinned here
    /// is that the fake is strict enough for the cases above to mean anything.
    @Test("an auth response is refused unless it quotes the challenge, names this relay, and is fresh")
    func authenticationIsChecked() async throws {
        let url = URL(string: "wss://fake.communities.buzz.xyz")!
        let fake = try BuzzFake()
        let key = try PrivateKey()

        try await fake.open(url: url)
        let challenge = await fake.challenge

        func answer(challenge: String, relay: URL, age: TimeInterval = 0) throws -> Data {
            let event = try NostrEvent.signed(
                kind: .clientAuth,
                content: "",
                tags: [["relay", relay.absoluteString], ["challenge", challenge]],
                createdAt: Date(timeIntervalSinceNow: -age),
                with: key
            )
            let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            return Data("[\"AUTH\",\(json)]".utf8)
        }

        // A signature collected by another relay, replayed here.
        try await fake.send(answer(challenge: challenge, relay: URL(string: "wss://somewhere.else.example")!))
        #expect(await fake.authenticatedAs == nil)

        // The right relay, the wrong challenge: a response captured from an
        // earlier connection.
        try await fake.send(answer(challenge: "challenge-0", relay: url))
        #expect(await fake.authenticatedAs == nil)

        // Right on both counts and an hour stale.
        try await fake.send(answer(challenge: challenge, relay: url, age: 3600))
        #expect(await fake.authenticatedAs == nil)

        try await fake.send(answer(challenge: challenge, relay: url))
        #expect(await fake.authenticatedAs == key.publicKey.hex)
    }

    // MARK: - Group scoping

    @Test("publishing into a group you do not belong to is refused")
    func publishRequiresMembership() async throws {
        let relay = try RelayUnderTest.fake()
        let owner = try PrivateKey()
        let stranger = try PrivateKey()

        let (ownerSession, _) = try await relay.connect(as: owner)
        try await create(Self.channel, with: ownerSession, by: owner)
        await ownerSession.stop()

        let (session, _) = try await relay.connect(as: stranger)
        let message = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "let me in",
            tags: [["h", Self.channel]],
            with: stranger
        )

        await #expect(throws: RelayError.self) {
            _ = try await session.publish(message)
        }
        await session.stop()
    }

    @Test("...and the case notices when the relay stops checking")
    func publishMembershipRuleIsLoadBearing() async throws {
        var loosened = BuzzFake.Rules()
        loosened.scopesToGroupMembership = false
        let relay = try RelayUnderTest.fake(loosened)

        let owner = try PrivateKey()
        let stranger = try PrivateKey()
        let (ownerSession, _) = try await relay.connect(as: owner)
        try await create(Self.channel, with: ownerSession, by: owner)
        await ownerSession.stop()

        let (session, _) = try await relay.connect(as: stranger)
        let message = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "let me in",
            tags: [["h", Self.channel]],
            with: stranger
        )

        // Accepted, because nothing is checking. If this succeeded with the
        // rule on, the case above would be asserting nothing.
        _ = try await session.publish(message)
        await session.stop()
    }

    @Test("a message with no h tag is refused")
    func publishRequiresGroupTag() async throws {
        let relay = try RelayUnderTest.fake()
        let key = try PrivateKey()
        let (session, _) = try await relay.connect(as: key)

        let untagged = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "addressed to nowhere",
            with: key
        )
        await #expect(throws: RelayError.self) {
            _ = try await session.publish(untagged)
        }
        await session.stop()
    }

    @Test("a kind the relay signs itself cannot be published")
    func relaySignedKindsAreRefused() async throws {
        let relay = try RelayUnderTest.fake()
        let key = try PrivateKey()
        let (session, _) = try await relay.connect(as: key)

        let forgedRoster = try NostrEvent.signed(
            kind: .groupMembers,
            content: "",
            tags: [["d", Self.channel], ["p", key.publicKey.hex]],
            with: key
        )
        await #expect(throws: RelayError.self) {
            _ = try await session.publish(forgedRoster)
        }
        await session.stop()
    }

    // MARK: - Filters

    @Test("a query answers with what the filter asked for and nothing else")
    func filtersAreEvaluated() async throws {
        let relay = try RelayUnderTest.fake()
        let key = try PrivateKey()
        let (session, _) = try await relay.connect(as: key)

        try await create(Self.channel, with: session, by: key)
        try await create("another-channel", with: session, by: key)
        _ = try await session.publish(try message("here", in: Self.channel, from: key))
        _ = try await session.publish(try message("elsewhere", in: "another-channel", from: key))

        let hits = try await session.query(
            [Filter(kinds: [.groupChatMessage]).inGroup(Self.channel)],
            timeout: .seconds(2)
        )
        #expect(hits.map(\.content) == ["here"])
        await session.stop()
    }

    @Test("...and the case notices when the relay stops evaluating them")
    func filterEvaluationIsLoadBearing() async throws {
        var loosened = BuzzFake.Rules()
        loosened.evaluatesFilters = false
        let relay = try RelayUnderTest.fake(loosened)
        let key = try PrivateKey()
        let (session, _) = try await relay.connect(as: key)

        try await create(Self.channel, with: session, by: key)
        try await create("another-channel", with: session, by: key)
        _ = try await session.publish(try message("here", in: Self.channel, from: key))
        _ = try await session.publish(try message("elsewhere", in: "another-channel", from: key))

        let hits = try await session.query(
            [Filter(kinds: [.groupChatMessage]).inGroup(Self.channel)],
            timeout: .seconds(2)
        )
        #expect(hits.count > 1, "a relay ignoring filters hands back everything")
        await session.stop()
    }

    // MARK: - The 9007 quirk

    @Test("group state never arrives on a live subscription, only on a later query")
    func groupStateIsQueryOnly() async throws {
        let relay = try RelayUnderTest.fake()
        let key = try PrivateKey()
        let (session, sink) = try await relay.connect(as: key)

        _ = try await session.subscribe([
            Filter(kinds: [.groupMetadata, .groupMembers, .groupChatMessage]),
        ], label: "live")

        try await create(Self.channel, with: session, by: key)
        // Something that does travel live, so the wait below is anchored to an
        // observable event rather than to a sleep.
        _ = try await session.publish(try message("hello", in: Self.channel, from: key))
        try await waitUntil("the chat message") { await sink.events.contains { $0.content == "hello" } }

        let live = await sink.events.map(\.kind)
        #expect(!live.contains(.groupMetadata))
        #expect(!live.contains(.groupMembers))

        // The same events are there for the asking, which is exactly why the
        // client refetches group state when it hears its membership changed.
        let queried = try await session.query(
            [Filter(kinds: [.groupMetadata, .groupMembers])],
            timeout: .seconds(2)
        )
        #expect(queried.contains { $0.kind == .groupMetadata })
        #expect(queried.contains { $0.kind == .groupMembers })
        await session.stop()
    }

    @Test("...and the case notices when the relay stops withholding it")
    func groupStateWithholdingIsLoadBearing() async throws {
        var loosened = BuzzFake.Rules()
        loosened.withholdsGroupStateFromLiveSubscriptions = false
        let relay = try RelayUnderTest.fake(loosened)
        let key = try PrivateKey()
        let (session, sink) = try await relay.connect(as: key)

        _ = try await session.subscribe([Filter(kinds: [.groupMetadata, .groupMembers])], label: "live")
        try await create(Self.channel, with: session, by: key)

        try await waitUntil("group state on the live subscription") {
            await sink.events.contains { $0.kind == .groupMetadata }
        }
        await session.stop()
    }

    // MARK: - Roster notices

    @Test("a membership change arrives as a relay-signed notice on the live subscription")
    func rosterChangesAreAnnounced() async throws {
        let relay = try RelayUnderTest.fake()
        let owner = try PrivateKey()
        let joiner = try PrivateKey()

        let (ownerSession, _) = try await relay.connect(as: owner)
        try await create(Self.channel, with: ownerSession, by: owner)
        await ownerSession.stop()

        let (session, sink) = try await relay.connect(as: joiner)
        _ = try await session.subscribe(
            [Filter(kinds: [.buzzMemberAdded]).taggingPubkey(joiner.publicKey.hex)],
            label: "membership"
        )

        let join = try NostrEvent.signed(
            kind: .groupJoinRequest,
            content: "",
            tags: [["h", Self.channel]],
            with: joiner
        )
        _ = try await session.publish(join)

        try await waitUntil("the membership notice") {
            await sink.events.contains { $0.kind == .buzzMemberAdded }
        }
        let notice = try #require(await sink.events.first { $0.kind == .buzzMemberAdded })
        // Signed by the relay, not by the joiner. A client that accepted this
        // from anyone would let a member forge somebody else's arrival.
        #expect(notice.pubkey == relay.fake?.relayKey.publicKey.hex)
        await session.stop()
    }

    // MARK: - Helpers

    /// Creates a group by publishing 9007, which is what the app does, so the
    /// same line works against a real relay.
    private func create(_ id: String, with session: RelaySession, by key: PrivateKey) async throws {
        let create = try NostrEvent.signed(
            kind: .groupCreate,
            content: "",
            tags: [["h", id], ["name", id]],
            with: key
        )
        _ = try await session.publish(create)
    }

    private func message(_ text: String, in channel: String, from key: PrivateKey) throws -> NostrEvent {
        try NostrEvent.signed(
            kind: .groupChatMessage,
            content: text,
            tags: [["h", channel]],
            with: key
        )
    }
}
