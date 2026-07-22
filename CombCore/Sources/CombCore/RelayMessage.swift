import Foundation

/// A message sent from client to relay (NIP-01, NIP-42).
///
/// These are heterogeneous JSON arrays rather than objects, so both directions
/// are encoded and decoded by hand against an unkeyed container.
public enum ClientMessage: Sendable {
    case event(NostrEvent)
    case req(subscriptionID: String, filters: [Filter])
    case close(subscriptionID: String)
    case auth(NostrEvent)

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()

        switch self {
        case .event(let event):
            return try encode(["EVENT"], appending: [event], with: encoder)
        case .auth(let event):
            return try encode(["AUTH"], appending: [event], with: encoder)
        case .close(let id):
            return try encoder.encode(["CLOSE", id])
        case .req(let id, let filters):
            // ["REQ", <id>, <filter>, <filter>, ...]
            var elements: [Data] = [try encoder.encode("REQ"), try encoder.encode(id)]
            elements.append(contentsOf: try filters.map { try encoder.encode($0) })
            return joinArray(elements)
        }
    }

    private func encode(
        _ prefix: [String],
        appending events: [NostrEvent],
        with encoder: JSONEncoder
    ) throws -> Data {
        var elements = try prefix.map { try encoder.encode($0) }
        elements.append(contentsOf: try events.map { try encoder.encode($0) })
        return joinArray(elements)
    }

    /// Splices pre-encoded JSON fragments into one array. Building the array
    /// this way avoids a type-erased `[Any]` round trip through
    /// `JSONSerialization`, which would lose `Codable` conformance details.
    private func joinArray(_ elements: [Data]) -> Data {
        var out = Data("[".utf8)
        for (index, element) in elements.enumerated() {
            if index > 0 { out.append(Data(",".utf8)) }
            out.append(element)
        }
        out.append(Data("]".utf8))
        return out
    }
}

/// A message sent from relay to client (NIP-01, NIP-42).
public enum RelayMessage: Sendable, Equatable {
    /// An event matching an active subscription.
    case event(subscriptionID: String, event: NostrEvent)
    /// End of stored events: everything after this is live.
    case endOfStoredEvents(subscriptionID: String)
    /// The relay's verdict on a publish attempt.
    case ok(eventID: String, accepted: Bool, message: String)
    /// The relay closed a subscription, typically a policy refusal.
    case closed(subscriptionID: String, message: String)
    /// A human-readable notice, usually an error.
    case notice(String)
    /// A NIP-42 challenge the client must sign to authenticate.
    case authChallenge(String)

    public enum DecodingFailure: Error, Equatable {
        case notAnArray
        case emptyMessage
        case unknownType(String)
        case malformed(type: String)
    }

    public init(json: Data) throws {
        guard let array = try JSONSerialization.jsonObject(with: json) as? [Any] else {
            throw DecodingFailure.notAnArray
        }
        guard let type = array.first as? String else {
            throw DecodingFailure.emptyMessage
        }

        func string(_ index: Int) throws -> String {
            guard index < array.count, let value = array[index] as? String else {
                throw DecodingFailure.malformed(type: type)
            }
            return value
        }

        func event(_ index: Int) throws -> NostrEvent {
            guard index < array.count, let object = array[index] as? [String: Any] else {
                throw DecodingFailure.malformed(type: type)
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(NostrEvent.self, from: data)
        }

        switch type {
        case "EVENT":
            self = .event(subscriptionID: try string(1), event: try event(2))

        case "EOSE":
            self = .endOfStoredEvents(subscriptionID: try string(1))

        case "OK":
            guard array.count >= 3, let accepted = array[2] as? Bool else {
                throw DecodingFailure.malformed(type: type)
            }
            // The trailing message is optional in practice despite the spec.
            let message = array.count > 3 ? (array[3] as? String ?? "") : ""
            self = .ok(eventID: try string(1), accepted: accepted, message: message)

        case "CLOSED":
            let message = array.count > 2 ? (array[2] as? String ?? "") : ""
            self = .closed(subscriptionID: try string(1), message: message)

        case "NOTICE":
            self = .notice(try string(1))

        case "AUTH":
            self = .authChallenge(try string(1))

        default:
            throw DecodingFailure.unknownType(type)
        }
    }
}

// MARK: - NIP-42

public extension NostrEvent {
    /// Builds the kind 22242 event that answers a relay's AUTH challenge.
    ///
    /// The relay checks that the challenge matches the one it issued and that
    /// the relay URL names itself, which is what stops a signed response from
    /// being replayed against a different relay.
    static func authResponse(
        challenge: String,
        relayURL: URL,
        with key: PrivateKey
    ) throws -> NostrEvent {
        try signed(
            kind: .clientAuth,
            content: "",
            tags: authTags(challenge: challenge, relayURL: relayURL),
            with: key
        )
    }

    /// The signer-based form, which is what the relay session uses: the app's
    /// key lives in the Keychain and is never handed around as a value.
    static func authResponse(
        challenge: String,
        relayURL: URL,
        with signer: some EventSigner
    ) async throws -> NostrEvent {
        try await signer.sign(
            kind: .clientAuth,
            content: "",
            tags: authTags(challenge: challenge, relayURL: relayURL)
        )
    }

    private static func authTags(challenge: String, relayURL: URL) -> [[String]] {
        [
            ["relay", relayURL.absoluteString],
            ["challenge", challenge],
        ]
    }
}
