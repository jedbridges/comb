import Foundation
import Testing
@testable import CombCore

@Suite("Canonical serialization")
struct CanonicalJSONTests {
    static let pubkey = "6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93"

    // Every expected id below was produced by an independent Python
    // implementation using json.dumps(separators=(',',':'), ensure_ascii=False),
    // which is the reference behaviour NIP-01 describes.

    @Test("matches the reference id for a plain note")
    func plainNote() {
        let id = NostrEvent.computeID(
            pubkey: Self.pubkey,
            createdAt: 1_673_347_337,
            kind: .textNote,
            tags: [],
            content: "Hello"
        )
        #expect(id.hex == "63966d99a69e83b30f771d8b0079ff1d09290a838c1e4c8781db779cb6516cc9")
    }

    @Test("matches the reference id for a tagged group message")
    func taggedMessage() {
        let id = NostrEvent.computeID(
            pubkey: Self.pubkey,
            createdAt: 1_700_000_000,
            kind: .groupChatMessage,
            tags: [["h", "channel-uuid-1"], ["e", "abc123", "", "reply"]],
            content: "hi there"
        )
        #expect(id.hex == "e12dbea4e81b6578e7e9dcd735c1a00a2a07adcc41dd889f5c8f96d820c5ecda")
    }

    @Test("matches the reference id for content needing escapes")
    func escapedContent() {
        // Quotes, backslashes, control characters, an emoji outside the BMP, and
        // an accented character. Escaping any of these differently than the
        // reference (for example emitting \uXXXX for non-ASCII) changes the hash
        // and every other client would reject the event.
        let id = NostrEvent.computeID(
            pubkey: Self.pubkey,
            createdAt: 1_700_000_000,
            kind: .textNote,
            tags: [],
            content: "quote:\" back:\\ nl:\n tab:\t emoji:🐝 unicode:é"
        )
        #expect(id.hex == "b15adc1518241c3d39ddbc122dfcaf1ad702ede050feb1e6a6a2027cf215b109")
    }
}

@Suite("NostrEvent")
struct NostrEventTests {
    @Test("signs an event that validates")
    func signsValidEvent() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "first post",
            tags: [["h", "abc-123"]],
            with: key
        )

        #expect(event.pubkey == key.publicKey.hex)
        #expect(event.kind == .groupChatMessage)
        #expect(event.hasValidID)
        #expect(event.isValid)
        #expect(event.sig.count == 128)
        #expect(event.id.count == 64)
    }

    @Test("detects tampered content")
    func detectsTamperedContent() throws {
        let key = try PrivateKey()
        let original = try NostrEvent.signed(kind: .textNote, content: "pay alice", with: key)

        // A relay swaps the content while keeping the original id and signature.
        // The signature still verifies over that id, so only recomputing the id
        // from the contents catches this.
        let tampered = NostrEvent(
            id: original.id,
            pubkey: original.pubkey,
            createdAt: original.createdAt,
            kind: original.kind,
            tags: original.tags,
            content: "pay mallory",
            sig: original.sig
        )

        #expect(!tampered.hasValidID)
        #expect(!tampered.isValid)
    }

    @Test("detects a forged signature")
    func detectsForgedSignature() throws {
        let key = try PrivateKey()
        let impostor = try PrivateKey()
        let event = try NostrEvent.signed(kind: .textNote, content: "hello", with: key)

        // Claim someone else's identity while keeping a well-formed signature.
        let forged = try NostrEvent.signed(kind: .textNote, content: "hello", with: impostor)
        let spoofed = NostrEvent(
            id: forged.id,
            pubkey: key.publicKey.hex,
            createdAt: forged.createdAt,
            kind: forged.kind,
            tags: forged.tags,
            content: forged.content,
            sig: forged.sig
        )

        #expect(!spoofed.isValid)
    }

    @Test("rejects structurally invalid fields")
    func rejectsGarbage() {
        let event = NostrEvent(
            id: "not-hex",
            pubkey: "also-not-hex",
            createdAt: 0,
            kind: .textNote,
            tags: [],
            content: "",
            sig: "nope"
        )
        #expect(!event.isValid)
    }

    @Test("round trips through JSON with wire field names")
    func jsonRoundTrip() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "round trip 🐝",
            tags: [["h", "room"], ["p", key.publicKey.hex]],
            with: key
        )

        let encoded = try JSONEncoder().encode(event)
        let json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(json["created_at"] != nil, "wire format uses created_at, not createdAt")
        #expect(json["kind"] as? Int == 9)

        let decoded = try JSONDecoder().decode(NostrEvent.self, from: encoded)
        #expect(decoded == event)
        #expect(decoded.isValid)
    }

    @Test("preserves unknown kinds through a round trip")
    func preservesUnknownKinds() throws {
        // A relay may serve kinds this client predates. Dropping or normalising
        // them would corrupt the id.
        let json = """
        {"id":"aa","pubkey":"bb","created_at":1,"kind":31337,"tags":[],"content":"x","sig":"cc"}
        """
        let event = try JSONDecoder().decode(NostrEvent.self, from: Data(json.utf8))
        #expect(event.kind.rawValue == 31337)

        let reencoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(NostrEvent.self, from: reencoded)
        #expect(decoded.kind.rawValue == 31337)
    }

    @Test("reads the group id from the h tag")
    func readsGroupID() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "in a room",
            tags: [["h", "room-uuid"]],
            with: key
        )
        #expect(event.groupID == "room-uuid")
    }

    @Test("returns nil group id for community-global events")
    func noGroupID() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(kind: .metadata, content: "{}", with: key)
        #expect(event.groupID == nil)
    }

    @Test("resolves NIP-10 reply and root markers")
    func resolvesThreading() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "a reply",
            tags: [
                ["e", "root-id", "", "root"],
                ["e", "parent-id", "", "reply"],
                ["p", "someone"],
            ],
            with: key
        )

        #expect(event.threadReference.rootID == "root-id")
        #expect(event.threadReference.parentID == "parent-id")
        #expect(event.isThreadReply)
        #expect(event.referencedEventIDs == ["root-id", "parent-id"])
        #expect(event.referencedPubkeys == ["someone"])
    }

    @Test("a lone root marker is not a reply")
    func rootAloneIsNotAReply() throws {
        // Buzz's resolver requires an explicit `reply` marker. Falling back to
        // `root` here would thread messages that Buzz renders flat, and the two
        // clients would draw the same conversation differently.
        let key = try PrivateKey()
        let event = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "mentions a thread without joining it",
            tags: [["e", "root-id", "", "root"]],
            with: key
        )
        #expect(event.threadReference.parentID == nil)
        #expect(event.threadReference.rootID == nil)
        #expect(!event.isThreadReply)
    }

    @Test("a reply to the opener is its own root")
    func replyToOpener() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "first reply",
            tags: [["e", "opener", "", "reply"]],
            with: key
        )
        #expect(event.threadReference.parentID == "opener")
        #expect(event.threadReference.rootID == "opener")
    }

    @Test("the last reply marker wins")
    func lastReplyMarkerWins() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "x",
            tags: [
                ["e", "root-id", "", "root"],
                ["e", "first", "", "reply"],
                ["e", "second", "", "reply"],
            ],
            with: key
        )
        #expect(event.threadReference.parentID == "second")
        #expect(event.threadReference.rootID == "root-id")
    }

    @Test("a broadcast reply belongs in the channel as well as the thread")
    func broadcastReply() throws {
        // Buzz lets an author echo a reply back into the channel. Treating it as
        // thread-only would silently hide a message its author meant everyone
        // to see.
        let key = try PrivateKey()
        let event = try NostrEvent.signed(
            kind: .groupChatMessage,
            content: "worth everyone seeing",
            tags: [["e", "root-id", "", "reply"], ["broadcast", "1"]],
            with: key
        )
        #expect(event.threadReference.parentID == "root-id")
        #expect(event.isBroadcastReply)
        #expect(!event.isThreadReply)
    }

    @Test("tag accessors ignore malformed tags")
    func ignoresMalformedTags() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(
            kind: .textNote,
            content: "x",
            tags: [["h"], [], ["h", "real-value"]],
            with: key
        )
        // A bare ["h"] with no value must not crash or return an empty string.
        #expect(event.groupID == "real-value")
    }
}

@Suite("EventKind")
struct EventKindTests {
    @Test("classifies storage semantics")
    func storageClasses() {
        #expect(EventKind.buzzPresence.isEphemeral)
        #expect(EventKind.buzzTyping.isEphemeral)
        #expect(!EventKind.groupChatMessage.isEphemeral)

        #expect(EventKind.groupMetadata.isAddressable)
        #expect(EventKind.groupMembers.isAddressable)
        #expect(!EventKind.textNote.isAddressable)

        #expect(EventKind.metadata.isReplaceable)
    }

    @Test("flags Buzz-only kinds so fallbacks stay required")
    func flagsExtensions() {
        #expect(EventKind.buzzRichContent.isBuzzExtension)
        #expect(EventKind.buzzEdit.isBuzzExtension)
        #expect(EventKind.buzzPresence.isBuzzExtension)

        // Standard NIP-29 must never be treated as a Buzz extension, or the
        // client would needlessly disable features on other relays.
        #expect(!EventKind.groupChatMessage.isBuzzExtension)
        #expect(!EventKind.groupMetadata.isBuzzExtension)
        #expect(!EventKind.groupJoinRequest.isBuzzExtension)
    }

    @Test("marks relay-signed kinds the client must not publish")
    func flagsRelaySigned() {
        #expect(EventKind.groupMetadata.isRelaySigned)
        #expect(EventKind.groupMembers.isRelaySigned)
        #expect(EventKind.buzzMemberAdded.isRelaySigned)
        #expect(!EventKind.groupChatMessage.isRelaySigned)
    }
}
