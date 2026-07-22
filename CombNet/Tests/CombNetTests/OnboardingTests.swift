import CombCore
import Foundation
import Testing
@testable import CombNet

@Suite("Invite links", .timeLimit(.minutes(1)))
struct InviteLinkTests {
    @Test("parses the web form a relay hands out")
    func parsesWebForm() throws {
        let link = try #require(InviteLink.parse(
            "https://designers.communities.buzz.xyz/invite/abc123XYZ.def456"
        ))
        #expect(link.relayURL.absoluteString == "wss://designers.communities.buzz.xyz")
        #expect(link.code == "abc123XYZ.def456")
        #expect(link.host == "designers.communities.buzz.xyz")
    }

    @Test("parses the app scheme handoff")
    func parsesAppScheme() throws {
        let link = try #require(InviteLink.parse(
            "buzz://join?relay=wss%3A%2F%2Fdesigners.communities.buzz.xyz&code=abc123XYZ"
        ))
        #expect(link.relayURL.absoluteString == "wss://designers.communities.buzz.xyz")
        #expect(link.code == "abc123XYZ")

        #expect(InviteLink.parse("comb://join?relay=wss://a.example&code=abc123XYZ") != nil)
    }

    @Test("survives pasted whitespace and tracking parameters")
    func survivesPasteNoise() {
        // Pasting is the primary path (universal links need an AASA file on a
        // domain a relay-agnostic client does not control), so real-world paste
        // sloppiness must parse.
        #expect(InviteLink.parse("  https://a.example/invite/abc123XYZ \n") != nil)
        #expect(InviteLink.parse(
            "https://a.example/invite/abc123XYZ?utm_source=x&fbclid=y"
        )?.code == "abc123XYZ")
    }

    @Test("keeps local development on plain ws")
    func localDevelopment() throws {
        let link = try #require(InviteLink.parse("http://localhost:3000/invite/abc123XYZ"))
        #expect(link.relayURL.absoluteString == "ws://localhost:3000")
    }

    @Test("rejects everything else")
    func rejectsGarbage() {
        #expect(InviteLink.parse("") == nil)
        #expect(InviteLink.parse("not a link") == nil)
        #expect(InviteLink.parse("https://a.example/") == nil)
        #expect(InviteLink.parse("https://a.example/invite/") == nil)
        #expect(InviteLink.parse("https://a.example/invite/a/b/c") == nil)
        #expect(InviteLink.parse("https://a.example/invite/short") == nil, "code too short")
        #expect(InviteLink.parse("buzz://join?code=abc123XYZ") == nil, "no relay")
        #expect(InviteLink.parse("buzz://join?relay=https://a.example&code=abc123XYZ") == nil,
                "relay must be a websocket")
        #expect(InviteLink.parse("ftp://a.example/invite/abc123XYZ") == nil)
    }
}

// Serialized because URLProtocol registration is process-global: the stub's
// responder is a static, and Swift Testing's default parallelism lets two
// tests overwrite each other's scripted responses. The symptom was tests that
// pass alone and fail together, with failures hopping between tests.
@Suite("Invite claiming", .timeLimit(.minutes(1)), .serialized)
struct InviteClaimTests {
    /// Serves scripted responses and records the request for inspection.
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var respond: (@Sendable (URLRequest) -> (Int, Data))?
        nonisolated(unsafe) static var lastRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
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

    private func makeClient() -> InviteClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return InviteClient(session: URLSession(configuration: configuration))
    }

    private var invite: InviteLink {
        InviteLink.parse("https://designers.communities.buzz.xyz/invite/abc123XYZ")!
    }

    @Test("claims with a NIP-98 signed request")
    func claimsWithAuth() async throws {
        StubProtocol.respond = { _ in
            (200, Data(#"{"status":"joined","host":"designers.communities.buzz.xyz","role":"member"}"#.utf8))
        }

        let signer = try InMemorySigner()
        let claim = try await makeClient().claim(invite, signer: signer)

        #expect(claim.isMember)
        #expect(claim.role == "member")

        let request = try #require(StubProtocol.lastRequest)
        #expect(request.url?.absoluteString
            == "https://designers.communities.buzz.xyz/api/invites/claim")
        #expect(request.httpMethod == "POST")

        // The Authorization header must be a valid NIP-98 event over these
        // exact body bytes, or the relay rejects the claim.
        let header = try #require(request.value(forHTTPHeaderField: "Authorization"))
        let body = try #require(
            request.httpBody ?? request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    data.append(buffer, count: read)
                }
                return data
            }
        )
        #expect(NIP98.validate(
            header: header,
            url: request.url!,
            method: "POST",
            body: body
        ))
        #expect(
            try JSONDecoder().decode([String: String].self, from: body)["code"] == "abc123XYZ"
        )
    }

    @Test("treats already_member as success")
    func idempotentClaim() async throws {
        // The server is idempotent; a retry after a dropped response must not
        // read as a failure.
        StubProtocol.respond = { _ in (200, Data(#"{"status":"already_member"}"#.utf8)) }
        let claim = try await makeClient().claim(invite, signer: try InMemorySigner())
        #expect(claim.isMember)
    }

    @Test("maps the server's coarse errors")
    func mapsErrors() async throws {
        StubProtocol.respond = { _ in (403, Data(#"{"error":"invite_expired"}"#.utf8)) }
        await #expect(throws: InviteClient.Failure.expired) {
            _ = try await makeClient().claim(invite, signer: try InMemorySigner())
        }

        StubProtocol.respond = { _ in (403, Data(#"{"error":"invite_invalid"}"#.utf8)) }
        await #expect(throws: InviteClient.Failure.invalid) {
            _ = try await makeClient().claim(invite, signer: try InMemorySigner())
        }

        StubProtocol.respond = { _ in (429, Data()) }
        await #expect(throws: InviteClient.Failure.rateLimited) {
            _ = try await makeClient().claim(invite, signer: try InMemorySigner())
        }
    }
}

@Suite("Community index", .timeLimit(.minutes(1)))
struct CommunityIndexTests {
    static let sample = Data("""
    {
      "version": 1,
      "communities": [
        {
          "id": "designers",
          "name": "Designers",
          "description": "A community for designers.",
          "relay": "wss://designers.communities.buzz.xyz",
          "tags": ["design"],
          "join": { "kind": "invite_url", "url": "https://designers.communities.buzz.xyz/invite/public" }
        },
        {
          "id": "sneaky-local",
          "name": "SSRF Attempt",
          "relay": "wss://192.168.1.1"
        },
        {
          "id": "not-a-websocket",
          "name": "Wrong Scheme",
          "relay": "https://example.com"
        }
      ]
    }
    """.utf8)

    @Test("decodes entries and drops invalid relays")
    func decodesAndFilters() throws {
        let service = CommunityIndexService(bundledData: Self.sample)
        let entries = service.seeded

        // The private-address and non-websocket entries must not survive: an
        // index is user-submitted content, and a hostile entry pointing at
        // someone's router is the obvious abuse.
        #expect(entries.map(\.id) == ["designers"])
        #expect(entries[0].join.kind == "invite_url")
    }

    @Test("refuses a future schema version")
    func refusesFutureVersion() {
        let future = Data(#"{"version": 2, "communities": []}"#.utf8)
        #expect(throws: CommunityIndexService.IndexError.unsupportedVersion(2)) {
            _ = try CommunityIndexService.decode(future)
        }
    }

    @Test("private host detection")
    func privateHosts() {
        #expect(CommunityIndex.Entry.isPrivateHost("localhost"))
        #expect(CommunityIndex.Entry.isPrivateHost("relay.local"))
        #expect(CommunityIndex.Entry.isPrivateHost("10.0.0.5"))
        #expect(CommunityIndex.Entry.isPrivateHost("172.20.1.1"))
        #expect(CommunityIndex.Entry.isPrivateHost("192.168.0.1"))
        #expect(CommunityIndex.Entry.isPrivateHost("169.254.1.1"))
        #expect(!CommunityIndex.Entry.isPrivateHost("designers.communities.buzz.xyz"))
        #expect(!CommunityIndex.Entry.isPrivateHost("172.15.1.1"))
    }
}
