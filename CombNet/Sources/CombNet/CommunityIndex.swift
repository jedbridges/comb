import Foundation

/// The community discovery index.
///
/// Buzz deliberately prevents discovery at the protocol level: every relay
/// serves an identical NIP-11 document, and even nonexistent hosts answer 200,
/// specifically so nobody can enumerate communities. So discovery is a plain
/// JSON file in the Comb repository, added to by pull request, fetched over
/// TLS. It is not signed: a signature without a trust anchor baked into the
/// app would be theatre, and baking one in would contradict the
/// no-privileged-relay principle. The README says exactly this.
public struct CommunityIndex: Equatable, Sendable, Decodable {
    public let version: Int
    public let communities: [Entry]

    /// The current schema. A document with a newer version is refused rather
    /// than half-understood.
    public static let supportedVersion = 1

    public struct Entry: Equatable, Sendable, Decodable, Identifiable {
        public let id: String
        public let name: String
        public let description: String?
        public let relay: URL
        public let icon: URL?
        public let tags: [String]
        public let join: Join

        enum CodingKeys: String, CodingKey {
            case id, name, description, relay, icon, tags, join
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            relay = try container.decode(URL.self, forKey: .relay)
            icon = try container.decodeIfPresent(URL.self, forKey: .icon)
            tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
            join = try container.decodeIfPresent(Join.self, forKey: .join) ?? .init(kind: "request_only", url: nil)
        }

        /// What actually happens when the join button is tapped. Carried in the
        /// index so the browse UI never promises what a relay will refuse.
        public struct Join: Equatable, Sendable, Decodable {
            /// "invite_url" | "open" | "request_only"
            public let kind: String
            public let url: URL?
        }

        /// An entry is only usable if its relay URL is a public websocket.
        /// The private-range check is the same SSRF guard Buzz's own client
        /// applies to user-supplied relay URLs.
        public var isValid: Bool {
            guard let scheme = relay.scheme?.lowercased(), scheme == "wss",
                  let host = relay.host, !host.isEmpty
            else { return false }
            return !Self.isPrivateHost(host)
        }

        static func isPrivateHost(_ host: String) -> Bool {
            if host == "localhost" || host.hasSuffix(".local") { return true }
            let parts = host.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { return false }
            if parts[0] == 10 || parts[0] == 127 { return true }
            if parts[0] == 192, parts[1] == 168 { return true }
            if parts[0] == 172, (16...31).contains(parts[1]) { return true }
            if parts[0] == 169, parts[1] == 254 { return true }
            return false
        }
    }
}

/// Loads the index: bundled seed instantly, refreshed copy from the network.
public actor CommunityIndexService {
    public static let defaultSource = URL(
        string: "https://raw.githubusercontent.com/jedbridges/comb/main/communities/index.json"
    )!

    /// Refuses documents beyond this size; the index is text, not a payload.
    static let byteLimit = 512 * 1024

    private let session: URLSession
    private let source: URL
    private let bundled: CommunityIndex?

    public init(
        source: URL = defaultSource,
        bundledData: Data? = nil,
        session: URLSession = .shared
    ) {
        self.source = source
        self.session = session
        self.bundled = bundledData.flatMap { try? Self.decode($0) }
    }

    /// The bundled entries, available before any network.
    public nonisolated var seeded: [CommunityIndex.Entry] {
        bundled?.communities.filter(\.isValid) ?? []
    }

    /// Fetches the live index, falling back to the seed on any failure.
    /// Errors are absorbed by design: discovery degrading to the bundled copy
    /// is strictly better than an error screen on the welcome flow.
    public func entries() async -> [CommunityIndex.Entry] {
        guard source.scheme?.lowercased() == "https" else { return seeded }

        var request = URLRequest(url: source, timeoutInterval: 10)
        request.cachePolicy = .reloadRevalidatingCacheData

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= Self.byteLimit,
              let index = try? Self.decode(data)
        else { return seeded }

        return index.communities.filter(\.isValid)
    }

    static func decode(_ data: Data) throws -> CommunityIndex {
        let index = try JSONDecoder().decode(CommunityIndex.self, from: data)
        guard index.version <= CommunityIndex.supportedVersion else {
            throw IndexError.unsupportedVersion(index.version)
        }
        return index
    }

    public enum IndexError: Error, Equatable {
        case unsupportedVersion(Int)
    }
}
