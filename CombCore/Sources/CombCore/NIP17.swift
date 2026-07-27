import Foundation

/// NIP-17 private direct messages: a rumor, sealed, then gift wrapped.
///
/// Three layers, each hiding something the one outside it must not see.
///
/// - The **rumor** (kind 14) is the message. It is deliberately *unsigned*: an
///   unsigned event proves nothing about who wrote it, so a leaked plaintext
///   cannot be shown to anyone as evidence. That deniability is the point.
/// - The **seal** (kind 13) is signed by the real sender and carries the
///   encrypted rumor. Only the recipient can open it, so only the recipient
///   learns who sent the message.
/// - The **gift wrap** (kind 1059) is signed by a throwaway key and carries the
///   encrypted seal. It is the only layer the relay sees, so the relay learns
///   that *somebody* sent *someone* a message, and nothing else.
///
/// This is a different mechanism from the DM channels Comb already shows, which
/// are NIP-29 groups wearing a `hidden` tag: those are ordinary group messages
/// that the relay stores and can read. Both are called direct messages, and
/// only one of them is private from the relay.
///
/// **Deliberately not wired to anything, and that is not an oversight.** Buzz
/// relays accept and route kind 1059 as a compatibility surface for third-party
/// clients, but no Buzz client reads it: their own DMs are the hidden-group kind
/// above, opened with `buzzOpenDirectMessage`. A gift wrap sent to a Buzz user
/// today would be stored correctly and never fetched by anyone.
///
/// So this is kept, tested, and unreachable, against the day Comb talks to a
/// relay whose clients do speak NIP-17. Anyone wiring it up should first check
/// that the other end has learned to listen. Deleting it is also a reasonable
/// answer; git remembers.
public enum NIP17 {
    /// A decrypted message, with the sender established rather than claimed.
    public struct Message: Sendable, Equatable {
        /// The real author, taken from the seal's signature. Never from the
        /// gift wrap, whose key is random, and never from the rumor, which is
        /// unsigned and so says only what its writer typed into it.
        public let sender: String
        /// Everyone the message is addressed to, from the rumor's `p` tags.
        public let recipients: [String]
        public let content: String
        /// The rumor's own timestamp, which is what the conversation is ordered
        /// by. The wrap's is deliberately fuzzed and means nothing.
        public let createdAt: Int64
        /// The rumor's computed id. Stable, because the id is a hash of the
        /// content, so two devices unwrapping the same message agree on it.
        public let id: String
        /// The conversation this belongs to, when the sender set one.
        public let subject: String?

        public init(
            sender: String,
            recipients: [String],
            content: String,
            createdAt: Int64,
            id: String,
            subject: String? = nil
        ) {
            self.sender = sender
            self.recipients = recipients
            self.content = content
            self.createdAt = createdAt
            self.id = id
            self.subject = subject
        }
    }

    public enum Failure: Error, Equatable {
        case notAGiftWrap
        case malformed
        /// The seal was not signed by the key that signed it, or not at all.
        case unverifiedSeal
        /// The rumor claims an author the seal does not support. This is the
        /// impersonation attempt the whole scheme turns on, so it is its own
        /// error rather than a generic malformation.
        case senderMismatch
        case wrongKinds
    }

    // MARK: - Opening

    /// Unwraps a kind 1059 addressed to `recipient`, returning the message.
    ///
    /// Every layer is checked rather than assumed. The relay chose which events
    /// to hand over and an attacker chose what to put in them, so the only
    /// facts worth anything here are the ones this function establishes:
    /// the seal verifies, and the rumor's author matches the seal's.
    public static func open(
        giftWrap: NostrEvent,
        recipient: PrivateKey
    ) throws -> Message {
        guard giftWrap.kind == .giftWrap else { throw Failure.notAGiftWrap }

        // The wrap's own signature is checked by the ingest choke point like
        // any other event. Its pubkey is a throwaway and says nothing about
        // who sent this, which is exactly what it is for.
        let sealKey = try NIP44.conversationKey(
            privateKey: recipient,
            peer: try publicKey(giftWrap.pubkey)
        )
        guard let sealJSON = try? NIP44.decrypt(giftWrap.content, conversationKey: sealKey),
              let seal = decode(sealJSON)
        else { throw Failure.malformed }

        guard seal.kind == .seal else { throw Failure.wrongKinds }

        // The one signature that matters. Everything the caller is told about
        // who sent this rests on it.
        guard seal.isValid else { throw Failure.unverifiedSeal }

        let rumorKey = try NIP44.conversationKey(
            privateKey: recipient,
            peer: try publicKey(seal.pubkey)
        )
        guard let rumorJSON = try? NIP44.decrypt(seal.content, conversationKey: rumorKey),
              let rumor = decode(rumorJSON)
        else { throw Failure.malformed }

        guard rumor.kind == .directMessage else { throw Failure.wrongKinds }

        // A rumor is unsigned, so its `pubkey` field is just a string somebody
        // typed. Without this check anyone could seal a rumor claiming to be
        // from anyone, and the recipient would render it as them.
        guard rumor.pubkey == seal.pubkey else { throw Failure.senderMismatch }

        return Message(
            sender: seal.pubkey,
            recipients: rumor.tags.compactMap {
                $0.count >= 2 && $0[0] == "p" ? $0[1] : nil
            },
            content: rumor.content,
            createdAt: rumor.createdAt,
            // Recomputed, not read: an unsigned event's id is only as good as
            // the arithmetic, and nothing has vouched for the one it carries.
            id: NostrEvent.computeID(
                pubkey: rumor.pubkey,
                createdAt: rumor.createdAt,
                kind: rumor.kind,
                tags: rumor.tags,
                content: rumor.content
            ).hex,
            subject: rumor.tags.first { $0.count >= 2 && $0[0] == "subject" }?[1]
        )
    }

    // MARK: - Sealing

    /// Builds one gift wrap per recipient, plus one addressed back to the
    /// sender.
    ///
    /// The copy to self is not a nicety: a gift wrap is encrypted to exactly one
    /// key, so without it the sender's own devices could never read what the
    /// sender sent. It is how a sent message survives being sent.
    public static func wrap(
        content: String,
        to recipients: [String],
        subject: String? = nil,
        from sender: PrivateKey,
        createdAt: Date = Date()
    ) throws -> [NostrEvent] {
        var tags: [[String]] = recipients.map { ["p", $0] }
        if let subject { tags.append(["subject", subject]) }

        let timestamp = Int64(createdAt.timeIntervalSince1970)
        let rumor = NostrEvent(
            // No signature, by design. The id is still computed so the message
            // has a stable identity to deduplicate and reply to.
            id: NostrEvent.computeID(
                pubkey: sender.publicKey.hex,
                createdAt: timestamp,
                kind: .directMessage,
                tags: tags,
                content: content
            ).hex,
            pubkey: sender.publicKey.hex,
            createdAt: timestamp,
            kind: .directMessage,
            tags: tags,
            content: content,
            sig: ""
        )
        let rumorJSON = try encode(rumor)

        // Everyone named, and the sender too, deduplicated so addressing
        // yourself explicitly does not produce two copies.
        var audience = recipients
        if !audience.contains(sender.publicKey.hex) { audience.append(sender.publicKey.hex) }

        return try audience.map { recipientHex in
            let peer = try publicKey(recipientHex)

            let seal = try NostrEvent.signed(
                kind: .seal,
                content: try NIP44.encrypt(
                    rumorJSON,
                    conversationKey: try NIP44.conversationKey(privateKey: sender, peer: peer)
                ),
                tags: [],
                // Fuzzed like the wrap's: a seal's timestamp is visible only to
                // the recipient, but leaving it exact would hand them a
                // second, more precise clock than the rumor's.
                createdAt: fuzzed(createdAt),
                with: sender
            )

            // A fresh key per wrap, never reused and never stored. Reusing one
            // would let the relay link every message a sender ever wrapped.
            let ephemeral = try PrivateKey()
            return try NostrEvent.signed(
                kind: .giftWrap,
                content: try NIP44.encrypt(
                    try encode(seal),
                    conversationKey: try NIP44.conversationKey(privateKey: ephemeral, peer: peer)
                ),
                tags: [["p", recipientHex]],
                createdAt: fuzzed(createdAt),
                with: ephemeral
            )
        }
    }

    /// Backdates by up to two days, as NIP-17 asks.
    ///
    /// The wrap's timestamp is the one thing about a private message a relay
    /// can read, so leaving it exact would let anyone watching reconstruct
    /// conversation timing from metadata alone. The rumor inside carries the
    /// real time, where only the recipient can see it.
    private static func fuzzed(_ date: Date) -> Date {
        date.addingTimeInterval(-Double.random(in: 0...(2 * 24 * 60 * 60)))
    }

    // MARK: - Plumbing

    private static func publicKey(_ hex: String) throws -> PublicKey {
        guard let key = PublicKey(hex: hex) else { throw Failure.malformed }
        return key
    }

    private static func decode(_ json: String) -> NostrEvent? {
        try? JSONDecoder().decode(NostrEvent.self, from: Data(json.utf8))
    }

    private static func encode(_ event: NostrEvent) throws -> String {
        String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    }
}
