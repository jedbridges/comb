import CombCore
import Foundation
import GRDB

/// Turns events into projection rows.
///
/// Every function here is pure with respect to the log: given the same event it
/// writes the same rows. The live ingest path and the rebuild path both call
/// `project`, which is what stops them from drifting apart. If you add a case,
/// bump `Schema.projectionVersion`.
enum Projector {
    static func project(_ event: NostrEvent, into db: Database) throws {
        switch event.kind {
        case .groupMetadata:
            try projectChannel(event, into: db)
        case .groupMembers:
            try projectMembers(event, into: db)
        case .metadata:
            try projectProfile(event, into: db)
        case .reaction:
            try projectReaction(event, into: db)
        case .zapReceipt:
            try projectZap(event, into: db)
        case .buzzZapAttestation:
            try projectAttestation(event, into: db)
        case .deletion, .groupDeleteEvent:
            try projectDeletion(event, into: db)
        case .buzzEdit:
            try projectEdit(event, into: db)
        case .buzzRichContent:
            try projectRichContent(event, into: db)
        case .groupChatMessage:
            try projectThread(event, into: db)
        case .buzzMemberAdded, .buzzMemberRemoved:
            try projectMembershipChange(event, into: db)
        default:
            // Everything else needs no projection; the timeline reads the log
            // directly.
            break
        }
    }

    // MARK: - Threads

    /// Records a message's place in a thread, when it has one.
    ///
    /// Only real replies get a row. That is what lets the channel timeline
    /// exclude replies with a single `NOT EXISTS` instead of decoding tag JSON
    /// for every message it renders.
    private static func projectThread(_ event: NostrEvent, into db: Database) throws {
        let reference = event.threadReference
        guard let parent = reference.parentID, let root = reference.rootID else { return }

        try db.execute(
            sql: """
                INSERT INTO thread
                    (event_id, root_id, parent_id, channel_id, pubkey, created_at, broadcast)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(event_id) DO NOTHING
                """,
            arguments: [
                event.id,
                root,
                parent,
                event.groupID,
                event.pubkey,
                event.createdAt,
                event.isBroadcastReply,
            ]
        )
    }

    // MARK: - Channels

    /// Kind 39000, relay-signed and addressable by `d`.
    private static func projectChannel(_ event: NostrEvent, into db: Database) throws {
        guard let id = event.addressableIdentifier else { return }
        let meta = try? JSONDecoder().decode(ChannelMetadata.self, from: Data(event.content.utf8))

        // Addressable events replace by (pubkey, kind, d), and a relay can resend
        // an older one after a reconnect, so ignore anything staler than what we
        // already hold.
        try db.execute(
            sql: """
                INSERT INTO channel (id, name, about, picture, is_private, is_dm, source_event_id, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    about = excluded.about,
                    picture = excluded.picture,
                    is_private = excluded.is_private,
                    is_dm = excluded.is_dm,
                    source_event_id = excluded.source_event_id,
                    updated_at = excluded.updated_at
                WHERE excluded.updated_at > channel.updated_at
                """,
            arguments: [
                id,
                meta?.name ?? event.firstValue(for: "name"),
                meta?.about ?? event.firstValue(for: "about"),
                meta?.picture ?? event.firstValue(for: "picture"),
                // NIP-29 marks closed groups with a bare `private` tag.
                event.tags.contains { $0.first == "private" },
                // And a direct message with a bare `hidden` tag, whose stated
                // purpose is to keep DMs out of a public channel list. It is a
                // display hint, not access control, which is exactly what this
                // column is used for.
                event.tags.contains { $0.first == "hidden" },
                event.id,
                event.createdAt,
            ]
        )
    }

    /// Kinds 44100 and 44101, the relay-signed notices that this account was
    /// added to or removed from a channel.
    ///
    /// These are only ever about the reader. The relay refuses a subscription
    /// to them that is not scoped to the authenticated pubkey (`NOSTR.md`:
    /// "p-gated events require #p matching your pubkey"), so an event of these
    /// kinds cannot reach this log describing somebody else. That is what lets
    /// this run without knowing who the viewer is, which a projector cannot.
    ///
    /// Newer wins rather than last-replayed wins: leaving and rejoining a
    /// channel is ordinary, and a rebuild replays in timestamp order, so the
    /// answer has to come from the timestamps rather than the order of arrival.
    private static func projectMembershipChange(
        _ event: NostrEvent, into db: Database
    ) throws {
        guard let channel = event.firstValue(for: "h") else { return }

        if event.kind == .buzzMemberRemoved {
            try db.execute(
                sql: """
                    INSERT INTO channel_departure (channel_id, removed_at)
                    VALUES (?, ?)
                    ON CONFLICT(channel_id) DO UPDATE SET removed_at = excluded.removed_at
                    WHERE excluded.removed_at > channel_departure.removed_at
                    """,
                arguments: [channel, event.createdAt]
            )
        } else {
            // Re-added: the departure only stops applying if this is the more
            // recent of the two.
            try db.execute(
                sql: "DELETE FROM channel_departure WHERE channel_id = ? AND removed_at <= ?",
                arguments: [channel, event.createdAt]
            )
        }
    }

    /// Kind 39002, the relay-signed member roster.
    private static func projectMembers(_ event: NostrEvent, into db: Database) throws {
        guard let channelID = event.addressableIdentifier else { return }

        // The roster is authoritative and complete, so it replaces rather than
        // merges. A member removed upstream must disappear here too.
        try db.execute(
            sql: "DELETE FROM channel_member WHERE channel_id = ?",
            arguments: [channelID]
        )

        for tag in event.tags where tag.first == "p" && tag.count > 1 {
            try db.execute(
                sql: """
                    INSERT INTO channel_member (channel_id, pubkey, role) VALUES (?, ?, ?)
                    ON CONFLICT(channel_id, pubkey) DO UPDATE SET role = excluded.role
                    """,
                arguments: [channelID, tag[1], tag.count > 2 ? tag[2] : nil]
            )
        }
    }

    // MARK: - Profiles

    /// Kind 0, replaceable per pubkey.
    private static func projectProfile(_ event: NostrEvent, into db: Database) throws {
        let meta = try? JSONDecoder().decode(ProfileMetadata.self, from: Data(event.content.utf8))

        try db.execute(
            sql: """
                INSERT INTO profile (pubkey, display_name, picture, about, nip05, lud16, source_event_id, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(pubkey) DO UPDATE SET
                    display_name = excluded.display_name,
                    picture = excluded.picture,
                    about = excluded.about,
                    nip05 = excluded.nip05,
                    lud16 = excluded.lud16,
                    source_event_id = excluded.source_event_id,
                    created_at = excluded.created_at
                WHERE excluded.created_at > profile.created_at
                """,
            arguments: [
                event.pubkey,
                // `display_name` is the newer field; `name` is what older clients
                // and most relays actually populate.
                meta?.displayName?.nilIfEmpty ?? meta?.name?.nilIfEmpty,
                meta?.picture?.nilIfEmpty,
                meta?.about?.nilIfEmpty,
                meta?.nip05?.nilIfEmpty,
                meta?.lud16?.nilIfEmpty,
                event.id,
                event.createdAt,
            ]
        )
    }

    // MARK: - Reactions

    private static func projectReaction(_ event: NostrEvent, into db: Database) throws {
        // NIP-25: the target is the last `e` tag, and empty or "+" content means
        // a like, which clients render as a heart.
        guard let target = event.referencedEventIDs.last else { return }
        let emoji = event.content.isEmpty || event.content == "+" ? "❤️" : event.content

        // NIP-30: a reaction whose content is `:shortcode:` is an image the
        // same event defines. Resolved now, while the tags are still in hand:
        // the tally groups reactions by their content, so by the time anything
        // reads this row the event that named the image is out of reach.
        let emojiURL = CustomEmoji.entries(in: event.tags).first {
            emoji == ":\($0.shortcode):"
        }?.url

        try db.execute(
            sql: """
                INSERT INTO reaction (event_id, target_id, pubkey, emoji, emoji_url, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(event_id) DO NOTHING
                """,
            arguments: [event.id, target, event.pubkey, emoji, emojiURL, event.createdAt]
        )
    }

    // MARK: - Zaps

    /// Records what a zap receipt says about itself.
    ///
    /// Only the offline half of the check runs here. `decodeReceipt` verifies
    /// the embedded kind 9734's signature, which is what makes the amount,
    /// sender and target unforgeable, and that answer never changes. Whether
    /// the receipt's signer was entitled to issue it needs the recipient's
    /// LNURL endpoint, an HTTPS fetch, so it happens at read time instead: a
    /// projector that needed the network could not be replayed offline, and
    /// `rebuildProjections` has to produce identical rows every time.
    ///
    /// This is the first projector that runs cryptography, one secp256k1
    /// verification per receipt on every rebuild. Receipts are rare next to
    /// messages, so the cost is small, but it is not nothing.
    ///
    /// A receipt that fails to decode simply writes no row. It stays in the
    /// log, like an undecodable channel or an unauthorised deletion.
    private static func projectZap(_ event: NostrEvent, into db: Database) throws {
        guard let receipt = try? Zap.decodeReceipt(event) else { return }

        try db.execute(
            sql: """
                INSERT INTO zap (event_id, request_id, target_id, sender, recipient,
                                 issuer, amount_msats, comment, bolt11, proof, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'receipt', ?)
                -- Both conflicts are the same defence seen from two sides: the
                -- same receipt arriving twice, and a genuine receipt
                -- republished under a fresh id to be counted again.
                ON CONFLICT DO NOTHING
                """,
            arguments: [
                receipt.receiptID,
                receipt.requestID,
                receipt.targetEventID,
                receipt.sender.hex,
                receipt.recipient,
                receipt.issuer,
                receipt.amountMillisats,
                receipt.comment,
                receipt.bolt11,
                event.createdAt,
            ]
        )
    }

    /// Records a zap the payer proved, into the same table a receipt lands in.
    ///
    /// One tally, two sources. A message does not care which way its sats were
    /// evidenced, and keeping them apart would mean every read doing a union
    /// and every total being two numbers that have to be added correctly in
    /// more than one place.
    ///
    /// Unlike a receipt, this one is checked completely here. An attestation's
    /// proof is its preimage, which is settled forever and needs no network, so
    /// nothing is left for read time to ask. That is why `proof` exists as a
    /// column: a receipt's trust depends on an issuer key that may not be
    /// cached, an attestation's does not depend on anything, and a read that
    /// could not tell them apart would have to report the better-evidenced of
    /// the two as the less.
    ///
    /// `issuer` is the payer's own key, because they are who signed this claim.
    /// It is not compared against `lnurl_issuer`, and must not be: no LNURL
    /// endpoint issued this.
    ///
    /// The unique index on bolt11 is what stops a zap being counted twice when
    /// both an attestation and a real receipt arrive for the same payment. One
    /// invoice, one row, whichever gets there first.
    private static func projectAttestation(_ event: NostrEvent, into db: Database) throws {
        guard let attested = try? Zap.verifyAttestation(event) else { return }

        try db.execute(
            sql: """
                INSERT INTO zap (event_id, request_id, target_id, sender, recipient,
                                 issuer, amount_msats, comment, bolt11, proof, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'attestation', ?)
                ON CONFLICT DO NOTHING
                """,
            arguments: [
                attested.attestationID,
                attested.requestID,
                attested.targetEventID,
                attested.sender.hex,
                attested.recipient,
                attested.sender.hex,
                attested.amountMillisats,
                attested.comment,
                attested.bolt11,
                event.createdAt,
            ]
        )
    }

    // MARK: - Deletions

    /// Records a deletion without judging it. Whether it takes effect is
    /// decided at read time, where the target's author is known: a kind 5
    /// only erases its own author's events, while a kind 9005 is the relay's
    /// moderation tombstone and is honoured from anyone the relay accepted,
    /// because in NIP-29 the relay is the group's moderation authority.
    ///
    /// Without that read-time check, any member of a plain NIP-29 relay could
    /// publish a valid kind 5 naming someone else's message and blank it on
    /// every Comb screen. Hosted Buzz rejects those server-side; Comb cannot
    /// assume every relay it meets does.
    private static func projectDeletion(_ event: NostrEvent, into db: Database) throws {
        for target in event.referencedEventIDs {
            try db.execute(
                sql: """
                    INSERT INTO deletion (event_id, target_id, deleted_by, kind, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(event_id) DO NOTHING
                    """,
                arguments: [event.id, target, event.pubkey, event.kind.rawValue, event.createdAt]
            )
        }
    }

    // MARK: - Buzz extensions

    private static func projectEdit(_ event: NostrEvent, into db: Database) throws {
        guard let target = event.referencedEventIDs.last else { return }

        try db.execute(
            sql: """
                INSERT INTO edit (event_id, target_id, pubkey, content, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(event_id) DO NOTHING
                """,
            arguments: [event.id, target, event.pubkey, event.content, event.createdAt]
        )
    }

    private static func projectRichContent(_ event: NostrEvent, into db: Database) throws {
        guard let target = event.referencedEventIDs.last else { return }

        try db.execute(
            sql: """
                INSERT INTO rich_content (target_id, event_id, payload) VALUES (?, ?, ?)
                ON CONFLICT(target_id) DO UPDATE SET
                    event_id = excluded.event_id,
                    payload = excluded.payload
                """,
            arguments: [target, event.id, event.content]
        )
    }
}

// MARK: - Content shapes

/// Kind 0 content. Every field is optional: relays serve whatever a client wrote,
/// including empty strings and absent keys.
private struct ProfileMetadata: Decodable {
    let name: String?
    let displayName: String?
    let picture: String?
    let about: String?
    let nip05: String?
    let lud16: String?

    enum CodingKeys: String, CodingKey {
        case name, picture, about, nip05, lud16
        case displayName = "display_name"
    }
}

/// Kind 39000 content, when the relay sends JSON rather than tags.
private struct ChannelMetadata: Decodable {
    let name: String?
    let about: String?
    let picture: String?
}

private extension String {
    /// Treats an empty string as absent, so a profile that was cleared falls back
    /// to the abbreviated key rather than rendering as blank.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
