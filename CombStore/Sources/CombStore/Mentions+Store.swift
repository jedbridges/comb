import CombCore
import Foundation
import GRDB

/// One message that named the viewer, for a background notification.
public struct MentionNotice: Sendable, Equatable, Identifiable {
    public let id: String
    public let channelID: String
    public let channelName: String
    public let author: String
    public let text: String
    public let createdAt: Int64

    public init(
        id: String,
        channelID: String,
        channelName: String,
        author: String,
        text: String,
        createdAt: Int64
    ) {
        self.id = id
        self.channelID = channelID
        self.channelName = channelName
        self.author = author
        self.text = text
        self.createdAt = createdAt
    }
}

public extension EventStore {
    /// Messages that `p`-tag the viewer and arrived after `since`.
    ///
    /// This is the query a background wake runs: it has no UI, so it asks the
    /// store directly for "what named me while I was gone." Own messages are
    /// excluded (you cannot mention yourself into a notification), and deleted
    /// ones are filtered, so a message removed before the wake never pings.
    ///
    /// `since` is a Unix timestamp, usually the last time a notification was
    /// posted for this community, so the same mention is never delivered twice.
    nonisolated func mentions(of me: String, since: Int64, limit: Int = 20) throws -> [MentionNotice] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.id, e.h,
                       COALESCE(c.name, e.h)                             AS channel_name,
                       COALESCE(p.display_name, substr(e.pubkey, 1, 8))  AS author,
                       e.content, e.created_at
                FROM event e
                JOIN event_tag t ON t.event_id = e.id AND t.name = 'p' AND t.value = :me
                LEFT JOIN channel c ON c.id = e.h
                LEFT JOIN profile p ON p.pubkey = e.pubkey
                WHERE e.kind = :kind
                  AND e.created_at > :since
                  AND e.pubkey <> :me
                  AND e.h IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM deletion d WHERE d.target_id = e.id)
                ORDER BY e.created_at ASC
                LIMIT :limit
                """, arguments: [
                    "me": me,
                    "kind": EventKind.groupChatMessage.rawValue,
                    "since": since,
                    "limit": limit,
                ])
            .map { row in
                MentionNotice(
                    id: row["id"],
                    channelID: row["h"] ?? "",
                    channelName: row["channel_name"] ?? "",
                    author: row["author"] ?? "",
                    text: MessageText.display(row["content"]),
                    createdAt: row["created_at"]
                )
            }
        }
    }
}
