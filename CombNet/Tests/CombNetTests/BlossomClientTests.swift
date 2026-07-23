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
                for: attachment, signer: InMemorySigner(try PrivateKey())
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
            for: attachment, signer: InMemorySigner(try PrivateKey())
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
