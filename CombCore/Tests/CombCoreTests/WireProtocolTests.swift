import Foundation
import Testing
@testable import CombCore

@Suite("Filter")
struct FilterTests {
    private func encodeToObject(_ filter: Filter) throws -> [String: Any] {
        let data = try JSONEncoder().encode(filter)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("omits unset fields entirely")
    func omitsUnset() throws {
        let json = try encodeToObject(Filter(kinds: [.groupChatMessage]))
        #expect(json.keys.sorted() == ["kinds"])
        // A null or empty-array field would be interpreted as "match nothing"
        // by some relays rather than "unconstrained".
        #expect(json["authors"] == nil)
    }

    @Test("spells tag filters with a leading hash")
    func spellsTagFilters() throws {
        let filter = Filter(kinds: [.groupChatMessage]).inGroup("room-uuid")
        let json = try encodeToObject(filter)
        #expect(json["#h"] as? [String] == ["room-uuid"])
        #expect(json["h"] == nil)
    }

    @Test("round trips through JSON including tags")
    func roundTrips() throws {
        let original = Filter(
            authors: ["abc"],
            kinds: [.groupChatMessage, .reaction],
            since: 100,
            until: 200,
            limit: 50
        )
        .inGroup("room")
        .taggingPubkey("me")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Filter.self, from: data)

        #expect(decoded == original)
        #expect(decoded.tags["h"] == ["room"])
        #expect(decoded.tags["p"] == ["me"])
    }

    @Test("canonical encoding is byte-stable")
    func canonicalIsStable() throws {
        let filter = Filter(kinds: [.giftWrap])
            .withTag("h", ["a"])
            .withTag("p", ["b"])
            .withTag("e", ["c"])

        // Plain JSONEncoder does NOT guarantee key order, so anything comparing
        // filters as bytes has to go through canonicalJSON.
        #expect(try filter.canonicalJSON() == filter.canonicalJSON())

        let rebuilt = Filter(kinds: [.giftWrap])
            .withTag("e", ["c"])
            .withTag("p", ["b"])
            .withTag("h", ["a"])
        #expect(try filter.canonicalJSON() == rebuilt.canonicalJSON())
        #expect(filter == rebuilt)
    }

    @Test("flags p-gated kinds that lack a pubkey scope")
    func flagsUnscopedGatedKinds() {
        // A Buzz relay refuses these outright. Catching it client-side turns a
        // confusing CLOSED response into a programming error we can fix.
        #expect(Filter(kinds: [.giftWrap]).needsPubkeyScope)
        #expect(Filter(kinds: [.buzzMemberAdded]).needsPubkeyScope)
        #expect(Filter(kinds: [.groupChatMessage, .giftWrap]).needsPubkeyScope)
    }

    @Test("accepts p-gated kinds once scoped")
    func acceptsScopedGatedKinds() {
        #expect(!Filter(kinds: [.giftWrap]).taggingPubkey("me").needsPubkeyScope)
        #expect(!Filter(kinds: [.groupChatMessage]).needsPubkeyScope)
        #expect(!Filter().needsPubkeyScope)
    }
}

@Suite("ClientMessage")
struct ClientMessageTests {
    private func encodeToArray(_ message: ClientMessage) throws -> [Any] {
        let data = try message.encoded()
        return try #require(JSONSerialization.jsonObject(with: data) as? [Any])
    }

    @Test("encodes EVENT as a two element array")
    func encodesEvent() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(kind: .groupChatMessage, content: "hi", with: key)
        let array = try encodeToArray(.event(event))

        #expect(array.count == 2)
        #expect(array[0] as? String == "EVENT")
        let payload = try #require(array[1] as? [String: Any])
        #expect(payload["id"] as? String == event.id)
        #expect(payload["created_at"] != nil)
    }

    @Test("encodes REQ with the subscription id then filters")
    func encodesReq() throws {
        let array = try encodeToArray(.req(
            subscriptionID: "sub1",
            filters: [Filter(kinds: [.groupChatMessage]).inGroup("room"), Filter(kinds: [.reaction])]
        ))

        #expect(array.count == 4)
        #expect(array[0] as? String == "REQ")
        #expect(array[1] as? String == "sub1")
        let first = try #require(array[2] as? [String: Any])
        #expect(first["#h"] as? [String] == ["room"])
    }

    @Test("encodes CLOSE")
    func encodesClose() throws {
        let array = try encodeToArray(.close(subscriptionID: "sub1"))
        #expect(array.count == 2)
        #expect(array[0] as? String == "CLOSE")
        #expect(array[1] as? String == "sub1")
    }

    @Test("encodes AUTH with a signed event")
    func encodesAuth() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.authResponse(
            challenge: "chal",
            relayURL: URL(string: "wss://relay.example")!,
            with: key
        )
        let array = try encodeToArray(.auth(event))

        #expect(array[0] as? String == "AUTH")
        let payload = try #require(array[1] as? [String: Any])
        #expect(payload["kind"] as? Int == 22242)
    }
}

@Suite("RelayMessage")
struct RelayMessageTests {
    private func decode(_ json: String) throws -> RelayMessage {
        try RelayMessage(json: Data(json.utf8))
    }

    @Test("decodes EVENT")
    func decodesEvent() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(kind: .groupChatMessage, content: "hello", with: key)
        let payload = String(data: try JSONEncoder().encode(event), encoding: .utf8)!

        let message = try decode("[\"EVENT\",\"sub1\",\(payload)]")
        guard case .event(let subscription, let decoded) = message else {
            Issue.record("expected an event, got \(message)")
            return
        }
        #expect(subscription == "sub1")
        #expect(decoded == event)
        #expect(decoded.isValid)
    }

    @Test("decodes EOSE")
    func decodesEose() throws {
        #expect(try decode("[\"EOSE\",\"sub1\"]") == .endOfStoredEvents(subscriptionID: "sub1"))
    }

    @Test("decodes an accepted OK")
    func decodesOkAccepted() throws {
        let message = try decode("[\"OK\",\"abc123\",true,\"\"]")
        #expect(message == .ok(eventID: "abc123", accepted: true, message: ""))
    }

    @Test("decodes a rejected OK with a reason")
    func decodesOkRejected() throws {
        let message = try decode("[\"OK\",\"abc123\",false,\"restricted: not a member\"]")
        #expect(message == .ok(
            eventID: "abc123",
            accepted: false,
            message: "restricted: not a member"
        ))
    }

    @Test("tolerates an OK with no trailing message")
    func decodesOkWithoutMessage() throws {
        // Not spec-compliant, but relays in the wild send this.
        #expect(try decode("[\"OK\",\"abc\",true]") == .ok(
            eventID: "abc",
            accepted: true,
            message: ""
        ))
    }

    @Test("decodes CLOSED")
    func decodesClosed() throws {
        #expect(try decode("[\"CLOSED\",\"sub1\",\"auth-required: join first\"]") == .closed(
            subscriptionID: "sub1",
            message: "auth-required: join first"
        ))
    }

    @Test("decodes NOTICE")
    func decodesNotice() throws {
        #expect(try decode("[\"NOTICE\",\"rate limited\"]") == .notice("rate limited"))
    }

    @Test("decodes an AUTH challenge")
    func decodesAuthChallenge() throws {
        #expect(try decode("[\"AUTH\",\"challenge-string\"]") == .authChallenge("challenge-string"))
    }

    @Test("rejects malformed frames")
    func rejectsMalformed() {
        #expect(throws: RelayMessage.DecodingFailure.notAnArray) {
            try decode("{\"not\":\"an array\"}")
        }
        #expect(throws: RelayMessage.DecodingFailure.emptyMessage) {
            try decode("[]")
        }
        #expect(throws: RelayMessage.DecodingFailure.unknownType("FUTURE")) {
            try decode("[\"FUTURE\",\"payload\"]")
        }
        #expect(throws: RelayMessage.DecodingFailure.malformed(type: "EOSE")) {
            try decode("[\"EOSE\"]")
        }
    }
}

@Suite("NIP-42 auth")
struct AuthTests {
    @Test("builds a kind 22242 event bound to relay and challenge")
    func buildsAuthEvent() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.authResponse(
            challenge: "abc-challenge",
            relayURL: URL(string: "wss://designers.communities.buzz.xyz")!,
            with: key
        )

        #expect(event.kind == .clientAuth)
        #expect(event.firstValue(for: "challenge") == "abc-challenge")
        #expect(event.firstValue(for: "relay") == "wss://designers.communities.buzz.xyz")
        #expect(event.content == "")
        #expect(event.isValid)
    }

    @Test("binds the signature to the specific relay")
    func bindsToRelay() throws {
        // The relay tag is what stops a response signed for one relay being
        // replayed against another.
        let key = try PrivateKey()
        let first = try NostrEvent.authResponse(
            challenge: "same",
            relayURL: URL(string: "wss://a.example")!,
            with: key
        )
        let second = try NostrEvent.authResponse(
            challenge: "same",
            relayURL: URL(string: "wss://b.example")!,
            with: key
        )
        #expect(first.id != second.id)
    }
}
