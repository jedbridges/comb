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
/// against a real Buzz relay in Docker when `COMB_LIVE_RELAY` names one.
///
/// Running against both is the entire point. The fake pins our *model* of the
/// relay; only the real thing can tell us the model is wrong. So no case
/// reaches into the fake to set something up: a group is created by publishing
/// 9007 and joined by publishing 9021, exactly as the app does, because those
/// are the only moves that work against both.
///
/// Two consequences of that discipline are worth naming, because they look
/// like fussiness until you run against a live relay. Every case makes its own
/// group id, since a real relay remembers the last case's. And every case
/// makes its own keys, since a real relay remembers those too.
///
/// The cases that assert a refusal are each followed by a falsification: the
/// same case with that one rule switched off in the fake, expecting the
/// opposite answer. A conformance suite that cannot fail is decoration, and
/// the only proof a case tests the rule it names is watching it change answer
/// when the rule goes away. Those are fake-only by nature; you cannot ask a
/// real relay to stop enforcing something.
@Suite("Relay contract")
struct RelayContractTests {
    /// A group id nothing else will use, so cases stay independent against a
    /// relay with a memory.
    static func newChannel() -> String {
        "contract-\(UUID().uuidString.prefix(8))"
    }

    // MARK: - NIP-42

    @Test("a session authenticates", arguments: RelayTarget.available)
    func authenticates(_ target: RelayTarget) async throws {
        let relay = try target.relay()
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

    @Test("publishing into a group you do not belong to is refused", arguments: RelayTarget.available)
    func publishRequiresMembership(_ target: RelayTarget) async throws {
        let relay = try target.relay()
        let channel = Self.newChannel()
        let owner = try PrivateKey()
        let stranger = try PrivateKey()

        let (ownerSession, _) = try await relay.connect(as: owner)
        try await create(channel, with: ownerSession, by: owner)
        await ownerSession.stop()

        let (session, _) = try await relay.connect(as: stranger)
        await #expect(throws: RelayError.self) {
            _ = try await session.publish(try message("let me in", in: channel, from: stranger))
        }
        await session.stop()
    }

    @Test("...and the case notices when the relay stops checking")
    func publishMembershipRuleIsLoadBearing() async throws {
        var loosened = BuzzFake.Rules()
        loosened.scopesToGroupMembership = false
        let relay = try RelayUnderTest.fake(loosened)
        let channel = Self.newChannel()

        let owner = try PrivateKey()
        let stranger = try PrivateKey()
        let (ownerSession, _) = try await relay.connect(as: owner)
        try await create(channel, with: ownerSession, by: owner)
        await ownerSession.stop()

        // Accepted, because nothing is checking. If this succeeded with the
        // rule on, the case above would be asserting nothing.
        let (session, _) = try await relay.connect(as: stranger)
        _ = try await session.publish(try message("let me in", in: channel, from: stranger))
        await session.stop()
    }

    @Test("a message with no h tag is refused", arguments: RelayTarget.available)
    func publishRequiresGroupTag(_ target: RelayTarget) async throws {
        let relay = try target.relay()
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

    /// Named for what it actually covers. `RelaySession.publish` refuses these
    /// kinds itself, before authentication and before a frame is sent, so this
    /// case never reaches a relay and would pass against one that accepted
    /// forged rosters happily. It was previously called "a kind the relay signs
    /// itself cannot be published", which claimed a contract it does not test.
    @Test("the client refuses to publish a kind the relay signs, without asking")
    func relaySignedKindsAreRefusedByTheClient() async throws {
        let relay = try RelayUnderTest.fake()
        let key = try PrivateKey()
        let (session, _) = try await relay.connect(as: key)

        let forgedRoster = try NostrEvent.signed(
            kind: .groupMembers,
            content: "",
            tags: [["d", Self.newChannel()], ["p", key.publicKey.hex]],
            with: key
        )
        await #expect(throws: RelayError.self) {
            _ = try await session.publish(forgedRoster)
        }

        // The evidence that this is a client-side refusal rather than a relay
        // one: nothing went out.
        let published = await relay.fake?.sent(ofType: "EVENT").count
        #expect(published == 0)
        await session.stop()
    }

    /// And the relay's own rule, reached the only way it can be: by putting the
    /// frame on the wire directly, as a client that lacked that guard would.
    @Test("the relay refuses a kind it signs itself")
    func relaySignedKindsAreRefusedByTheRelay() async throws {
        let fake = try BuzzFake()
        let url = URL(string: "wss://fake.communities.buzz.xyz")!
        let key = try PrivateKey()
        try await fake.open(url: url)
        _ = try await fake.receive()

        let authResponse = try NostrEvent.authResponse(
            challenge: await fake.challenge,
            relayURL: url,
            with: key
        )
        try await fake.send(Self.frame("AUTH", authResponse))

        let forgedRoster = try NostrEvent.signed(
            kind: .groupMembers,
            content: "",
            tags: [["d", Self.newChannel()], ["p", key.publicKey.hex]],
            with: key
        )
        try await fake.send(Self.frame("EVENT", forgedRoster))

        #expect(await fake.stored.contains { $0.id == forgedRoster.id } == false)
    }

    /// Presence carries no group at all, and retracting a reaction carries only
    /// the `e` tag of the reaction it withdraws.
    ///
    /// These two exist because the fake got them wrong. It demanded an `h` tag
    /// on both, which would have meant presence silently never landing and
    /// un-reacting silently failing, against a suite whose whole purpose is to
    /// notice that. Deleting a message does carry a group, which is what made
    /// the mistake easy: one of the two kind 5 paths looks group-scoped.
    @Test("presence carries no group", arguments: RelayTarget.available)
    func presenceNeedsNoGroup(_ target: RelayTarget) async throws {
        let relay = try target.relay()
        let key = try PrivateKey()
        let (session, _) = try await relay.connect(as: key)

        // Signed exactly as CommunitySession.sendPresence signs it.
        let presence = try NostrEvent.signed(kind: .buzzPresence, content: "", with: key)
        _ = try await session.publish(presence)
        await session.stop()
    }

    @Test("withdrawing a reaction carries no group", arguments: RelayTarget.available)
    func reactionRetractionNeedsNoGroup(_ target: RelayTarget) async throws {
        let relay = try target.relay()
        let channel = Self.newChannel()
        let key = try PrivateKey()
        let (session, _) = try await relay.connect(as: key)
        try await create(channel, with: session, by: key)

        let reaction = try NostrEvent.signed(
            kind: .reaction,
            content: "🐝",
            tags: [["e", "some-message-id"], ["h", channel]],
            with: key
        )
        _ = try await session.publish(reaction)

        // Signed exactly as CommunitySession.toggleReaction signs the retraction:
        // an `e` tag and nothing else.
        let retraction = try NostrEvent.signed(
            kind: .deletion,
            content: "",
            tags: [["e", reaction.id]],
            with: key
        )
        _ = try await session.publish(retraction)
        await session.stop()
    }

    // MARK: - Filters

    @Test("a query answers with what the filter asked for and nothing else", arguments: RelayTarget.available)
    func filtersAreEvaluated(_ target: RelayTarget) async throws {
        let relay = try target.relay()
        let here = Self.newChannel()
        let elsewhere = Self.newChannel()
        let key = try PrivateKey()
        let (session, _) = try await relay.connect(as: key)

        try await create(here, with: session, by: key)
        try await create(elsewhere, with: session, by: key)
        _ = try await session.publish(try message("here", in: here, from: key))
        _ = try await session.publish(try message("elsewhere", in: elsewhere, from: key))

        let hits = try await session.query(
            [Filter(kinds: [.groupChatMessage]).inGroup(here)],
            timeout: .seconds(5)
        )
        #expect(hits.map(\.content) == ["here"])
        await session.stop()
    }

    @Test("...and the case notices when the relay stops evaluating them")
    func filterEvaluationIsLoadBearing() async throws {
        var loosened = BuzzFake.Rules()
        loosened.evaluatesFilters = false
        let relay = try RelayUnderTest.fake(loosened)
        let here = Self.newChannel()
        let elsewhere = Self.newChannel()
        let key = try PrivateKey()
        let (session, _) = try await relay.connect(as: key)

        try await create(here, with: session, by: key)
        try await create(elsewhere, with: session, by: key)
        _ = try await session.publish(try message("here", in: here, from: key))
        _ = try await session.publish(try message("elsewhere", in: elsewhere, from: key))

        let hits = try await session.query(
            [Filter(kinds: [.groupChatMessage]).inGroup(here)],
            timeout: .seconds(2)
        )
        #expect(hits.count > 1, "a relay ignoring filters hands back everything")
        await session.stop()
    }

    // MARK: - The 9007 quirk

    @Test("group state never arrives live, only on a later query", arguments: RelayTarget.available)
    func groupStateIsQueryOnly(_ target: RelayTarget) async throws {
        let relay = try target.relay()
        let channel = Self.newChannel()
        let key = try PrivateKey()
        let (session, sink) = try await relay.connect(as: key)

        _ = try await session.subscribe([
            Filter(kinds: [.groupMetadata, .groupMembers, .groupChatMessage]),
        ], label: "live")

        try await create(channel, with: session, by: key)
        // Something that does travel live, so the wait below is anchored to an
        // observable event rather than to a sleep.
        _ = try await session.publish(try message("hello", in: channel, from: key))
        try await waitUntil("the chat message") { await sink.events.contains { $0.content == "hello" } }

        let live = await sink.events.map(\.kind)
        #expect(!live.contains(.groupMetadata))
        #expect(!live.contains(.groupMembers))

        // The same events are there for the asking, which is exactly why the
        // client refetches group state when it hears its membership changed.
        let queried = try await session.query(
            [Filter(kinds: [.groupMetadata, .groupMembers])],
            timeout: .seconds(5)
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
        let channel = Self.newChannel()
        let key = try PrivateKey()
        let (session, sink) = try await relay.connect(as: key)

        _ = try await session.subscribe([Filter(kinds: [.groupMetadata, .groupMembers])], label: "live")
        try await create(channel, with: session, by: key)

        try await waitUntil("group state on the live subscription") {
            await sink.events.contains { $0.kind == .groupMetadata }
        }
        await session.stop()
    }

    // MARK: - Roster notices

    @Test("a membership change is announced by the relay", arguments: RelayTarget.available)
    func rosterChangesAreAnnounced(_ target: RelayTarget) async throws {
        let relay = try target.relay()
        let channel = Self.newChannel()
        let owner = try PrivateKey()
        let joiner = try PrivateKey()

        let (ownerSession, _) = try await relay.connect(as: owner)
        try await create(channel, with: ownerSession, by: owner)
        await ownerSession.stop()

        let (session, sink) = try await relay.connect(as: joiner)
        _ = try await session.subscribe(
            [Filter(kinds: [.buzzMemberAdded]).taggingPubkey(joiner.publicKey.hex)],
            label: "membership"
        )

        let join = try NostrEvent.signed(
            kind: .groupJoinRequest,
            content: "",
            tags: [["h", channel]],
            with: joiner
        )
        _ = try await session.publish(join)

        try await waitUntil("the membership notice") {
            await sink.events.contains { $0.kind == .buzzMemberAdded }
        }
        let notice = try #require(await sink.events.first { $0.kind == .buzzMemberAdded })
        // Signed by the relay, not by the joiner. A client that accepted this
        // from anyone would let a member forge somebody else's arrival.
        #expect(notice.pubkey != joiner.publicKey.hex)
        if let fake = relay.fake {
            #expect(notice.pubkey == fake.relayKey.publicKey.hex)
        }
        await session.stop()
    }

    // MARK: - The 41010 command

    @Test("opening a direct message answers with the channel it made", arguments: RelayTarget.available)
    func directMessageOpenReturnsAChannel(_ target: RelayTarget) async throws {
        let relay = try target.relay()
        let me = try PrivateKey()
        let them = try PrivateKey()
        let (session, _) = try await relay.connect(as: me)

        let open = try NostrEvent.signed(
            kind: .buzzOpenDirectMessage,
            content: "",
            tags: [["p", them.publicKey.hex]],
            with: me
        )
        let response = try await session.publish(open)

        // The only acknowledgement in the protocol that carries data rather
        // than a verdict. Everything else the client reads from an OK is yes
        // or no.
        let channel = try #require(CommandResponse.channelID(in: response))
        #expect(!channel.isEmpty)

        // And the conversation's metadata is query-only like any other group
        // state, which is why the client refetches after opening one rather
        // than waiting for it to arrive.
        let state = try await session.query(
            [Filter(kinds: [.groupMetadata])],
            timeout: .seconds(5)
        )
        #expect(state.contains { $0.tags.contains { $0 == ["d", channel] } })
        await session.stop()
    }

    @Test("opening the same conversation twice returns the same channel", arguments: RelayTarget.available)
    func directMessageOpenIsIdempotent(_ target: RelayTarget) async throws {
        let relay = try target.relay()
        let me = try PrivateKey()
        let them = try PrivateKey()
        let (session, _) = try await relay.connect(as: me)

        // Distinct whole seconds, not a random offset. `created_at` is seconds,
        // so two draws from a thirty-second window collided about one run in
        // thirty, produced byte-identical events, and the second open came back
        // as a duplicate with no channel id in it.
        func open(secondsAgo: TimeInterval) async throws -> String? {
            let event = try NostrEvent.signed(
                kind: .buzzOpenDirectMessage,
                content: "",
                tags: [["p", them.publicKey.hex]],
                createdAt: Date(timeIntervalSinceNow: -secondsAgo),
                with: me
            )
            return CommandResponse.channelID(in: try await session.publish(event))
        }

        let first = try await open(secondsAgo: 60)
        let second = try await open(secondsAgo: 1)
        #expect(first != nil)
        #expect(first == second, "tapping message on a profile twice must not make two conversations")
        await session.stop()
    }

    // MARK: - Storage classes

    @Test("typing reaches a live subscriber and is never stored", arguments: RelayTarget.available)
    func ephemeralsAreNotKept(_ target: RelayTarget) async throws {
        let relay = try target.relay()
        let channel = Self.newChannel()
        let key = try PrivateKey()
        let (session, sink) = try await relay.connect(as: key)
        try await create(channel, with: session, by: key)

        _ = try await session.subscribe([Filter(kinds: [.buzzTyping])], label: "typing")
        let typing = try NostrEvent.signed(
            kind: .buzzTyping,
            content: "",
            tags: [["h", channel]],
            with: key
        )
        _ = try await session.publish(typing)

        try await waitUntil("the typing indicator") {
            await sink.events.contains { $0.kind == .buzzTyping }
        }
        // Delivered and forgotten. A relay that kept these would answer a
        // reconnect's backfill with a pile of people who stopped typing hours
        // ago.
        let history = try await session.query([Filter(kinds: [.buzzTyping])], timeout: .seconds(5))
        #expect(history.isEmpty)
        await session.stop()
    }

    @Test("a newer read-state marker replaces the one before it", arguments: RelayTarget.available)
    func addressableEventsAreReplaced(_ target: RelayTarget) async throws {
        let relay = try target.relay()
        let key = try PrivateKey()
        let identifier = "comb.readstate.\(UUID().uuidString.prefix(8))"
        let (session, _) = try await relay.connect(as: key)

        func publishMarker(_ content: String, at age: TimeInterval) async throws {
            let event = try NostrEvent.signed(
                kind: .appData,
                content: content,
                tags: [["d", identifier]],
                createdAt: Date(timeIntervalSinceNow: -age),
                with: key
            )
            _ = try await session.publish(event)
        }

        try await publishMarker("older", at: 60)
        try await publishMarker("newer", at: 0)
        // Out of order too, which is not hypothetical: two devices with skewed
        // clocks, or an outbox flushing after an offline stretch, both deliver
        // read state late. A relay that kept the straggler alongside the
        // current marker would hand the other device a superseded one.
        try await publishMarker("stale straggler", at: 120)

        // Read-state sync publishes one of these per change under the same `d`
        // tag and relies on the relay keeping only the newest. If it kept both,
        // a second device would apply a superseded marker and unread counts
        // would walk backwards.
        let markers = try await session.query(
            [Filter(authors: [key.publicKey.hex], kinds: [.appData]).withTag("d", [identifier])],
            timeout: .seconds(5)
        )
        #expect(markers.map(\.content) == ["newer"])
        await session.stop()
    }

    @Test("account-level events need no group", arguments: RelayTarget.available)
    func profileAndReportCarryNoGroupTag(_ target: RelayTarget) async throws {
        let relay = try target.relay()
        let key = try PrivateKey()
        let (session, _) = try await relay.connect(as: key)

        // The h-tag rule must not overreach. A profile belongs to an account,
        // not a channel, and a relay demanding a group for one would break
        // setting a display name before joining anything.
        let profile = try NostrEvent.signed(
            kind: .metadata,
            content: #"{"display_name":"Somebody"}"#,
            with: key
        )
        _ = try await session.publish(profile)

        let report = try NostrEvent.signed(
            kind: .report,
            content: "spam",
            tags: [["p", try PrivateKey().publicKey.hex, "spam"]],
            with: key
        )
        _ = try await session.publish(report)
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

    /// A wire frame, for the cases that have to bypass the client entirely.
    static func frame(_ type: String, _ event: NostrEvent) throws -> Data {
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        return Data("[\"\(type)\",\(json)]".utf8)
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
