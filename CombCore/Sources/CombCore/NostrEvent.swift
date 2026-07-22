import Foundation
import P256K

/// A signed Nostr event, exactly as it appears on the wire (NIP-01).
///
/// Immutable by construction. An event's id is a hash over its own contents, so
/// mutating any field would invalidate both the id and the signature; the only
/// supported way to produce one is `NostrEvent.signed(...)`.
public struct NostrEvent: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let pubkey: String
    public let createdAt: Int64
    public let kind: EventKind
    public let tags: [[String]]
    public let content: String
    public let sig: String

    enum CodingKeys: String, CodingKey {
        case id, pubkey, kind, tags, content, sig
        case createdAt = "created_at"
    }

    public init(
        id: String,
        pubkey: String,
        createdAt: Int64,
        kind: EventKind,
        tags: [[String]],
        content: String,
        sig: String
    ) {
        self.id = id
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.kind = kind
        self.tags = tags
        self.content = content
        self.sig = sig
    }

    // MARK: - Creation

    /// Builds and signs an event, deriving `pubkey` and `id` from the inputs.
    public static func signed(
        kind: EventKind,
        content: String,
        tags: [[String]] = [],
        createdAt: Date = Date(),
        with key: PrivateKey
    ) throws -> NostrEvent {
        let pubkey = key.publicKey.hex
        let timestamp = Int64(createdAt.timeIntervalSince1970)
        let id = computeID(
            pubkey: pubkey,
            createdAt: timestamp,
            kind: kind,
            tags: tags,
            content: content
        )
        let signature = try key.signMessage(id)

        return NostrEvent(
            id: id.hex,
            pubkey: pubkey,
            createdAt: timestamp,
            kind: kind,
            tags: tags,
            content: content,
            sig: signature.hex
        )
    }

    /// The NIP-01 event id: SHA-256 over the canonical serialization.
    public static func computeID(
        pubkey: String,
        createdAt: Int64,
        kind: EventKind,
        tags: [[String]],
        content: String
    ) -> Data {
        let canonical = CanonicalJSON.serialize(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content
        )
        return Data(SHA256.hash(data: canonical))
    }

    // MARK: - Validation

    /// Recomputes the id and checks it matches the claimed one.
    public var hasValidID: Bool {
        let expected = Self.computeID(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content
        )
        return expected.hex == id
    }

    /// Full validation: the id must match its contents *and* the signature must
    /// verify against the claimed pubkey.
    ///
    /// Checking the signature alone would be insufficient. Without also
    /// recomputing the id, a relay could serve an event whose content had been
    /// swapped while keeping a signature that verifies over the original id.
    public var isValid: Bool {
        guard hasValidID,
              let key = PublicKey(hex: pubkey),
              let signature = Data(hex: sig),
              let message = Data(hex: id)
        else { return false }
        return verifySignature(signature, message: message, publicKey: key)
    }

    // MARK: - Accessors

    public var author: PublicKey? { PublicKey(hex: pubkey) }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }

    /// First value of the first tag with the given name, the common case.
    public func firstValue(for tag: String) -> String? {
        tags.first { $0.first == tag && $0.count > 1 }?[1]
    }

    /// Every value across all tags with the given name.
    public func values(for tag: String) -> [String] {
        tags.compactMap { $0.first == tag && $0.count > 1 ? $0[1] : nil }
    }

    /// The NIP-29 group this event belongs to, from its `h` tag.
    ///
    /// Events without one are community-global on a Buzz relay: profiles,
    /// wrapped DMs, membership notices.
    public var groupID: String? { firstValue(for: "h") }

    /// The `d` tag identifying an addressable event (NIP-01 kind 30000..39999).
    public var addressableIdentifier: String? { firstValue(for: "d") }

    public var referencedEventIDs: [String] { values(for: "e") }
    public var referencedPubkeys: [String] { values(for: "p") }

    /// The event this one replies to, per NIP-10 marked tags.
    ///
    /// Prefers an explicit `reply` marker, falling back to `root` so a direct
    /// reply to a thread's opening message still threads correctly.
    public var replyTarget: String? {
        for tag in tags where tag.first == "e" && tag.count >= 4 {
            if tag[3] == "reply" { return tag[1] }
        }
        for tag in tags where tag.first == "e" && tag.count >= 4 {
            if tag[3] == "root" { return tag[1] }
        }
        return nil
    }

    /// The thread root per NIP-10, if this event is part of a thread.
    public var threadRoot: String? {
        for tag in tags where tag.first == "e" && tag.count >= 4 {
            if tag[3] == "root" { return tag[1] }
        }
        return nil
    }
}
