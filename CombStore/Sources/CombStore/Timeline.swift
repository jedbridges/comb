import CombCore
import Foundation
import GRDB

/// One message as the UI needs it: content already resolved through edits,
/// deletion and delivery state applied, author details joined in.
public struct TimelineRow: Sendable, Hashable, Identifiable {
    public let id: String
    public let pubkey: String
    public let createdAt: Int64
    /// The current text, which is the newest edit's content when one exists.
    public let content: String
    public let isEdited: Bool
    public let isDeleted: Bool
    public let delivery: Delivery
    public let authorName: String?
    public let authorPicture: String?
    /// The author's Lightning address (lud16), when their profile carries one.
    /// Present is what makes zapping this message possible.
    public let authorLightningAddress: String?
    /// The message this one replies to directly, when it is a reply.
    public let parentID: String?
    /// The message that opened this reply's thread.
    public let rootID: String?
    /// How many replies hang off this message, when it opens a thread.
    public let replyCount: Int
    /// When the newest reply landed, for "last reply 5m ago".
    public let lastReplyAt: Int64?
    /// Buzz kind 40002 payload, absent on relays that do not implement it. The
    /// renderer falls back to `content`.
    public let richContent: String?
    /// Images and video hanging off this message, from its NIP-92 `imeta` tags.
    public let attachments: [Blossom.Attachment]
    /// Pubkeys this message mentions via `p` tags. Comparing against the
    /// viewer is what lets a message that names you carry extra weight.
    public let mentionedPubkeys: [String]

    public func mentions(_ pubkey: String) -> Bool {
        mentionedPubkeys.contains { $0.caseInsensitiveCompare(pubkey) == .orderedSame }
    }

    /// The body as a person should read it.
    ///
    /// Buzz appends `![image](url)` to the text for every attachment as a
    /// fallback for clients that cannot read NIP-92. Comb renders the
    /// attachment itself, so showing the markdown too would put a wall of
    /// relay URL in the middle of the conversation.
    public var displayContent: String { MessageText.withoutMediaMarkdown(content) }

    /// Whether this message opens a thread worth offering a way into.
    public var hasThread: Bool { replyCount > 0 }
    public var isReply: Bool { parentID != nil }

    public var lastReplyDate: Date? {
        lastReplyAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }

    /// A display name, falling back to a short form of the key.
    ///
    /// Deliberately not the raw npub: a first-time user should never have to
    /// reason about keys, and a truncated hex string reads as an identifier
    /// rather than as something they are supposed to understand.
    public var displayName: String {
        if let authorName, !authorName.isEmpty { return authorName }
        return String(pubkey.prefix(8))
    }
}

/// Where a message is in its journey to the relay.
public enum Delivery: Sendable, Hashable {
    /// Written to the log, which means the relay accepted it.
    case sent
    /// Signed and queued, waiting on the relay's OK.
    case pending
    /// The relay rejected it, or the send failed. Carries the reason when there
    /// is one worth showing.
    case failed(String?)

    init(state: String, lastError: String?) {
        switch state {
        case OutboxState.pending.rawValue, OutboxState.sending.rawValue: self = .pending
        case OutboxState.failed.rawValue: self = .failed(lastError)
        default: self = .sent
        }
    }
}

/// A position in a channel's history.
///
/// Ordering is `(created_at, id)` rather than `created_at` alone. Relays hand
/// out many events in the same second, and a timestamp-only cursor either skips
/// or repeats them depending on which side of the boundary they land.
public struct TimelineCursor: Sendable, Equatable {
    public let createdAt: Int64
    public let id: String

    public init(createdAt: Int64, id: String) {
        self.createdAt = createdAt
        self.id = id
    }

    public init(row: TimelineRow) {
        self.init(createdAt: row.createdAt, id: row.id)
    }
}

/// A reaction tally for one message.
public struct ReactionSummary: Sendable, Equatable, Identifiable {
    public let emoji: String
    public let count: Int
    /// Whether the current user is among the reactors, which drives the
    /// highlighted state and makes the tap a toggle.
    public let includesMe: Bool

    public var id: String { emoji }
}

public extension EventStore {
    /// A page of a channel's history, newest first.
    ///
    /// Event rows and outbox rows are unioned in one statement so a pending
    /// message sorts into place by its own timestamp. Keeping them in separate
    /// lists is the usual source of optimistic-send bugs, where the two
    /// disagree about order or a message appears twice during the handover.
    nonisolated func timeline(
        channel: String,
        before cursor: TimelineCursor? = nil,
        limit: Int = 50
    ) throws -> [TimelineRow] {
        try reader.read { db in
            try Self.fetchTimeline(db, channel: channel, before: cursor, limit: limit)
        }
    }

    /// The query itself, over an open database so `ValueObservation` can track
    /// the tables it touches.
    static func fetchTimeline(
        _ db: Database,
        channel: String,
        before cursor: TimelineCursor?,
        limit: Int
    ) throws -> [TimelineRow] {
        // Columns are qualified per branch because the joined `profile` table
        // also has a `created_at`, and the two branches key on different id
        // columns. Descending id in the tiebreak so the comparison matches
        // ORDER BY.
        func page(_ timestamp: String, _ identifier: String) -> String {
            """
            (:hasCursor = 0
             OR \(timestamp) < :ts
             OR (\(timestamp) = :ts AND \(identifier) < :id))
            """
        }

        // Thread replies are excluded here and shown in their thread instead.
        // Without this every reply renders as its own top-level message and a
        // threaded conversation reads as a flat pile, which is exactly what a
        // thread is meant to prevent. Broadcast replies keep their `thread` row
        // but are deliberately let through: their author echoed them here.
        let sql = """
            SELECT \(Self.timelineColumns)
            FROM (
                \(Self.eventBranch(where: """
                    e.h = :channel AND e.kind = :kind AND \(page("e.created_at", "e.id"))
                      AND NOT EXISTS (
                            SELECT 1 FROM thread tx
                            WHERE tx.event_id = e.id AND tx.broadcast = 0
                          )
                    """))

                UNION ALL

                \(Self.outboxBranch(where: """
                    o.channel_id = :channel AND o.parent_id IS NULL
                      AND \(page("o.created_at", "o.event_id"))
                    """))
            )
            ORDER BY created_at DESC, id DESC
            LIMIT :limit
            """

        let rows = try Row.fetchAll(db, sql: sql, arguments: [
            "channel": channel,
            "kind": EventKind.groupChatMessage.rawValue,
            "hasCursor": cursor == nil ? 0 : 1,
            "ts": cursor?.createdAt ?? 0,
            "id": cursor?.id ?? "",
            "limit": limit,
        ])

        return Self.makeRows(rows)
    }

    /// A whole thread: the message that opened it, then every reply, oldest
    /// first because a thread is read forwards.
    nonisolated func thread(root: String) throws -> [TimelineRow] {
        try reader.read { db in try Self.fetchThread(db, root: root) }
    }

    static func fetchThread(_ db: Database, root: String) throws -> [TimelineRow] {
        let sql = """
            SELECT \(Self.timelineColumns)
            FROM (
                \(Self.eventBranch(where: "e.id = :root AND e.kind = :kind"))

                UNION ALL

                \(Self.eventBranch(where: """
                    e.kind = :kind AND EXISTS (
                        SELECT 1 FROM thread tr
                        WHERE tr.event_id = e.id AND tr.root_id = :root
                    )
                    """))

                UNION ALL

                \(Self.outboxBranch(where: "o.root_id = :root"))
            )
            ORDER BY created_at ASC, id ASC
            """

        let rows = try Row.fetchAll(db, sql: sql, arguments: [
            "root": root,
            "kind": EventKind.groupChatMessage.rawValue,
        ])
        return Self.makeRows(rows)
    }

    // MARK: - Shared query pieces

    /// One column list, so the branches below and their callers cannot drift.
    private static let timelineColumns = """
        id, pubkey, created_at, content, edited, deleted, rich,
        display_name, picture, lud16, parent_id, root_id,
        reply_count, last_reply_at, tags, state, last_error
        """

    /// A message from the log, with its author, edits and thread position.
    ///
    /// Ownership is enforced here, at read time, not at ingest: an edit only
    /// applies when its signer is the message's author, and a kind 5 deletion
    /// only when it names its own author's event. Kind 9005 is the relay's
    /// moderation tombstone and is honoured from anyone the relay accepted,
    /// because in NIP-29 the relay is the group's moderation authority.
    /// Hosted Buzz enforces all of this server-side; a plain NIP-29 relay may
    /// not, and without these predicates any member there could rewrite or
    /// blank anyone else's messages on every Comb screen.
    ///
    /// The reply tallies exclude deleted replies: a thread whose only reply was
    /// removed should stop advertising one.
    private static func eventBranch(where predicate: String) -> String {
        """
        SELECT e.id                AS id,
               e.pubkey            AS pubkey,
               e.created_at        AS created_at,
               e.content           AS content,
               (SELECT ed.content FROM edit ed
                 WHERE ed.target_id = e.id
                   AND ed.pubkey = e.pubkey
                 ORDER BY ed.created_at DESC, ed.event_id DESC
                 LIMIT 1)          AS edited,
               EXISTS(SELECT 1 FROM deletion d
                       WHERE d.target_id = e.id
                         AND (d.kind = 9005 OR d.deleted_by = e.pubkey)) AS deleted,
               rc.payload          AS rich,
               p.display_name      AS display_name,
               p.picture           AS picture,
               p.lud16             AS lud16,
               t.parent_id         AS parent_id,
               t.root_id           AS root_id,
               (SELECT COUNT(*) FROM thread tc
                 WHERE tc.root_id = e.id
                   AND NOT EXISTS (
                         SELECT 1 FROM deletion dc
                          WHERE dc.target_id = tc.event_id
                            AND (dc.kind = 9005 OR dc.deleted_by = tc.pubkey)
                       )) AS reply_count,
               (SELECT MAX(tl.created_at) FROM thread tl
                 WHERE tl.root_id = e.id
                   AND NOT EXISTS (
                         SELECT 1 FROM deletion dl
                          WHERE dl.target_id = tl.event_id
                            AND (dl.kind = 9005 OR dl.deleted_by = tl.pubkey)
                       )) AS last_reply_at,
               e.tags              AS tags,
               'sent'              AS state,
               NULL                AS last_error
        FROM event e
        LEFT JOIN rich_content rc ON rc.target_id = e.id
        LEFT JOIN profile p ON p.pubkey = e.pubkey
        LEFT JOIN thread t ON t.event_id = e.id
        WHERE \(predicate)
        """
    }

    /// A message we have signed but the relay has not acknowledged. It carries
    /// no reply tally: nothing can have replied to it yet.
    private static func outboxBranch(where predicate: String) -> String {
        """
        SELECT o.event_id, o.pubkey, o.created_at, o.content,
               NULL, 0, NULL,
               p.display_name, p.picture, p.lud16,
               o.parent_id, o.root_id, 0, NULL,
               o.tags, o.state, o.last_error
        FROM outbox o
        LEFT JOIN profile p ON p.pubkey = o.pubkey
        WHERE \(predicate)
        """
    }

    /// One decoder for the whole page rather than one per row: this runs on
    /// every observation fire, and allocating eighty decoders per incoming
    /// message was pure waste. Not shared wider than a fetch, because
    /// `JSONDecoder` makes no thread-safety promise and the reader pool is
    /// concurrent.
    private static func makeRows(_ rows: [Row]) -> [TimelineRow] {
        let decoder = JSONDecoder()
        return rows.map { makeRow($0, decoder: decoder) }
    }

    /// Decodes `imeta` attachments from a row's stored tag JSON.
    ///
    /// Done in Swift rather than SQL: the tags are already JSON, the page is at
    /// most a screenful, and pushing JSON parsing into SQLite would buy nothing
    /// but an unreadable query.
    private static func decodedTags(
        fromJSON json: String?,
        decoder: JSONDecoder
    ) -> [[String]] {
        guard let json,
              let tags = try? decoder.decode([[String]].self, from: Data(json.utf8))
        else { return [] }
        return tags
    }

    private static func makeRow(_ row: Row, decoder: JSONDecoder) -> TimelineRow {
        let edited: String? = row["edited"]
        // Decoded once per row and read twice: attachments and mentions both
        // come from the same tag array.
        let tags = decodedTags(fromJSON: row["tags"], decoder: decoder)
        return TimelineRow(
            id: row["id"],
            pubkey: row["pubkey"],
            createdAt: row["created_at"],
            content: edited ?? row["content"],
            isEdited: edited != nil,
            isDeleted: row["deleted"] ?? false,
            delivery: Delivery(state: row["state"], lastError: row["last_error"]),
            authorName: row["display_name"],
            authorPicture: row["picture"],
            authorLightningAddress: row["lud16"],
            parentID: row["parent_id"],
            rootID: row["root_id"],
            replyCount: row["reply_count"] ?? 0,
            lastReplyAt: row["last_reply_at"],
            richContent: row["rich"],
            attachments: Blossom.attachments(in: tags),
            mentionedPubkeys: tags.compactMap {
                $0.count >= 2 && $0[0] == "p" ? $0[1] : nil
            }
        )
    }

    /// Reaction tallies for a set of messages.
    ///
    /// Aggregated in SQL and fetched for a whole page at once. Counting in Swift
    /// per row would be an N+1 query against the timeline.
    nonisolated func reactions(
        for eventIDs: [String],
        me: String?
    ) throws -> [String: [ReactionSummary]] {
        try reader.read { db in try Self.fetchReactions(db, for: eventIDs, me: me) }
    }

    static func fetchReactions(
        _ db: Database,
        for eventIDs: [String],
        me: String?
    ) throws -> [String: [ReactionSummary]] {
        guard !eventIDs.isEmpty else { return [:] }

        let placeholders = databaseQuestionMarks(count: eventIDs.count)
        // A withdrawn reaction is a kind 5 deletion of the reaction event, so
        // the tally has to exclude deleted reactions or un-reacting would never
        // take effect visually.
        let sql = """
            SELECT target_id, emoji, COUNT(*) AS n,
                   MAX(pubkey = ?) AS mine
            FROM reaction
            WHERE target_id IN (\(placeholders))
              AND NOT EXISTS (SELECT 1 FROM deletion d
                               WHERE d.target_id = reaction.event_id
                                 AND (d.kind = 9005 OR d.deleted_by = reaction.pubkey))
            GROUP BY target_id, emoji
            ORDER BY n DESC, emoji ASC
            """

        let rows = try Row.fetchAll(
            db,
            sql: sql,
            arguments: StatementArguments([me ?? ""] + eventIDs)
        )

        var out: [String: [ReactionSummary]] = [:]
        for row in rows {
            let target: String = row["target_id"]
            out[target, default: []].append(
                ReactionSummary(
                    emoji: row["emoji"],
                    count: row["n"],
                    includesMe: row["mine"] ?? false
                )
            )
        }
        return out
    }

    /// The id of the caller's own live reaction with this emoji, for toggling:
    /// reacting again means withdrawing, which is a deletion of this event.
    nonisolated func ownReactionID(
        target: String,
        emoji: String,
        pubkey: String
    ) throws -> String? {
        try reader.read { db in
            try String.fetchOne(db, sql: """
                SELECT event_id FROM reaction
                WHERE target_id = ? AND emoji = ? AND pubkey = ?
                  AND NOT EXISTS (SELECT 1 FROM deletion d
                                   WHERE d.target_id = reaction.event_id
                                     AND (d.kind = 9005 OR d.deleted_by = reaction.pubkey))
                LIMIT 1
                """, arguments: [target, emoji, pubkey])
        }
    }

}
