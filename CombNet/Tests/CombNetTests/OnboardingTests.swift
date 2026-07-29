import CombCore
import Foundation
import Testing
@testable import CombNet
import CombNetTesting

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

@Suite("Invite expiry")
struct InviteExpiryTests {
    /// A real Buzz code: `base64url({"c":…,"r":"member","e":<epoch>,"n":…}).mac`
    /// with `e` at 2026-07-28T00:34:51Z.
    static let code = """
        eyJjIjoiNzQ4ZmQxNDItMDZkNC00MzllLThmYzgtZTcyN2QwNGNlMGQwIiwiciI6Im1lbWJlciIsImUiOjE3ODUyMjA0OTEsIm4iOiJlel9wX0luUTV3b2pNbUhIcUxGVUFBIn0.9bU4Gscg2p1-62eRGqxR9mMpSJ6nZf_I-wguq0dvjRQ
        """

    private var invite: InviteLink {
        InviteLink.parse("https://designers.communities.buzz.xyz/invite/\(Self.code)")!
    }

    @Test("reads the expiry out of the payload")
    func readsExpiry() throws {
        let expiresAt = try #require(invite.expiresAt)
        #expect(Int(expiresAt.timeIntervalSince1970) == 1_785_220_491)
    }

    @Test("expires only once the moment has passed")
    func comparesAgainstNow() {
        let expiry = Date(timeIntervalSince1970: 1_785_220_491)
        #expect(!invite.hasExpired(asOf: expiry.addingTimeInterval(-1)))
        #expect(invite.hasExpired(asOf: expiry))
        #expect(invite.hasExpired(asOf: expiry.addingTimeInterval(1)))
    }

    @Test("has no opinion about a code it cannot read")
    func staysQuietOnUnknownFormats() {
        // The check exists to fail an invite early, never to pass one, so a
        // format this does not understand has to reach the relay untouched
        // rather than be called expired.
        for code in ["abc123XYZ.def456", "notbase64!!.mac", "eyJ4IjoxfQ.mac"] {
            let link = try? #require(
                InviteLink.parse("https://designers.communities.buzz.xyz/invite/\(code)")
            )
            #expect(link?.expiresAt == nil)
            #expect(link?.hasExpired() == false)
        }
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

    @Test("tells a missing policy acceptance apart from a bad invite")
    func mapsPolicyRequired() async throws {
        // The whole reason this case exists: the relay refuses with a 403 the
        // person can act on, and reading it as `invalid` told them to check
        // their paste when the link was never the problem.
        StubProtocol.respond = { _ in (403, Data(#"{"error":"join_policy_required"}"#.utf8)) }
        await #expect(throws: InviteClient.Failure.policyRequired) {
            _ = try await makeClient().claim(invite, signer: try InMemorySigner())
        }
    }

    @Test("sends the policy receipt with the claim")
    func claimsWithReceipt() async throws {
        StubProtocol.respond = { _ in (200, Data(#"{"status":"joined"}"#.utf8)) }
        _ = try await makeClient().claim(
            invite,
            signer: try InMemorySigner(),
            policyReceipt: "receipt-abc"
        )

        let body = try #require(StubProtocol.lastRequest.flatMap(Self.body(of:)))
        let json = try JSONDecoder().decode([String: String].self, from: body)
        #expect(json["code"] == "abc123XYZ")
        #expect(json["policy_receipt"] == "receipt-abc")
    }

    @Test("omits the receipt key entirely when there is nothing to send")
    func claimsWithoutReceipt() async throws {
        // A relay with no policy configured must see exactly the body it saw
        // before this field existed.
        StubProtocol.respond = { _ in (200, Data(#"{"status":"joined"}"#.utf8)) }
        _ = try await makeClient().claim(invite, signer: try InMemorySigner())

        let body = try #require(StubProtocol.lastRequest.flatMap(Self.body(of:)))
        let json = try JSONDecoder().decode([String: String?].self, from: body)
        #expect(json.keys.sorted() == ["code"])
    }

    // MARK: - Join policy

    private func makePolicyClient() -> JoinPolicyClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return JoinPolicyClient(session: URLSession(configuration: configuration))
    }

    @Test("reads a configured join policy")
    func readsPolicy() async throws {
        StubProtocol.respond = { _ in
            (200, Data(#"""
            {"policy":{"terms_markdown":"# Terms","privacy_markdown":"# Privacy",
            "age_attestation_required":true,"version":"2026-07-17"}}
            """#.utf8))
        }

        let policy = try #require(try await makePolicyClient().policy(for: invite))
        #expect(policy.version == "2026-07-17")
        #expect(policy.ageAttestationRequired)
        #expect(policy.termsMarkdown == "# Terms")
        #expect(!policy.isEmpty)

        #expect(StubProtocol.lastRequest?.url?.absoluteString
            == "https://designers.communities.buzz.xyz/api/join-policy")
    }

    @Test("reads no policy as no policy, not as an error")
    func readsAbsentPolicy() async throws {
        // A relay without one answers `{}`. That is the common case, and it
        // must leave the join screen exactly as it was.
        StubProtocol.respond = { _ in (200, Data("{}".utf8)) }
        let policy = try await makePolicyClient().policy(for: invite)
        #expect(policy == nil)
    }

    @Test("a policy with nothing to show is still a policy")
    func readsSilentPolicy() async throws {
        // The relay demands a receipt for any configured policy, including one
        // that asks nothing. That must come back as a real policy with
        // `isEmpty` true, not as no policy at all: the caller mints a receipt
        // on the first and skips it on the second, and confusing the two locks
        // such a relay out entirely.
        StubProtocol.respond = { _ in
            (200, Data(#"{"policy":{"age_attestation_required":false,"version":"v1"}}"#.utf8))
        }

        let policy = try #require(try await makePolicyClient().policy(for: invite))
        #expect(policy.isEmpty)
        #expect(!policy.hasDocuments)
        #expect(policy.version == "v1")
    }

    @Test("exchanges acceptance for a receipt")
    func acceptsPolicy() async throws {
        StubProtocol.respond = { _ in (200, Data(#"{"receipt":"receipt-abc"}"#.utf8)) }

        let receipt = try await makePolicyClient().acceptPolicy(
            for: invite,
            version: "2026-07-17",
            ageConfirmed: true
        )
        #expect(receipt == "receipt-abc")

        let request = try #require(StubProtocol.lastRequest)
        #expect(request.url?.absoluteString
            == "https://designers.communities.buzz.xyz/api/invites/accept-policy")
        #expect(request.httpMethod == "POST")

        // The receipt is bound to this code and this revision, so both must go
        // out exactly as the person saw them.
        let body = try #require(Self.body(of: request))
        let json = try JSONDecoder().decode([String: JSONValue].self, from: body)
        #expect(json["code"] == .string("abc123XYZ"))
        #expect(json["policy_version"] == .string("2026-07-17"))
        #expect(json["age_confirmed"] == .bool(true))
    }

    @Test("surfaces a stale revision as needing acceptance again")
    func rejectsStaleAcceptance() async throws {
        StubProtocol.respond = { _ in (400, Data(#"{"error":"join_policy_not_accepted"}"#.utf8)) }
        await #expect(throws: JoinPolicyClient.Failure.notAccepted) {
            _ = try await makePolicyClient().acceptPolicy(
                for: invite, version: "stale", ageConfirmed: true
            )
        }
    }

    /// `URLProtocol` hands the body back as a stream once it has been sent.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
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

    /// Just enough to assert on a mixed-type JSON body.
    private enum JSONValue: Decodable, Equatable {
        case string(String)
        case bool(Bool)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else {
                self = .string(try container.decode(String.self))
            }
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
