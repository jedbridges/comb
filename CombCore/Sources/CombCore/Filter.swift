import Foundation

/// A NIP-01 subscription filter.
///
/// Fields combine with AND; values within a field combine with OR. Omitted
/// fields are unconstrained, so an empty filter matches everything a relay is
/// willing to serve.
public struct Filter: Codable, Hashable, Sendable {
    public var ids: [String]?
    public var authors: [String]?
    public var kinds: [EventKind]?
    public var since: Int64?
    public var until: Int64?
    public var limit: Int?
    public var search: String?

    /// Single-letter tag filters, keyed without the leading `#`.
    ///
    /// Stored separately because NIP-01 spells them as dynamic `#e` / `#p` /
    /// `#h` keys, which no static `CodingKeys` enum can express.
    public var tags: [String: [String]]

    public init(
        ids: [String]? = nil,
        authors: [String]? = nil,
        kinds: [EventKind]? = nil,
        since: Int64? = nil,
        until: Int64? = nil,
        limit: Int? = nil,
        search: String? = nil,
        tags: [String: [String]] = [:]
    ) {
        self.ids = ids
        self.authors = authors
        self.kinds = kinds
        self.since = since
        self.until = until
        self.limit = limit
        self.search = search
        self.tags = tags
    }

    // MARK: - Builders

    /// Constrains the filter to a NIP-29 group via its `h` tag.
    public func inGroup(_ groupID: String) -> Filter {
        var copy = self
        copy.tags["h"] = [groupID]
        return copy
    }

    /// Constrains the filter to events tagging a pubkey.
    ///
    /// Required, not optional, for the p-gated kinds (gift wraps and membership
    /// notices): a Buzz relay rejects a global subscription for those unless it
    /// carries a `#p` matching the authenticated pubkey.
    public func taggingPubkey(_ pubkey: String) -> Filter {
        var copy = self
        copy.tags["p"] = [pubkey]
        return copy
    }

    public func referencingEvent(_ eventID: String) -> Filter {
        var copy = self
        copy.tags["e"] = [eventID]
        return copy
    }

    public func withTag(_ name: String, _ values: [String]) -> Filter {
        var copy = self
        copy.tags[name] = values
        return copy
    }

    /// Kinds that a relay will refuse to serve globally, requiring a `#p` filter
    /// scoped to the authenticated user. Subscribing without one leaks nothing,
    /// it simply fails, so the client should catch this before sending.
    public static let pGatedKinds: Set<EventKind> = [
        .giftWrap, .buzzMemberAdded, .buzzMemberRemoved,
    ]

    /// True when this filter requests p-gated kinds without scoping to a pubkey.
    public var needsPubkeyScope: Bool {
        guard let kinds, kinds.contains(where: { Self.pGatedKinds.contains($0) }) else {
            return false
        }
        return tags["p"]?.isEmpty != false
    }

    // MARK: - Canonical form

    /// Encodes with sorted keys, giving byte-identical output for equal filters.
    ///
    /// Plain `JSONEncoder` guarantees no key ordering for keyed containers, so two
    /// encodes of the same filter can differ. Anything comparing filters as
    /// strings (logging, cache keys, test assertions) must go through this.
    /// Prefer `Hashable` conformance where a value comparison will do.
    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    // MARK: - Codable

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ string: String) { self.stringValue = string }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        ids = try container.decodeIfPresent([String].self, forKey: .init("ids"))
        authors = try container.decodeIfPresent([String].self, forKey: .init("authors"))
        kinds = try container.decodeIfPresent([EventKind].self, forKey: .init("kinds"))
        since = try container.decodeIfPresent(Int64.self, forKey: .init("since"))
        until = try container.decodeIfPresent(Int64.self, forKey: .init("until"))
        limit = try container.decodeIfPresent(Int.self, forKey: .init("limit"))
        search = try container.decodeIfPresent(String.self, forKey: .init("search"))

        var collected: [String: [String]] = [:]
        for key in container.allKeys where key.stringValue.hasPrefix("#") {
            let name = String(key.stringValue.dropFirst())
            collected[name] = try container.decode([String].self, forKey: key)
        }
        tags = collected
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)

        try container.encodeIfPresent(ids, forKey: .init("ids"))
        try container.encodeIfPresent(authors, forKey: .init("authors"))
        try container.encodeIfPresent(kinds, forKey: .init("kinds"))
        try container.encodeIfPresent(since, forKey: .init("since"))
        try container.encodeIfPresent(until, forKey: .init("until"))
        try container.encodeIfPresent(limit, forKey: .init("limit"))
        try container.encodeIfPresent(search, forKey: .init("search"))

        // Sorted so encoding is deterministic, which keeps subscription
        // deduplication and test assertions stable.
        for name in tags.keys.sorted() {
            try container.encode(tags[name], forKey: .init("#\(name)"))
        }
    }
}
