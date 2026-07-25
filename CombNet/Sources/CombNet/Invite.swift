import CombCore
import Foundation

/// An invitation to a community, however it arrived.
public struct InviteLink: Equatable, Sendable {
    /// The community's websocket relay URL.
    public let relayURL: URL
    /// The opaque invite code, claimed over HTTPS.
    public let code: String

    /// The HTTPS host the claim endpoint lives on.
    public var host: String { relayURL.host ?? "" }

    // MARK: - Parsing

    /// Accepts every form an invite arrives in:
    ///
    ///     https://<host>/invite/<code>
    ///     buzz://join?relay=wss://<host>&code=<code>
    ///     comb://join?relay=wss://<host>&code=<code>
    ///
    /// Pasted text gets whitespace trimmed and tracking parameters ignored.
    /// Universal links cannot open Comb (they need an AASA file on a domain a
    /// relay-agnostic client does not control), so pasting the https form is a
    /// first-class path, not a fallback.
    public static func parse(_ input: String) -> InviteLink? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased()
        else { return nil }

        switch scheme {
        case "https", "http":
            return parseWebLink(url)
        case "buzz", "comb":
            return parseAppLink(url)
        default:
            return nil
        }
    }

    private static func parseWebLink(_ url: URL) -> InviteLink? {
        // Path shape: /invite/<code>, exactly one code segment.
        let segments = url.path.split(separator: "/").map(String.init)
        guard segments.count == 2, segments[0] == "invite",
              let host = url.host, !host.isEmpty
        else { return nil }

        let code = segments[1]
        guard isPlausibleCode(code) else { return nil }

        // The relay is the same host over wss. Plain http is only trusted for
        // local development.
        let ws = url.scheme?.lowercased() == "http" ? "ws" : "wss"
        var components = URLComponents()
        components.scheme = ws
        components.host = host
        components.port = url.port
        guard let relayURL = components.url else { return nil }

        return InviteLink(relayURL: relayURL, code: code)
    }

    private static func parseAppLink(_ url: URL) -> InviteLink? {
        guard url.host?.lowercased() == "join",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        var relay: URL?
        var code: String?
        for item in components.queryItems ?? [] {
            switch item.name {
            case "relay": relay = item.value.flatMap(URL.init(string:))
            case "code": code = item.value
            default: break // tracking noise, ignored
            }
        }

        guard let relay, let scheme = relay.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws",
              let host = relay.host, !host.isEmpty,
              let code, isPlausibleCode(code)
        else { return nil }

        return InviteLink(relayURL: relay, code: code)
    }

    /// When the code says it stops working, if it says so at all.
    ///
    /// Read out of the payload segment, which is base64url JSON. Deliberately
    /// **unverified**: the MAC covers this payload but only the relay holds the
    /// key, so a forged expiry cannot be told from a real one here.
    ///
    /// That is why this is only ever allowed to fail an invite early, never to
    /// pass one. The relay checks the real expiry on every claim, so the worst
    /// a tampered date can do is make someone re-ask for a link that would have
    /// been refused anyway. Reading it lets Comb say so before a name has been
    /// typed and terms have been read, instead of after.
    ///
    /// Best-effort by construction: the format is Buzz's and may change, and
    /// anything that does not decode simply has no opinion.
    public var expiresAt: Date? {
        guard let payload = code.split(separator: ".").first,
              let data = Self.base64URLDecoded(String(payload)),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seconds = fields["e"] as? TimeInterval
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Whether the code says it has already expired. False whenever it does not
    /// say, so an unreadable code is still worth sending to the relay.
    public func hasExpired(asOf now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// base64url, padding optional. Buzz mints without it.
    static func base64URLDecoded(_ string: String) -> Data? {
        var encoded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }

    /// The relay's HTTP surface for this community. Every non-socket call
    /// (claiming, the join policy) is the same host over http(s), so the
    /// mapping lives here once rather than in each client.
    func httpURL(path: String) -> URL? {
        var components = URLComponents()
        components.scheme = relayURL.scheme?.lowercased() == "ws" ? "http" : "https"
        components.host = host
        components.port = relayURL.port
        components.path = path
        return components.url
    }

    /// Buzz codes are `base64url(payload).base64url(mac)`. The check here is
    /// deliberately loose, enough to reject obvious garbage without breaking
    /// when the server evolves the format.
    private static func isPlausibleCode(_ code: String) -> Bool {
        code.count >= 8 && code.count <= 512 && !code.contains(" ")
    }
}

/// Claims invites against a Buzz relay's HTTP API.
public struct InviteClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public struct Claim: Equatable, Sendable, Decodable {
        /// "joined", or "already_member" on an idempotent repeat.
        public let status: String
        public let host: String?
        public let role: String?

        enum CodingKeys: String, CodingKey { case status, host, role }

        public var isMember: Bool { status == "joined" || status == "already_member" }
    }

    /// Body for `POST /api/invites/claim`.
    private struct ClaimRequest: Encodable {
        let code: String
        let policyReceipt: String?

        enum CodingKeys: String, CodingKey {
            case code
            case policyReceipt = "policy_receipt"
        }
    }

    public enum Failure: Error, Equatable {
        /// The code is expired. The server distinguishes this one case because
        /// telling the user helps and telling a forger does not.
        case expired
        /// Bad code, wrong community, or forged. Deliberately coarse upstream.
        case invalid
        /// The operator requires their join policy accepted before this invite
        /// can be claimed. Recoverable: accept, then claim again with a receipt.
        case policyRequired
        /// Too many attempts; the relay rate-limits claims per pubkey.
        case rateLimited
        case serverError(Int)
        case malformedResponse
    }

    /// Claims the invite as `signer`'s identity.
    ///
    /// Buzz's own client mints a fresh keypair immediately before claiming, so
    /// per-community identity is the protocol's shape, not Comb's invention.
    /// The claim is idempotent: repeating it with the same key is safe.
    public func claim(
        _ invite: InviteLink,
        signer: some EventSigner,
        policyReceipt: String? = nil
    ) async throws -> Claim {
        guard let url = invite.httpURL(path: "/api/invites/claim") else { throw Failure.invalid }

        let body = try JSONEncoder().encode(
            ClaimRequest(code: invite.code, policyReceipt: policyReceipt)
        )

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // NIP-98: the header signs the exact body bytes, so they must not be
        // touched after this line.
        request.setValue(
            try await NIP98.authorizationHeader(url: url, method: "POST", body: body, signer: signer),
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }

        switch http.statusCode {
        case 200..<300:
            guard let claim = try? JSONDecoder().decode(Claim.self, from: data) else {
                throw Failure.malformedResponse
            }
            return claim
        case 403:
            let error = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            switch error {
            case "invite_expired":
                throw Failure.expired
            case "join_policy_required":
                // Not a bad invite: the operator requires their terms accepted
                // first. Told apart from `invalid` because the two ask entirely
                // different things of the person reading the message.
                throw Failure.policyRequired
            default:
                throw Failure.invalid
            }
        case 429:
            throw Failure.rateLimited
        default:
            throw Failure.serverError(http.statusCode)
        }
    }
}
