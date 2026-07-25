import Foundation

/// Terms a relay operator requires before an invite can be claimed.
///
/// This is the operator's policy, not Comb's. A relay declares one by serving
/// `GET /api/join-policy`; most do not, and a relay without one joins with no
/// extra step at all. That asymmetry is the point: the friction belongs to the
/// operator who chose it, and it follows you only onto their relay.
///
/// The claim flow is a three-step handshake when a policy exists:
/// fetch the policy, exchange an explicit acceptance for a short-lived receipt
/// bound to this invite code and this policy version, then send the receipt
/// with the claim. Without the receipt the relay answers 403
/// `join_policy_required`.
public struct JoinPolicy: Sendable, Equatable, Codable {
    /// Operator-authored Markdown. Rendered in the app rather than handed to a
    /// browser: sending someone out mid-onboarding is how apps get agreement
    /// without reading.
    public let termsMarkdown: String?
    public let privacyMarkdown: String?
    /// Whether the operator additionally requires a minimum-age assertion.
    /// Separate from accepting the terms, and the relay treats it separately,
    /// so it is asked as its own question.
    public let ageAttestationRequired: Bool
    /// The revision the person actually saw. Echoed back on acceptance so a
    /// receipt can never outlive the text it was granted against.
    public let version: String

    enum CodingKeys: String, CodingKey {
        case termsMarkdown = "terms_markdown"
        case privacyMarkdown = "privacy_markdown"
        case ageAttestationRequired = "age_attestation_required"
        case version
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        termsMarkdown = try container.decodeIfPresent(String.self, forKey: .termsMarkdown)
        privacyMarkdown = try container.decodeIfPresent(String.self, forKey: .privacyMarkdown)
        ageAttestationRequired =
            try container.decodeIfPresent(Bool.self, forKey: .ageAttestationRequired) ?? false
        version = try container.decode(String.self, forKey: .version)
    }

    public init(
        termsMarkdown: String?,
        privacyMarkdown: String?,
        ageAttestationRequired: Bool,
        version: String
    ) {
        self.termsMarkdown = termsMarkdown
        self.privacyMarkdown = privacyMarkdown
        self.ageAttestationRequired = ageAttestationRequired
        self.version = version
    }

    /// Whether there is anything for a person to actually read.
    public var hasDocuments: Bool {
        termsMarkdown?.isEmpty == false || privacyMarkdown?.isEmpty == false
    }

    /// Nothing to show and nothing to assert: a policy that asks for neither is
    /// not worth a step in the flow.
    public var isEmpty: Bool {
        !hasDocuments && !ageAttestationRequired
    }
}

/// Reads and accepts a relay's join policy.
public struct JoinPolicyClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public enum Failure: Error, Equatable {
        /// The operator changed the text, or the age box was not ticked. Either
        /// way the fix is to show the policy again.
        case notAccepted
        case notConfigured
        case serverError(Int)
        case malformedResponse
    }

    /// The policy for `host`, or nil when the operator has not configured one.
    ///
    /// Best-effort, like the NIP-11 fetch beside it: a host that never answers
    /// leaves the join screen unchanged rather than blocking it. A relay that
    /// does require a policy will still refuse the claim, which is the check
    /// that actually matters.
    public func policy(for invite: InviteLink) async throws -> JoinPolicy? {
        let url = try Self.endpoint(invite, path: "/api/join-policy")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.serverError(http.statusCode)
        }

        // `{}` is the documented "no policy here" answer, not an error.
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw Failure.malformedResponse
        }
        return envelope.policy
    }

    /// Exchanges an explicit acceptance for a receipt to send with the claim.
    ///
    /// Unauthenticated by design on the relay side: the receipt is bound to the
    /// invite code, so it proves acceptance for this join without needing to
    /// know who is joining yet.
    public func acceptPolicy(
        for invite: InviteLink,
        version: String,
        ageConfirmed: Bool
    ) async throws -> String {
        let url = try Self.endpoint(invite, path: "/api/invites/accept-policy")
        let body = try JSONEncoder().encode(
            AcceptanceRequest(
                code: invite.code,
                policyVersion: version,
                ageConfirmed: ageConfirmed
            )
        )

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }

        switch http.statusCode {
        case 200..<300:
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else {
                throw Failure.malformedResponse
            }
            return receipt.receipt
        case 400:
            // `join_policy_not_accepted`: a stale version, or the age box was
            // required and not ticked.
            throw Failure.notAccepted
        case 404:
            throw Failure.notConfigured
        default:
            throw Failure.serverError(http.statusCode)
        }
    }

    private static func endpoint(_ invite: InviteLink, path: String) throws -> URL {
        guard let url = invite.httpURL(path: path) else { throw Failure.malformedResponse }
        return url
    }

    private struct Envelope: Decodable {
        let policy: JoinPolicy?
    }

    private struct Receipt: Decodable {
        let receipt: String
    }

    private struct AcceptanceRequest: Encodable {
        let code: String
        let policyVersion: String
        let ageConfirmed: Bool

        enum CodingKeys: String, CodingKey {
            case code
            case policyVersion = "policy_version"
            case ageConfirmed = "age_confirmed"
        }
    }
}
