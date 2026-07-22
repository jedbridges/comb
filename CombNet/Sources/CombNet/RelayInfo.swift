import Foundation

/// A relay's NIP-11 information document.
///
/// Fetched unauthenticated before connecting, which makes it the only thing
/// Comb can learn about a relay before committing to it. That is what the join
/// screen uses to prove a host exists and to decide which features to offer.
///
/// Note what is *not* here for a Buzz relay: `name` and `description` are
/// hardcoded identical strings across every community on the service, and
/// `icon` is the only field that varies per community. So this document
/// confirms a relay is real and says what it can do; it cannot tell you which
/// community you are looking at.
public struct RelayInfo: Sendable, Equatable, Codable {
    public let name: String?
    public let description: String?
    public let icon: String?
    public let software: String?
    public let version: String?
    public let supportedNIPs: [Int]
    public let supportedExtensions: [String]
    public let limitation: Limitation?
    /// The relay's own pubkey, which it signs group state with.
    public let selfPubkey: String?
    /// Buzz's device-pairing relay, used by the `nostrpair://` handshake.
    public let pairingRelayURL: String?

    enum CodingKeys: String, CodingKey {
        case name, description, icon, software, version, limitation
        case supportedNIPs = "supported_nips"
        case supportedExtensions = "supported_extensions"
        case selfPubkey = "self"
        case pairingRelayURL = "pairing_relay_url"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        software = try container.decodeIfPresent(String.self, forKey: .software)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        limitation = try container.decodeIfPresent(Limitation.self, forKey: .limitation)
        selfPubkey = try container.decodeIfPresent(String.self, forKey: .selfPubkey)
        pairingRelayURL = try container.decodeIfPresent(String.self, forKey: .pairingRelayURL)
        // Absent rather than empty on plenty of relays, and a missing list must
        // not fail the whole document.
        supportedNIPs = try container.decodeIfPresent([Int].self, forKey: .supportedNIPs) ?? []
        supportedExtensions =
            try container.decodeIfPresent([String].self, forKey: .supportedExtensions) ?? []
    }

    public struct Limitation: Sendable, Equatable, Codable {
        public let authRequired: Bool?
        public let restrictedWrites: Bool?
        public let paymentRequired: Bool?
        public let maxSubscriptions: Int?
        public let maxFilters: Int?
        public let maxLimit: Int?
        public let maxMessageLength: Int?
        public let maxSubidLength: Int?

        enum CodingKeys: String, CodingKey {
            case authRequired = "auth_required"
            case restrictedWrites = "restricted_writes"
            case paymentRequired = "payment_required"
            case maxSubscriptions = "max_subscriptions"
            case maxFilters = "max_filters"
            case maxLimit = "max_limit"
            case maxMessageLength = "max_message_length"
            case maxSubidLength = "max_subid_length"
        }
    }

    // MARK: - Capabilities
    //
    // Feature decisions are made from what a relay says it supports, never from
    // whether it happens to be a Buzz relay. That is what keeps Comb usable
    // against a plain NIP-29 relay.

    /// NIP-29 relay-based groups: the minimum Comb needs to be useful at all.
    public var supportsGroups: Bool { supportedNIPs.contains(29) }
    /// NIP-42 authentication.
    public var supportsAuth: Bool { supportedNIPs.contains(42) }
    /// NIP-50 search, which the search screen degrades without.
    public var supportsSearch: Bool { supportedNIPs.contains(50) }
    /// NIP-17 private messages.
    public var supportsPrivateMessages: Bool { supportedNIPs.contains(17) }

    /// True when the relay demands NIP-42 before serving anything. Hosted Buzz
    /// relays always do.
    public var requiresAuth: Bool { limitation?.authRequired ?? false }

    /// Whether this is Buzz's own relay software, which is the gate for the
    /// non-standard kinds. Comb renders those when present and never requires
    /// them, so this only ever enables extras.
    public var isBuzzRelay: Bool { software == "https://github.com/block/buzz" }

    /// Whether Comb can work with this relay at all.
    public var isUsable: Bool { supportsGroups }

    /// The relay's advertised subscription ceiling, with a conservative default
    /// for relays that do not say.
    public var subscriptionLimit: Int { limitation?.maxSubscriptions ?? 20 }

    /// Filters allowed in one REQ, which caps how many channels a single
    /// subscription can cover.
    public var filterLimit: Int { limitation?.maxFilters ?? 10 }
}

/// Fetches NIP-11 documents.
public struct RelayInfoClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public enum Failure: Error, Equatable {
        case invalidURL
        case notARelay(status: Int)
        case malformedDocument
    }

    /// Fetches a relay's information document.
    ///
    /// Accepts either a websocket or an https URL, since users paste both. Note
    /// that a Buzz host that maps to no community still answers 200 with the
    /// same document, deliberately, so that nobody can probe which communities
    /// exist. A successful fetch therefore proves the host runs a relay, not
    /// that the community on it is real.
    public func fetch(from url: URL, timeout: TimeInterval = 10) async throws -> RelayInfo {
        guard let httpURL = Self.httpURL(for: url) else { throw Failure.invalidURL }

        var request = URLRequest(url: httpURL, timeoutInterval: timeout)
        request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.notARelay(status: http.statusCode)
        }
        guard let info = try? JSONDecoder().decode(RelayInfo.self, from: data) else {
            throw Failure.malformedDocument
        }
        return info
    }

    /// Maps a relay URL to the https URL its information document lives at.
    static func httpURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "wss", "https": components.scheme = "https"
        // Plain ws is only ever a local development relay; anywhere else it
        // would mean sending an auth event over an unencrypted socket.
        case "ws", "http": components.scheme = "http"
        default: return nil
        }
        // URLComponents reports an empty host rather than nil for a bare
        // "wss://", which would otherwise map to "https:///".
        guard let host = components.host, !host.isEmpty else { return nil }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
