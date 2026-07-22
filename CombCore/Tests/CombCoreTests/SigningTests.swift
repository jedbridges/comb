import Foundation
import Testing
@testable import CombCore

@Suite("EventSigner")
struct EventSignerTests {
    @Test("signs a valid event")
    func signsValidEvent() async throws {
        let signer = try InMemorySigner()
        let event = try await signer.sign(kind: .groupChatMessage, content: "hello")

        #expect(event.isValid)
        #expect(try await event.pubkey == signer.publicKey().hex)
    }

    @Test("refuses to sign relay-signed kinds")
    func refusesRelaySignedKinds() async throws {
        // The relay authors 39000 itself and rejects a client-authored one. Failing
        // here turns a confusing server rejection into an obvious programming error.
        let signer = try InMemorySigner()

        await #expect(throws: SigningError.relaySignedKind(.groupMetadata)) {
            try await signer.sign(kind: .groupMetadata, content: "{}")
        }
        await #expect(throws: SigningError.relaySignedKind(.groupMembers)) {
            try await signer.sign(kind: .groupMembers, content: "{}")
        }
    }

    @Test("honours an explicit timestamp")
    func honoursTimestamp() async throws {
        let signer = try InMemorySigner()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let event = try await signer.sign(
            kind: .textNote,
            content: "x",
            tags: [],
            createdAt: when
        )

        #expect(event.createdAt == 1_700_000_000)
        #expect(event.isValid)
    }

    @Test("wraps an existing key without changing identity")
    func wrapsExistingKey() async throws {
        let key = try PrivateKey(nsec: Bech32Tests.nsec)
        let signer = InMemorySigner(key)

        #expect(try await signer.publicKey() == key.publicKey)
    }
}

@Suite("NIP-98")
struct NIP98Tests {
    static let url = URL(string: "https://designers.communities.buzz.xyz/api/invites/claim")!

    @Test("builds an event with the tags Buzz expects")
    func buildsExpectedTags() async throws {
        let signer = try InMemorySigner()
        let body = Data(#"{"code":"abc"}"#.utf8)
        let event = try await NIP98.authorizationEvent(
            url: Self.url,
            method: "post",
            body: body,
            signer: signer
        )

        #expect(event.kind == .httpAuth)
        #expect(event.content == "")
        #expect(event.firstValue(for: "u") == Self.url.absoluteString)
        // Method is normalised to uppercase regardless of how it was passed.
        #expect(event.firstValue(for: "method") == "POST")
        #expect(event.firstValue(for: "nonce") != nil)
        #expect(event.isValid)
    }

    @Test("hashes the request body into the payload tag")
    func hashesBody() async throws {
        let signer = try InMemorySigner()
        // sha256("hello") — an independently known vector.
        let expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

        let event = try await NIP98.authorizationEvent(
            url: Self.url,
            method: "POST",
            body: Data("hello".utf8),
            signer: signer
        )
        #expect(event.firstValue(for: "payload") == expected)
    }

    @Test("hashes empty bytes for a bodyless request")
    func hashesEmptyBody() async throws {
        let signer = try InMemorySigner()
        // sha256("") — the reference client always sends a payload tag, so a GET
        // carries the hash of zero bytes rather than omitting the tag.
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

        let event = try await NIP98.authorizationEvent(
            url: Self.url,
            method: "GET",
            signer: signer
        )
        #expect(event.firstValue(for: "payload") == expected)
    }

    @Test("produces a header that decodes back to the event")
    func headerRoundTrip() async throws {
        let signer = try InMemorySigner()
        let header = try await NIP98.authorizationHeader(
            url: Self.url,
            method: "POST",
            signer: signer
        )

        #expect(header.hasPrefix("Nostr "))
        let encoded = String(header.dropFirst("Nostr ".count))
        let json = try #require(Data(base64Encoded: encoded))
        let event = try JSONDecoder().decode(NostrEvent.self, from: json)

        #expect(event.kind == .httpAuth)
        #expect(event.isValid)
    }

    @Test("validates a header it just built")
    func validatesOwnHeader() async throws {
        let signer = try InMemorySigner()
        let body = Data(#"{"code":"abc"}"#.utf8)
        let header = try await NIP98.authorizationHeader(
            url: Self.url,
            method: "POST",
            body: body,
            signer: signer
        )

        #expect(NIP98.validate(header: header, url: Self.url, method: "POST", body: body))
    }

    @Test("rejects a header bound to a different request")
    func rejectsMismatchedRequest() async throws {
        let signer = try InMemorySigner()
        let body = Data(#"{"code":"abc"}"#.utf8)
        let header = try await NIP98.authorizationHeader(
            url: Self.url,
            method: "POST",
            body: body,
            signer: signer
        )

        let otherURL = URL(string: "https://evil.example/api/invites/claim")!
        #expect(!NIP98.validate(header: header, url: otherURL, method: "POST", body: body))
        #expect(!NIP98.validate(header: header, url: Self.url, method: "GET", body: body))
        #expect(!NIP98.validate(
            header: header,
            url: Self.url,
            method: "POST",
            body: Data(#"{"code":"stolen"}"#.utf8)
        ))
    }

    @Test("rejects a stale header")
    func rejectsStale() async throws {
        let signer = try InMemorySigner()
        let header = try await NIP98.authorizationHeader(
            url: Self.url,
            method: "POST",
            signer: signer
        )

        #expect(!NIP98.validate(
            header: header,
            url: Self.url,
            method: "POST",
            now: Date().addingTimeInterval(3600)
        ))
    }

    @Test("rejects malformed headers")
    func rejectsMalformed() {
        #expect(!NIP98.validate(header: "Bearer abc", url: Self.url, method: "GET"))
        #expect(!NIP98.validate(header: "Nostr not-base64!!", url: Self.url, method: "GET"))
        #expect(!NIP98.validate(header: "", url: Self.url, method: "GET"))
    }

    @Test("uses a fresh nonce per request")
    func freshNonce() async throws {
        // Two identical requests must not produce the same event id, or a captured
        // header could be replayed.
        let signer = try InMemorySigner()
        let first = try await NIP98.authorizationEvent(url: Self.url, method: "POST", signer: signer)
        let second = try await NIP98.authorizationEvent(url: Self.url, method: "POST", signer: signer)

        #expect(first.firstValue(for: "nonce") != second.firstValue(for: "nonce"))
        #expect(first.id != second.id)
    }
}
