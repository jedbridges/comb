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
        case .deletion, .groupDeleteEvent:
            try projectDeletion(event, into: db)
        case .buzzEdit:
            try projectEdit(event, into: db)
        case .buzzRichContent:
            try projectRichContent(event, into: db)
        case .groupChatMessage:
            try projectThread(event, into: db)
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
                INSERT INTO channel (id, name, about, picture, is_private, source_event_id, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    about = excluded.about,
                    picture = excluded.picture,
                    is_private = excluded.is_private,
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
                event.id,
                event.createdAt,
            ]
        )
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

        try db.execute(
            sql: """
                INSERT INTO reaction (event_id, target_id, pubkey, emoji, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(event_id) DO NOTHING
                """,
            arguments: [event.id, target, event.pubkey, emoji, event.createdAt]
        )
    }

    // MARK: - Deletions

    /// Kind 5 (self-deletion) and kind 9005 (moderator deletion).
    ///
    /// Authority is not checked here. The relay decides whether a deletion is
    /// permitted; a client that enforced its own rules would disagree with what
    /// other members see.
    private static func projectDeletion(_ event: NostrEvent, into db: Database) throws {
        for target in event.referencedEventIDs {
            try db.execute(
                sql: """
                    INSERT INTO deletion (event_id, target_id, deleted_by, created_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(event_id) DO NOTHING
                    """,
                arguments: [event.id, target, event.pubkey, event.createdAt]
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
