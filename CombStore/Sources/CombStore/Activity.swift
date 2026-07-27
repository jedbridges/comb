import CombCore
import Foundation
import GRDB

/// One thing that happened to you: a message that named you, a reply to
/// something you wrote, or a reaction to it.
///
/// The channel list answers "where is there anything new"; this answers "what
/// of it was addressed to me". Both read the same log, and neither is a feed in
/// the algorithmic sense: the order is the order it happened.
public struct ActivityItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case mention, reply, reaction
    }

    /// The event that caused this: the reply, the mention, or the reaction.
    public let id: String
    public let kind: Kind
    public let channelID: String
    public let channelName: String
    public let actorPubkey: String
    public let actorName: String
    public let actorPicture: String?
    /// The message being opened when this row is tapped. For a mention that is
    /// the message itself; for a reply or a reaction it is the message of yours
    /// that was answered.
    public let targetID: String
    /// The reply or mention text, or the reaction's emoji.
    public let text: String
    /// Set when `text` is a NIP-30 shortcode rather than a Unicode emoji.
    public let emojiURL: String?
    public let createdAt: Int64

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
}

public extension EventStore {
    /// Everything addressed to you across every channel, newest first.
    nonisolated func activity(for me: String, limit: Int = 100) throws -> [ActivityItem] {
        try reader.read { db in try Self.fetchActivity(db, me: me, limit: limit) }
    }

    /// Emits the same list whenever a message, reply, reaction, or profile
    /// changes anything in it.
    nonisolated func observeActivity(
        for me: String,
        limit: Int = 100
    ) -> AsyncValueObservation<[ActivityItem]> {
        ValueObservation
            .tracking { db in try Self.fetchActivity(db, me: me, limit: limit) }
            .removeDuplicates()
            .values(in: reader)
    }

    static func fetchActivity(
        _ db: Database,
        me: String,
        limit: Int
    ) throws -> [ActivityItem] {
        guard !me.isEmpty else { return [] }

        // Three sources unioned, then named once on the outside. Joining the
        // channel and the profile in each branch would repeat the same two
        // joins three times for no difference in the answer.
        let sql = """
            SELECT a.kind, a.id, a.target_id, a.channel_id, a.actor,
                   a.text, a.emoji_url, a.created_at,
                   COALESCE(c.name, a.channel_id)  AS channel_name,
                   p.display_name                  AS actor_name,
                   p.picture                       AS actor_picture
            FROM (
                \(mentionBranch)
                UNION ALL
                \(replyBranch)
                UNION ALL
                \(reactionBranch)
            ) a
            LEFT JOIN channel c ON c.id = a.channel_id
            LEFT JOIN profile p ON p.pubkey = a.actor
            -- A channel this account has left keeps its history in the log but
            -- has no business putting rows in front of you.
            WHERE NOT EXISTS (
                SELECT 1 FROM channel_departure d WHERE d.channel_id = a.channel_id
            )
            ORDER BY a.created_at DESC, a.id DESC
            LIMIT :limit
            """

        return try Row.fetchAll(db, sql: sql, arguments: [
            "me": me,
            "kind": EventKind.groupChatMessage.rawValue,
            "limit": limit,
        ])
        .compactMap { row in
            guard let kind = ActivityItem.Kind(rawValue: row["kind"]) else { return nil }
            let actor: String = row["actor"]
            return ActivityItem(
                id: row["id"],
                kind: kind,
                channelID: row["channel_id"] ?? "",
                channelName: row["channel_name"] ?? "",
                actorPubkey: actor,
                // Same fallback the timeline uses, so one person is called the
                // same thing on both screens.
                actorName: (row["actor_name"] as String?).flatMap { $0.isEmpty ? nil : $0 }
                    ?? String(actor.prefix(8)),
                actorPicture: row["actor_picture"],
                targetID: row["target_id"] ?? "",
                // Reactions carry an emoji, not prose, and running it through
                // the message pipeline would strip a bare `*` as emphasis.
                text: kind == .reaction
                    ? (row["text"] ?? "")
                    : MessageText.display(row["text"] ?? ""),
                emojiURL: row["emoji_url"],
                createdAt: row["created_at"]
            )
        }
    }

    /// Messages that name you, excluding the ones that are already replies to
    /// something you wrote.
    ///
    /// A Nostr reply conventionally `p`-tags the author it answers, so without
    /// that exclusion almost every reply would also arrive as a mention and the
    /// list would show each one twice. The reply branch is the more specific
    /// description of the same event, so it is the one that survives.
    private static var mentionBranch: String {
        """
        SELECT 'mention' AS kind, e.id AS id, e.id AS target_id,
               e.h AS channel_id, e.pubkey AS actor, e.content AS text,
               NULL AS emoji_url, e.created_at AS created_at
        FROM event e
        JOIN event_tag t ON t.event_id = e.id AND t.name = 'p' AND t.value = :me
        WHERE e.kind = :kind
          AND e.pubkey <> :me
          AND e.h IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM thread th
              JOIN event pe ON pe.id = th.parent_id
              WHERE th.event_id = e.id AND pe.pubkey = :me
          )
          AND \(undeleted("e"))
          AND \(notBlocked("e.pubkey"))
        """
    }

    /// Replies to your messages.
    private static var replyBranch: String {
        """
        SELECT 'reply' AS kind, e.id AS id, th.parent_id AS target_id,
               e.h AS channel_id, e.pubkey AS actor, e.content AS text,
               NULL AS emoji_url, e.created_at AS created_at
        FROM thread th
        JOIN event e ON e.id = th.event_id
        JOIN event parent ON parent.id = th.parent_id
        WHERE parent.pubkey = :me
          AND e.pubkey <> :me
          AND e.kind = :kind
          AND e.h IS NOT NULL
          AND \(undeleted("e"))
          AND \(notBlocked("e.pubkey"))
        """
    }

    /// Reactions to your messages.
    ///
    /// The reaction's own deletion is what matters here, not the target's: a
    /// withdrawn reaction should leave, and a reaction to a message you later
    /// deleted is still something that happened to you.
    private static var reactionBranch: String {
        """
        SELECT 'reaction' AS kind, r.event_id AS id, r.target_id AS target_id,
               target.h AS channel_id, r.pubkey AS actor, r.emoji AS text,
               r.emoji_url AS emoji_url, r.created_at AS created_at
        FROM reaction r
        JOIN event target ON target.id = r.target_id
        WHERE target.pubkey = :me
          AND r.pubkey <> :me
          AND target.h IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM deletion d
              WHERE d.target_id = r.event_id
                AND (d.kind = 9005 OR d.deleted_by = r.pubkey)
          )
          AND \(notBlocked("r.pubkey"))
        """
    }

    /// The read-time deletion rule, as the rest of the store applies it: a
    /// kind 5 only erases its own author's work, a kind 9005 is the relay's
    /// tombstone and is honoured from anyone.
    private static func undeleted(_ alias: String) -> String {
        """
        NOT EXISTS (
            SELECT 1 FROM deletion d
            WHERE d.target_id = \(alias).id
              AND (d.kind = 9005 OR d.deleted_by = \(alias).pubkey)
        )
        """
    }
}
