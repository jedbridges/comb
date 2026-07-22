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

    public var lastActivityDate: Date? {
        lastActivity.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

public extension EventStore {
    /// Every known channel, most recently active first, silent ones after.
    nonisolated func channelSummaries() throws -> [ChannelSummary] {
        try reader.read { db in try Self.fetchChannelSummaries(db) }
    }

    static func fetchChannelSummaries(_ db: Database) throws -> [ChannelSummary] {
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
                     ORDER BY e.created_at DESC, e.id DESC LIMIT 1)   AS last_at
            FROM channel c
            ORDER BY last_at IS NULL, last_at DESC, c.name COLLATE NOCASE ASC
            """, arguments: ["kind": EventKind.groupChatMessage.rawValue])

        return rows.map { row in
            ChannelSummary(
                id: row["id"],
                name: row["name"] ?? row["id"],
                about: row["about"],
                picture: row["picture"],
                memberCount: row["members"],
                lastMessage: row["last_message"],
                lastAuthor: row["last_author"],
                lastActivity: row["last_at"]
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

    /// Emits the channel list whenever channels, members, messages, or
    /// profiles change.
    nonisolated func observeChannelSummaries() -> AsyncValueObservation<[ChannelSummary]> {
        ValueObservation
            .tracking { db in try Self.fetchChannelSummaries(db) }
            .removeDuplicates()
            .values(in: reader)
    }
}
