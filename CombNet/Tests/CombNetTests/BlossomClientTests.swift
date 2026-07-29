import CombCore
import CryptoKit
import Foundation
import Testing
@testable import CombNet

@Suite("Blossom client", .timeLimit(.minutes(1)), .serialized)
struct BlossomClientTests {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var respond: (@Sendable (URLRequest) -> (Int, Data))?
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.append(request)
            let (status, body) = Self.respond?(request) ?? (500, Data())
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> BlossomClient {
        Stub.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return BlossomClient(session: URLSession(configuration: config))
    }

    private let relay = URL(string: "wss://designers.communities.buzz.xyz")!
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02, 0x03, 0x04])

    private func descriptorJSON(for data: Data) -> Data {
        let hash = Data(SHA256.hash(data: data)).hex
        return Data("""
        {"url":"https://designers.communities.buzz.xyz/media/\(hash).png",
         "sha256":"\(hash)","size":\(data.count),"type":"image/png","dim":"64x64"}
        """.utf8)
    }

    @Test("uploads to the BUD-02 endpoint with a signed header")
    func uploadsToUploadEndpoint() async throws {
        let payload = png
        Stub.respond = { _ in (200, self.descriptorJSON(for: payload)) }

        let descriptor = try await makeClient().upload(
            payload,
            mimeType: "image/png",
            to: relay,
            signer: InMemorySigner(try PrivateKey())
        )

        let request = try #require(Stub.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString
            == "https://designers.communities.buzz.xyz/upload")
        // The relay verifies the header against the body's hash, so the two
        // must agree or every upload is refused.
        #expect(request.value(forHTTPHeaderField: "X-SHA-256")
            == Data(SHA256.hash(data: payload)).hex)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Nostr ") == true)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(descriptor.mimeType == "image/png")
        #expect(descriptor.dim == "64x64")
    }

    @Test("falls back to the legacy endpoint only on 404 or 405")
    func legacyFallback() async throws {
        // An older relay has no /upload. Anything other than "not here" is a
        // real refusal, and retrying it elsewhere would just fail twice.
        let payload = png
        Stub.respond = { request in
            request.url?.path == "/upload"
                ? (404, Data())
                : (200, self.descriptorJSON(for: payload))
        }

        _ = try await makeClient().upload(
            payload, mimeType: "image/png", to: relay, signer: InMemorySigner(try PrivateKey())
        )

        #expect(Stub.requests.map { $0.url!.path } == ["/upload", "/media/upload"])
    }

    @Test("a rejection is not retried against the legacy endpoint")
    func rejectionNotRetried() async throws {
        Stub.respond = { _ in (413, Data()) }

        await #expect(throws: BlossomClient.Failure.rejected(status: 413)) {
            try await makeClient().upload(
                self.png, mimeType: "image/png", to: self.relay,
                signer: InMemorySigner(try PrivateKey())
            )
        }
        #expect(Stub.requests.count == 1)
    }

    @Test("refuses an unsupported type before sending anything")
    func refusesUnsupportedType() async throws {
        let client = makeClient()
        await #expect(throws: BlossomClient.Failure.unsupportedType("image/heic")) {
            try await client.upload(
                self.png, mimeType: "image/heic", to: self.relay,
                signer: InMemorySigner(try PrivateKey())
            )
        }
        #expect(Stub.requests.isEmpty, "nothing should reach the network")
    }

    @Test("refuses an oversized file before sending anything")
    func refusesOversized() async throws {
        let client = makeClient()
        let huge = Data(count: Blossom.maxImageBytes + 1)

        await #expect(throws: BlossomClient.Failure.self) {
            try await client.upload(
                huge, mimeType: "image/png", to: self.relay,
                signer: InMemorySigner(try PrivateKey())
            )
        }
        #expect(Stub.requests.isEmpty)
    }

    @Test("a download must hash to what was asked for")
    func downloadVerifiesHash() async throws {
        // Without this a relay could serve any bytes it liked under someone
        // else's attachment, and the cache would keep them.
        Stub.respond = { _ in (200, Data("not the right bytes".utf8)) }
        let attachment = Blossom.Attachment(
            url: "https://designers.communities.buzz.xyz/media/abc.png",
            mimeType: "image/png",
            sha256: String(repeating: "a", count: 64),
            size: nil, width: nil, height: nil, blurhash: nil
        )

        await #expect(throws: BlossomClient.Failure.hashMismatch) {
            try await self.makeClient().data(
                for: attachment,
                servedBy: URL(string: "wss://designers.communities.buzz.xyz")!,
                signer: InMemorySigner(try PrivateKey())
            )
        }
    }

    @Test("a download carries a get authorization")
    func downloadIsAuthorized() async throws {
        let bytes = Data("the real bytes".utf8)
        Stub.respond = { _ in (200, bytes) }
        let attachment = Blossom.Attachment(
            url: "https://designers.communities.buzz.xyz/media/abc.png",
            mimeType: "image/png",
            sha256: Data(SHA256.hash(data: bytes)).hex,
            size: nil, width: nil, height: nil, blurhash: nil
        )

        let data = try await makeClient().data(
            for: attachment,
            servedBy: URL(string: "wss://designers.communities.buzz.xyz")!,
            signer: InMemorySigner(try PrivateKey())
        )

        #expect(data == bytes)
        #expect(Stub.requests.first?.value(forHTTPHeaderField: "Authorization")?
            .hasPrefix("Nostr ") == true)
    }

    @Test("maps relay schemes onto HTTP origins")
    func httpOrigin() {
        #expect(BlossomClient.httpOrigin(of: URL(string: "wss://relay.example")!)?
            .absoluteString == "https://relay.example")
        // Plain ws is local development, and must not be forced to https.
        #expect(BlossomClient.httpOrigin(of: URL(string: "ws://localhost:8080")!)?
            .absoluteString == "http://localhost:8080")
        #expect(BlossomClient.httpOrigin(of: URL(string: "ftp://relay.example")!) == nil)
    }
}

/// The host check on downloads, which is a privacy control rather than a
/// correctness one.
///
/// An attachment names its own host, in an `imeta` tag written by whoever sent
/// the message. Fetching one signs a Blossom authorization with the reader's
/// key and puts it in a header, so an unchecked host meant a single message
/// could hand a stranger every reader's IP address together with a signature
/// proving their pubkey.
@Suite("Blossom download provenance", .timeLimit(.minutes(1)), .serialized)
struct BlossomProvenanceTests {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var requested: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requested.append(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("bytes".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> BlossomClient {
        Stub.requested = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return BlossomClient(session: URLSession(configuration: config))
    }

    private func attachment(_ url: String) -> Blossom.Attachment {
        Blossom.Attachment(
            url: url,
            mimeType: "image/jpeg",
            sha256: String(repeating: "a", count: 64),
            size: nil, width: nil, height: nil, blurhash: nil
        )
    }

    private let community = URL(string: "wss://designers.communities.buzz.xyz")!

    /// The attack. No request may leave at all, because the request itself is
    /// the leak: it carries the reader's IP whether or not the bytes come back.
    @Test("a blob on somebody else's host is refused before anything is sent")
    func refusesForeignHost() async throws {
        let client = makeClient()
        let signer = try InMemorySigner()

        await #expect(throws: BlossomClient.Failure.foreignHost) {
            try await client.data(
                for: attachment("https://attacker.example/\(String(repeating: "a", count: 64))"),
                servedBy: community,
                signer: signer
            )
        }
        #expect(Stub.requested.isEmpty)
    }

    @Test("a blob on the community's own host is fetched and signed")
    func allowsTheCommunitysHost() async throws {
        let client = makeClient()
        let signer = try InMemorySigner()

        _ = try? await client.data(
            for: attachment("https://designers.communities.buzz.xyz/\(String(repeating: "a", count: 64))"),
            servedBy: community,
            signer: signer
        )

        #expect(Stub.requested.count == 1)
        #expect(Stub.requested.first?.value(forHTTPHeaderField: "Authorization") != nil)
    }

    /// A different port is a different origin, and a lookalike host is the
    /// whole point of the check.
    @Test("a lookalike host and a different port are both foreign")
    func portAndSuffixAreNotEnough() async throws {
        let client = makeClient()
        let signer = try InMemorySigner()
        let blob = String(repeating: "a", count: 64)

        for url in [
            "https://designers.communities.buzz.xyz.attacker.example/\(blob)",
            "https://designers.communities.buzz.xyz:8443/\(blob)",
            "https://evil.designers.communities.buzz.xyz/\(blob)",
        ] {
            await #expect(throws: BlossomClient.Failure.foreignHost) {
                try await client.data(for: attachment(url), servedBy: community, signer: signer)
            }
        }
        #expect(Stub.requested.isEmpty)
    }

    /// Userinfo. The likeliest trick, and the one that would silently start
    /// passing if anyone rewrote the check in terms of the URL string.
    @Test("a community host in the userinfo is not the host")
    func userinfoIsNotTheHost() async throws {
        let client = makeClient()
        let signer = try InMemorySigner()

        await #expect(throws: BlossomClient.Failure.foreignHost) {
            try await client.data(
                for: attachment("https://designers.communities.buzz.xyz@attacker.example/\(String(repeating: "a", count: 64))"),
                servedBy: community,
                signer: signer
            )
        }
        #expect(Stub.requested.isEmpty)
    }

    /// The mappings the comparison rests on, pinned as deliberate rather than
    /// incidental: wss means 443, and hosts fold case.
    @Test("an explicit default port and an uppercase host both still match")
    func defaultPortAndCaseMatch() async throws {
        let blob = String(repeating: "a", count: 64)

        for url in [
            "https://designers.communities.buzz.xyz:443/\(blob)",
            "https://DESIGNERS.COMMUNITIES.BUZZ.XYZ/\(blob)",
        ] {
            let client = makeClient()
            _ = try? await client.data(
                for: attachment(url), servedBy: community, signer: try InMemorySigner()
            )
            #expect(Stub.requested.count == 1, "expected \(url) to be fetched")
        }
    }

    /// The other way out of the function, before either guard. Nothing may be
    /// sent on that path either.
    @Test("an unparseable origin sends nothing")
    func unparseableOriginSendsNothing() async throws {
        let client = makeClient()
        let signer = try InMemorySigner()

        await #expect(throws: BlossomClient.Failure.badRelayURL) {
            try await client.data(
                for: attachment("ftp://designers.communities.buzz.xyz/\(String(repeating: "a", count: 64))"),
                servedBy: community,
                signer: signer
            )
        }
        #expect(Stub.requested.isEmpty)
    }

    /// The invariant that would break first under a refactor: the signature is
    /// bound to the community, never to whatever the attachment named.
    @Test("the authorization names the community, not the attachment's host")
    func authorizationNamesTheCommunity() async throws {
        let client = makeClient()
        _ = try? await client.data(
            for: attachment("https://designers.communities.buzz.xyz/\(String(repeating: "a", count: 64))"),
            servedBy: community,
            signer: try InMemorySigner()
        )

        let header = try #require(Stub.requested.first?.value(forHTTPHeaderField: "Authorization"))
        let encoded = header.replacingOccurrences(of: "Nostr ", with: "")
        let decoded = try #require(Data(base64Encoded: encoded))
        let event = try #require(try? JSONDecoder().decode(NostrEvent.self, from: decoded))

        #expect(event.firstValue(for: "server")?.contains("designers.communities.buzz.xyz") == true)
        #expect(event.firstValue(for: "server")?.contains("attacker") != true)
    }

    /// The right host over plain HTTP would put the signed header on the wire
    /// in clear. Only loopback is exempt, where the traffic never leaves.
    @Test("the right host without TLS is still refused")
    func requiresTLS() async throws {
        let client = makeClient()
        let signer = try InMemorySigner()

        await #expect(throws: BlossomClient.Failure.foreignHost) {
            try await client.data(
                for: attachment("http://designers.communities.buzz.xyz/\(String(repeating: "a", count: 64))"),
                servedBy: community,
                signer: signer
            )
        }
        #expect(Stub.requested.isEmpty)
    }

    @Test("a local development relay still works over plain HTTP")
    func allowsLoopback() async throws {
        let client = makeClient()
        let signer = try InMemorySigner()

        _ = try? await client.data(
            for: attachment("http://localhost:3030/\(String(repeating: "a", count: 64))"),
            servedBy: URL(string: "ws://localhost:3030")!,
            signer: signer
        )

        #expect(Stub.requested.count == 1)
    }
}
