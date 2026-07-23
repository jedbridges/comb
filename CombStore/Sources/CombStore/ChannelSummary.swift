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
                       AND NOT EXISTS (SELECT 1 FROM deletion d
                                        WHERE d.target_id = e.id
                                          AND (d.kind = 9005 OR d.deleted_by = e.pubkey))
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
                       AND NOT EXISTS (SELECT 1 FROM deletion d
                                        WHERE d.target_id = e.id
                                          AND (d.kind = 9005 OR d.deleted_by = e.pubkey))
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
                // Stripped here too: a channel whose newest message is a
                // picture would otherwise preview as a relay URL.
                lastMessage: (row["last_message"] as String?)
                    .map(MessageText.withoutMediaMarkdown),
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

    /// Emits a thread whenever it, or anything it renders, changes.
    nonisolated func observeThread(
        root: String,
        me: String?
    ) -> AsyncValueObservation<TimelineSnapshot> {
        ValueObservation
            .tracking { db -> TimelineSnapshot in
                let rows = try Self.fetchThread(db, root: root)
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


/// A member's profile, as the app displays it.
public struct ProfileSummary: Sendable, Equatable, Identifiable {
    public let pubkey: String
    public let displayName: String?
    public let about: String?
    public let picture: String?
    public let nip05: String?
    public let lightningAddress: String?
    /// How many messages of theirs the local log holds. A rough sense of how
    /// present someone is, without asking the relay anything.
    public let messageCount: Int

    public var id: String { pubkey }

    /// Never the raw npub: a name or a short key, same rule as the timeline.
    public var name: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return String(pubkey.prefix(8))
    }

    public var canReceiveZaps: Bool {
        lightningAddress?.isEmpty == false
    }
}

/// One search hit, with enough context to render a result row.
public struct SearchResult: Sendable, Equatable, Identifiable {
    public let id: String
    public let channelID: String
    public let channelName: String
    public let author: String
    public let content: String
    public let createdAt: Int64

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
}

public extension EventStore {
    /// A member's profile, joined with how much they have said here.
    nonisolated func profile(pubkey: String) throws -> ProfileSummary? {
        try reader.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT p.pubkey, p.display_name, p.about, p.picture, p.nip05, p.lud16,
                       (SELECT COUNT(*) FROM event e
                         WHERE e.pubkey = :pubkey AND e.kind = :kind) AS messages
                FROM profile p WHERE p.pubkey = :pubkey
                """, arguments: [
                    "pubkey": pubkey,
                    "kind": EventKind.groupChatMessage.rawValue,
                ])

            // Someone can be present without a profile event; show what we know
            // rather than nothing.
            guard let row else {
                let messages = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM event WHERE pubkey = ? AND kind = ?
                    """, arguments: [pubkey, EventKind.groupChatMessage.rawValue]) ?? 0
                guard messages > 0 else { return nil }
                return ProfileSummary(
                    pubkey: pubkey, displayName: nil, about: nil, picture: nil,
                    nip05: nil, lightningAddress: nil, messageCount: messages
                )
            }

            return ProfileSummary(
                pubkey: row["pubkey"],
                displayName: row["display_name"],
                about: row["about"],
                picture: row["picture"],
                nip05: row["nip05"],
                lightningAddress: row["lud16"],
                messageCount: row["messages"] ?? 0
            )
        }
    }

    /// The roster of a channel, most talkative first.
    nonisolated func members(of channel: String) throws -> [ProfileSummary] {
        let pubkeys: [String] = try reader.read { db in
            try String.fetchAll(db, sql: """
                SELECT pubkey FROM channel_member WHERE channel_id = ?
                """, arguments: [channel])
        }
        return try pubkeys
            .compactMap { try profile(pubkey: $0) }
            .sorted { $0.messageCount > $1.messageCount }
    }

    /// Searches message text already on this device.
    ///
    /// Local-first on purpose: it answers instantly, works offline, and covers
    /// what the person has actually seen. Relay-side NIP-50 can widen it later
    /// without changing this path.
    nonisolated func search(_ query: String, limit: Int = 50) throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        return try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.id, e.h, e.content, e.created_at,
                       COALESCE(c.name, e.h)          AS channel_name,
                       COALESCE(p.display_name, substr(e.pubkey, 1, 8)) AS author
                FROM event e
                LEFT JOIN channel c ON c.id = e.h
                LEFT JOIN profile p ON p.pubkey = e.pubkey
                WHERE e.kind = :kind
                  AND e.content LIKE :needle ESCAPE '\\'
                  AND NOT EXISTS (SELECT 1 FROM deletion d WHERE d.target_id = e.id)
                ORDER BY e.created_at DESC
                LIMIT :limit
                """, arguments: [
                    "kind": EventKind.groupChatMessage.rawValue,
                    // Escaped so a query containing % or _ is treated literally
                    // rather than as a wildcard.
                    "needle": "%" + trimmed
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "%", with: "\\%")
                        .replacingOccurrences(of: "_", with: "\\_") + "%",
                    "limit": limit,
                ]).map { row in
                    SearchResult(
                        id: row["id"],
                        channelID: row["h"] ?? "",
                        channelName: row["channel_name"] ?? "",
                        author: row["author"] ?? "",
                        content: MessageText.withoutMediaMarkdown(row["content"]),
                        createdAt: row["created_at"]
                    )
                }
        }
    }
}
