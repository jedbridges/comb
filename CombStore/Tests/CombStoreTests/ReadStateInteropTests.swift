import CombCore
import Foundation
import Testing
@testable import CombStore

/// NIP-RS, checked against the spec's own vectors rather than against examples
/// invented here.
///
/// The distinction matters for an interoperability format: a suite built from
/// examples written by the same person who wrote the parser agrees with itself
/// by construction. Every case below is transcribed from the published
/// document, including the ciphertext one, which is the only test in this
/// repository that proves Comb can read bytes produced somewhere else.
@Suite("Read state interop")
struct ReadStateInteropTests {
    // MARK: - The spec's test vectors

    static let deviceA = #"""
    {"v":1,"client_id":"client-aabbccdd","contexts":{"group:general":1700001000,"group:dev":1700000500}}
    """#

    static let deviceB = #"""
    {"v":1,"client_id":"client-11223344","contexts":{"group:general":1700001200,"group:random":1700000800}}
    """#

    private func decode(_ json: String) throws -> ReadStateBlob {
        try #require(JSONDecoder().decode(ReadStateBlob.self, from: Data(json.utf8)).validated())
    }

    @Test("decodes the two device blobs from the specification")
    func decodesVectors() throws {
        let a = try decode(Self.deviceA)
        #expect(a.clientID == "client-aabbccdd")
        #expect(a.contexts == ["group:general": 1700001000, "group:dev": 1700000500])

        let b = try decode(Self.deviceB)
        #expect(b.clientID == "client-11223344")
        #expect(b.contexts == ["group:general": 1700001200, "group:random": 1700000800])
    }

    /// The specification's "merged effective state", reproduced through Comb's
    /// own merge rather than through a second implementation of max().
    ///
    /// They agree whenever the two blobs were published at the same moment,
    /// because Comb breaks an `updatedAt` tie on the larger marker. That is not
    /// a coincidence worth leaning on silently, so it is asserted.
    @Test("merging the specification's two blobs gives the specification's answer")
    func mergeMatchesTheSpecification() throws {
        let published: Int64 = 1700002000
        let merged = ReadStateSync.merge(
            local: try decode(Self.deviceA).markers(publishedAt: published),
            remote: try decode(Self.deviceB).markers(publishedAt: published)
        )

        #expect(merged.map(\.channelID) == ["group:dev", "group:general", "group:random"])
        #expect(merged.map(\.lastReadAt) == [1700000500, 1700001200, 1700000800])
    }

    /// The one place Comb deliberately does not do what the specification says.
    ///
    /// NIP-RS is a grow-only maximum and has no way to say "I marked this
    /// unread". Comb does, so an incoming blob is stamped with its own
    /// `created_at` and loses to a local decision made afterwards. A strict
    /// max() would silently undo the reader's deliberate act.
    @Test("a mark-unread made after a blob was published survives it")
    func laterLocalDecisionWins() throws {
        let blob = try decode(Self.deviceB)
        let remote = blob.markers(publishedAt: 1700002000)

        // Marked unread a minute later: the line moves backwards, the stamp
        // moves forwards.
        let local = [ReadMarker(channelID: "group:general", lastReadAt: 1699999000, updatedAt: 1700002060)]

        let merged = ReadStateSync.merge(local: local, remote: remote)
        let general = try #require(merged.first { $0.channelID == "group:general" })
        #expect(general.lastReadAt == 1699999000, "the deliberate unread must not be undone")

        // And a blob published after the decision does advance it.
        let later = blob.markers(publishedAt: 1700002120)
        let advanced = try #require(
            ReadStateSync.merge(local: local, remote: later).first { $0.channelID == "group:general" }
        )
        #expect(advanced.lastReadAt == 1700001200)
    }

    /// The full encrypt-to-self pipeline, against ciphertext this repository did
    /// not produce.
    ///
    /// The specification publishes this with the well-known secp256k1 scalar 1,
    /// and NIP-44 uses a random nonce, so the only meaningful check is that we
    /// can decrypt it. If Comb's conversation-key derivation were subtly wrong,
    /// every round-trip test would still pass and this one would not.
    @Test("decrypts the specification's ciphertext vector")
    func decryptsTheCiphertextVector() async throws {
        let scalar = try #require(
            Data(hex: "0000000000000000000000000000000000000000000000000000000000000001")
        )
        let key = try PrivateKey(data: scalar)
        #expect(key.publicKey.hex == "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")

        let ciphertext = """
        Akt10yui5aDIjfH+xED2Dr1NJ/SGWp85SC/r/bloiLRtj8K59rJrYhcfsNQMoMhpLlvhKqrN0HIGb9/V9BcYKxWV8HT/\
        jjDdvfHLUVfo688I6WpapcX41GzL4VnGGDdFyUom53odJncjHszS3dpTrG1OKp2x9dtdG+924/+Ne49KN4nztd1pikqY\
        eqQuxflKCmh+VcCFbDclQ8a9NUpqWkPpeoweISVVuZDnP9WFoKG5X6YcpXBWH6wjc69xK4cs6KkJ
        """

        let plaintext = try await InMemorySigner(key).decryptFromSelf(ciphertext)
        let blob = try #require(
            JSONDecoder().decode(ReadStateBlob.self, from: Data(plaintext.utf8)).validated()
        )
        #expect(blob.clientID == "test-vector-client")
        #expect(blob.contexts == ["group:general": 1700001000, "group:dev": 1700000500])
    }

    // MARK: - The specification's invalid cases, one test each

    @Test("content that is not JSON is discarded")
    func rejectsNonJSON() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ReadStateBlob.self, from: Data("not json".utf8))
        }
    }

    @Test("a missing client_id discards the event")
    func rejectsMissingClientID() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                ReadStateBlob.self,
                from: Data(#"{"v":1,"contexts":{"a":1}}"#.utf8)
            )
        }
    }

    @Test("an unknown version is ignored")
    func ignoresUnknownVersion() throws {
        let decoded = try JSONDecoder().decode(
            ReadStateBlob.self,
            from: Data(#"{"v":2,"client_id":"c","contexts":{"a":1}}"#.utf8)
        )
        #expect(decoded.validated() == nil)
    }

    @Test("a non-integer timestamp drops that entry and keeps the rest")
    func dropsOneBadEntry() throws {
        let blob = try decode(#"""
        {"v":1,"client_id":"c","contexts":{"ctx:AAA":"yesterday","ctx:BBB":1700000000}}
        """#)
        #expect(blob.contexts == ["ctx:BBB": 1700000000])
    }

    @Test("a context id over 256 bytes drops that entry and keeps the rest")
    func dropsOversizedContext() throws {
        let huge = String(repeating: "x", count: 257)
        let blob = try decode(#"""
        {"v":1,"client_id":"c","contexts":{"\#(huge)":1700000000,"ctx:ok":1700000001}}
        """#)
        #expect(blob.contexts == ["ctx:ok": 1700000001])
    }

    @Test("more than ten thousand contexts rejects the whole blob")
    func rejectsTooManyContexts() throws {
        let contexts = (0...10_000).map { "\"c\($0)\":1" }.joined(separator: ",")
        let decoded = try JSONDecoder().decode(
            ReadStateBlob.self,
            from: Data(#"{"v":1,"client_id":"c","contexts":{\#(contexts)}}"#.utf8)
        )
        #expect(decoded.contexts.count == 10_001)
        #expect(decoded.validated() == nil)
    }

    @Test("a timestamp outside the representable range drops that entry")
    func dropsOutOfRangeTimestamp() throws {
        let blob = try decode(#"""
        {"v":1,"client_id":"c","contexts":{"ctx:neg":-1,"ctx:huge":4294967296,"ctx:ok":17}}
        """#)
        #expect(blob.contexts == ["ctx:ok": 17])
    }

    // MARK: - Wire shape

    /// Nothing pinned the literal keys before, so a rename would have been
    /// invisible to CI while silently ending cross-device sync. Both shapes are
    /// pinned here, Comb's own included.
    @Test("both payloads encode to the keys the wire expects")
    func wireShapeIsPinned() throws {
        let blob = ReadStateBlob(clientID: "c", contexts: ["room": 12])
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(blob)
        ) as? [String: Any]
        let object = try #require(encoded)
        #expect(object["v"] as? Int == 1)
        #expect(object["client_id"] as? String == "c")
        #expect((object["contexts"] as? [String: Any])?["room"] as? Int == 12)

        let own = ReadStatePayload(markers: [ReadMarker(channelID: "room", lastReadAt: 1, updatedAt: 2)])
        let ownObject = try #require(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(own)) as? [String: Any]
        )
        #expect(ownObject["v"] as? Int == 1)
        let markers = try #require(ownObject["m"] as? [[String: Any]])
        #expect(markers.first?["c"] as? String == "room")
        #expect(markers.first?["r"] as? Int == 1)
        #expect(markers.first?["u"] as? Int == 2)
    }

    @Test("publishing prunes contexts that have aged out of the horizon")
    func prunesOldContexts() {
        let now: Int64 = 1_700_000_000
        let blob = ReadStateBlob(
            clientID: "c",
            markers: [
                ReadMarker(channelID: "recent", lastReadAt: now - 60, updatedAt: now),
                ReadMarker(channelID: "ancient", lastReadAt: now - 30 * 24 * 60 * 60, updatedAt: now),
            ],
            now: now
        )
        #expect(blob.contexts.keys.sorted() == ["recent"])
    }
}
