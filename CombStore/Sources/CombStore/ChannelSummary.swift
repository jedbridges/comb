import CombCore
import Foundation
import GRDB

/// One row of the channel list: metadata joined with activity.
public struct ChannelSummary: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let about: String?
    public let picture: String?
    public let memberCount: Int
    public let lastMessage: String?
    public let lastAuthor: String?
    /// Unix seconds of the newest message, nil for a silent channel.
    public let lastActivity: Int64?
    /// Messages newer than the last time this channel was read, excluding your
    /// own: seeing a badge for something you just sent would be nonsense.
    public let unreadCount: Int

    public var hasUnread: Bool { unreadCount > 0 }

    public var lastActivityDate: Date? {
        lastActivity.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

public extension EventStore {
    /// Every known channel, most recently active first, silent ones after.
    nonisolated func channelSummaries(me: String = "") throws -> [ChannelSummary] {
        try reader.read { db in try Self.fetchChannelSummaries(db, me: me) }
    }

    static func fetchChannelSummaries(_ db: Database, me: String = "") throws -> [ChannelSummary] {
        // Correlated subqueries rather than joins: the channel count is small
        // (tens), and this keeps "latest message" unambiguous.
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.id, c.name, c.about, c.picture,
                   (SELECT COUNT(*) FROM channel_member m
                     WHERE m.channel_id = c.id)                       AS members,
                   (SELECT e.content FROM event e
                     WHERE e.h = c.id AND e.kind = :kind
                       AND NOT EXISTS (SELECT 1 FROM deletion d WHERE d.target_id = e.id)
                     ORDER BY e.created_at DESC, e.id DESC LIMIT 1)   AS last_message,
                   (SELECT p.display_name FROM event e
                     LEFT JOIN profile p ON p.pubkey = e.pubkey
                     WHERE e.h = c.id AND e.kind = :kind
                     ORDER BY e.created_at DESC, e.id DESC LIMIT 1)   AS last_author,
                   (SELECT e.created_at FROM event e
                     WHERE e.h = c.id AND e.kind = :kind
                     ORDER BY e.created_at DESC, e.id DESC LIMIT 1)   AS last_at,
                   (SELECT COUNT(*) FROM event e
                     WHERE e.h = c.id AND e.kind = :kind
                       AND e.pubkey != :me
                       AND e.created_at > COALESCE(
                             (SELECT r.last_read_at FROM read_state r
                               WHERE r.channel_id = c.id), 0)
                       AND NOT EXISTS (SELECT 1 FROM deletion d WHERE d.target_id = e.id)
                   )                                                  AS unread
            FROM channel c
            ORDER BY last_at IS NULL, last_at DESC, c.name COLLATE NOCASE ASC
            """, arguments: [
                "kind": EventKind.groupChatMessage.rawValue,
                "me": me,
            ])

        return rows.map { row in
            ChannelSummary(
                id: row["id"],
                name: row["name"] ?? row["id"],
                about: row["about"],
                picture: row["picture"],
                memberCount: row["members"],
                lastMessage: row["last_message"],
                lastAuthor: row["last_author"],
                lastActivity: row["last_at"],
                unreadCount: row["unread"] ?? 0
            )
        }
    }
}

/// A page of timeline rows with their reaction tallies, fetched atomically so
/// the two can never describe different moments.
public struct TimelineSnapshot: Sendable, Equatable {
    public let rows: [TimelineRow]
    public let reactions: [String: [ReactionSummary]]

    public static let empty = TimelineSnapshot(rows: [], reactions: [:])
}

public extension EventStore {
    /// The newest event timestamp in the log, which is where a live
    /// subscription resumes from.
    nonisolated func newestEventTimestamp() throws -> Int64? {
        try reader.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(created_at) FROM event")
        }
    }

    /// Emits a fresh snapshot whenever anything the query touches changes.
    ///
    /// This is the only bridge between storage and the UI: GRDB re-runs the
    /// tracking closure when any table it read from changes, so an insert into
    /// `event`, `outbox`, `reaction`, `deletion`, `edit`, or `profile` all
    /// surface as one new value. The view layer never polls and never watches
    /// the socket.
    nonisolated func observeTimeline(
        channel: String,
        limit: Int,
        me: String?
    ) -> AsyncValueObservation<TimelineSnapshot> {
        ValueObservation
            .tracking { db -> TimelineSnapshot in
                let rows = try Self.fetchTimeline(db, channel: channel, before: nil, limit: limit)
                let reactions = try Self.fetchReactions(db, for: rows.map(\.id), me: me)
                return TimelineSnapshot(rows: rows, reactions: reactions)
            }
            .removeDuplicates()
            .values(in: reader)
    }

    /// Emits the channel list whenever channels, members, messages, profiles,
    /// or read state change.
    nonisolated func observeChannelSummaries(me: String = "") -> AsyncValueObservation<[ChannelSummary]> {
        ValueObservation
            .tracking { db in try Self.fetchChannelSummaries(db, me: me) }
            .removeDuplicates()
            .values(in: reader)
    }

    /// Marks a channel read up to its newest message.
    ///
    /// Recorded as a timestamp rather than a set of ids, so a channel that
    /// receives a hundred messages while you are away still costs one row, and
    /// history arriving later cannot retroactively mark itself unread.
    func markRead(channel: String) throws {
        try writer.write { db in
            let newest = try Int64.fetchOne(db, sql: """
                SELECT MAX(created_at) FROM event WHERE h = ? AND kind = ?
                """, arguments: [channel, EventKind.groupChatMessage.rawValue])

            try db.execute(sql: """
                INSERT INTO read_state (channel_id, last_read_at) VALUES (?, ?)
                ON CONFLICT(channel_id) DO UPDATE SET
                    last_read_at = MAX(read_state.last_read_at, excluded.last_read_at)
                """, arguments: [channel, newest ?? 0])
        }
    }

    /// Total unread across every channel, for a badge.
    nonisolated func totalUnread(me: String = "") throws -> Int {
        try reader.read { db in
            try Self.fetchChannelSummaries(db, me: me).reduce(0) { $0 + $1.unreadCount }
        }
    }
}
