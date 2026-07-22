import CombCore
import Foundation
import GRDB

/// One message as the UI needs it: content already resolved through edits,
/// deletion and delivery state applied, author details joined in.
public struct TimelineRow: Sendable, Equatable, Identifiable {
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
    public let replyTo: String?
    /// Buzz kind 40002 payload, absent on relays that do not implement it. The
    /// renderer falls back to `content`.
    public let richContent: String?

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
public enum Delivery: Sendable, Equatable {
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

        let sql = """
            SELECT id, pubkey, created_at, content, edited, deleted, rich,
                   display_name, picture, tags, state, last_error
            FROM (
                SELECT e.id                AS id,
                       e.pubkey            AS pubkey,
                       e.created_at        AS created_at,
                       e.content           AS content,
                       (SELECT ed.content FROM edit ed
                         WHERE ed.target_id = e.id
                         ORDER BY ed.created_at DESC, ed.event_id DESC
                         LIMIT 1)          AS edited,
                       EXISTS(SELECT 1 FROM deletion d WHERE d.target_id = e.id) AS deleted,
                       rc.payload          AS rich,
                       p.display_name      AS display_name,
                       p.picture           AS picture,
                       e.tags              AS tags,
                       'sent'              AS state,
                       NULL                AS last_error
                FROM event e
                LEFT JOIN rich_content rc ON rc.target_id = e.id
                LEFT JOIN profile p ON p.pubkey = e.pubkey
                WHERE e.h = :channel AND e.kind = :kind AND \(page("e.created_at", "e.id"))

                UNION ALL

                SELECT o.event_id, o.pubkey, o.created_at, o.content,
                       NULL, 0, NULL,
                       p.display_name, p.picture,
                       '[]', o.state, o.last_error
                FROM outbox o
                LEFT JOIN profile p ON p.pubkey = o.pubkey
                WHERE o.channel_id = :channel AND \(page("o.created_at", "o.event_id"))
            )
            ORDER BY created_at DESC, id DESC
            LIMIT :limit
            """

        return try reader.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [
                "channel": channel,
                "kind": EventKind.groupChatMessage.rawValue,
                "hasCursor": cursor == nil ? 0 : 1,
                "ts": cursor?.createdAt ?? 0,
                "id": cursor?.id ?? "",
                "limit": limit,
            ])

            return rows.map { row in
                let edited: String? = row["edited"]
                let tagsJSON: String = row["tags"]
                let tags = (try? JSONDecoder().decode([[String]].self, from: Data(tagsJSON.utf8))) ?? []

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
                    replyTo: Self.replyTarget(in: tags),
                    richContent: row["rich"]
                )
            }
        }
    }

    /// Reaction tallies for a set of messages.
    ///
    /// Aggregated in SQL and fetched for a whole page at once. Counting in Swift
    /// per row would be an N+1 query against the timeline.
    nonisolated func reactions(
        for eventIDs: [String],
        me: String?
    ) throws -> [String: [ReactionSummary]] {
        guard !eventIDs.isEmpty else { return [:] }

        let placeholders = databaseQuestionMarks(count: eventIDs.count)
        let sql = """
            SELECT target_id, emoji, COUNT(*) AS n,
                   MAX(pubkey = ?) AS mine
            FROM reaction
            WHERE target_id IN (\(placeholders))
            GROUP BY target_id, emoji
            ORDER BY n DESC, emoji ASC
            """

        return try reader.read { db in
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
    }

    /// NIP-10 reply target: an explicit `reply` marker, else `root`.
    private static func replyTarget(in tags: [[String]]) -> String? {
        for tag in tags where tag.first == "e" && tag.count >= 4 && tag[3] == "reply" {
            return tag[1]
        }
        for tag in tags where tag.first == "e" && tag.count >= 4 && tag[3] == "root" {
            return tag[1]
        }
        return nil
    }
}
