import Foundation

public extension ReadStateSync {
    /// NIP-RS gives every installation its own slot, `read-state:<random>`,
    /// rather than one fixed name per application.
    ///
    /// The two schemes coexist deliberately. Comb keeps publishing its own
    /// shape, because that one carries an `updatedAt` per marker and so can say
    /// "I marked this unread", which NIP-RS cannot: the spec is a grow-only
    /// maximum and says in as many words that it does not define mark-as-unread.
    /// Publishing both means the desktop sees the read line and Comb's own
    /// devices still see the whole decision.
    static let interopPrefix = "read-state:"
    static let interopTopic = "read-state"

    static func interopDTag(slot: String) -> String { interopPrefix + slot }

    /// The spec's default fetch and prune window.
    static let interopHorizon: Int64 = 7 * 24 * 60 * 60
}

/// A NIP-RS read-state blob: what another client publishes, and what Comb
/// publishes alongside its own shape.
///
/// Decoding is deliberately lenient in one place and strict everywhere else,
/// because the spec asks for both. A context entry whose timestamp is not an
/// integer is dropped on its own and the rest of the blob is still processed; a
/// missing `client_id` discards the whole thing. Getting that backwards would
/// either throw away a good blob over one bad row, or accept a blob that says
/// nothing about who wrote it.
public struct ReadStateBlob: Sendable, Equatable {
    /// Only version 1 exists. An unknown version is ignored rather than guessed
    /// at, the same rule Comb's own payload applies to itself.
    public static let currentVersion = 1

    public let version: Int
    /// Identifies the installation that wrote this, and is the only link
    /// between a blob and a device. Never visible to the relay: it lives inside
    /// the encrypted body.
    public let clientID: String
    /// Channel id to "everything at or before this second has been read".
    public let contexts: [String: Int64]

    public init(version: Int = ReadStateBlob.currentVersion, clientID: String, contexts: [String: Int64]) {
        self.version = version
        self.clientID = clientID
        self.contexts = contexts
    }

    /// Builds a blob from Comb's own markers, dropping contexts that have aged
    /// out of the horizon so the event does not grow without bound.
    ///
    /// Only the read line travels. A marker Comb has moved *backwards* through
    /// mark-as-unread is published at its lower value, which the spec forbids
    /// and which is nonetheless the honest answer: the alternative is claiming
    /// to have read something the reader explicitly un-read. Conformant readers
    /// take the maximum and ignore it, so the practical effect is that unread
    /// does not travel, which is what the spec intends.
    public init(
        clientID: String,
        markers: [ReadMarker],
        now: Int64,
        horizon: Int64 = ReadStateSync.interopHorizon
    ) {
        var contexts: [String: Int64] = [:]
        for marker in markers where marker.lastReadAt >= now - horizon {
            contexts[marker.channelID] = marker.lastReadAt
        }
        self.init(clientID: clientID, contexts: contexts)
    }

    /// The blob as Comb markers, stamped with when it was published.
    ///
    /// `publishedAt` is the event's own `created_at`, and it is what makes the
    /// chosen conflict rule fall out of the merge Comb already has. NIP-RS
    /// carries no per-context "when was this decided", so the blob's own clock
    /// is the best available answer, and last-writer-wins then means a
    /// deliberate mark-unread made after this blob was written survives it.
    public func markers(publishedAt: Int64) -> [ReadMarker] {
        contexts
            .map { ReadMarker(channelID: $0.key, lastReadAt: $0.value, updatedAt: publishedAt) }
            .sorted { $0.channelID < $1.channelID }
    }

    /// NIP-RS content validation, applied after decoding.
    ///
    /// Returns nil when the whole blob must be discarded. Individual context
    /// entries that fail are dropped from the returned blob rather than
    /// condemning it.
    public func validated() -> ReadStateBlob? {
        guard version == Self.currentVersion else { return nil }
        guard (1...64).contains(clientID.count) else { return nil }
        guard contexts.count <= 10_000 else { return nil }

        let kept = contexts.filter { context, timestamp in
            (0...4_294_967_295).contains(timestamp) && context.utf8.count <= 256
        }
        return ReadStateBlob(version: version, clientID: clientID, contexts: kept)
    }
}

extension ReadStateBlob: Codable {
    private enum Key: String, CodingKey {
        case version = "v"
        case clientID = "client_id"
        case contexts
    }

    /// A context id, which can be any string, so it cannot be a static enum.
    private struct ContextKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)

        // Missing or wrong-typed: the blob is discarded, by throwing.
        version = try container.decode(Int.self, forKey: .version)
        clientID = try container.decode(String.self, forKey: .clientID)

        // A `contexts` that is not an object throws here, which discards the
        // blob, as the spec requires.
        let entries = try container.nestedContainer(keyedBy: ContextKey.self, forKey: .contexts)
        var collected: [String: Int64] = [:]
        for key in entries.allKeys {
            // A single unreadable entry is dropped and the rest survive.
            guard let timestamp = try? entries.decode(Int64.self, forKey: key) else { continue }
            collected[key.stringValue] = timestamp
        }
        contexts = collected
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(version, forKey: .version)
        try container.encode(clientID, forKey: .clientID)

        var entries = container.nestedContainer(keyedBy: ContextKey.self, forKey: .contexts)
        // Sorted, so the same state encodes to the same bytes and a diff of two
        // published blobs is readable.
        for context in contexts.keys.sorted() {
            guard let key = ContextKey(stringValue: context) else { continue }
            try entries.encode(contexts[context], forKey: key)
        }
    }
}
