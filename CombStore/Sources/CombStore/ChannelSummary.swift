import CombCore
import Foundation
import GRDB

/// What someone is allowed to do in a channel, as the relay reports it.
///
/// NIP-29 puts the role in a roster entry's fourth element and says nothing
/// about which values exist, so a relay may send a role Comb has never heard of,
/// or none at all. Both are `unknown`, and `unknown` is not `member`: one is a
/// relay declining to say, the other is an answer. Flattening them would mean
/// hiding an action from someone who may well be an owner.
public enum ChannelRole: String, Sendable, Equatable, Hashable {
    case owner
    case admin
    case member
    case guest
    case bot

    /// Parsed leniently, because the set is the relay's to extend.
    public init?(stored: String?) {
        guard let stored, let role = ChannelRole(rawValue: stored) else { return nil }
        self = role
    }

    /// Whether this role may do the things NIP-29 gates on owner or admin.
    /// Advisory only: the relay decides, and this is a guess made from a roster
    /// that arrives on a historical query and may be minutes old.
    public var isElevated: Bool { self == .owner || self == .admin }
}

/// One row of the channel list: metadata joined with activity.
public struct ChannelSummary: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let about: String?
    public let picture: String?
    public let memberCount: Int
    /// A conversation with people rather than a room. Buzz marks these with a
    /// bare `hidden` tag on the group metadata event.
    public let isDirectMessage: Bool
    public let lastMessage: String?
    public let lastAuthor: String?
    /// Unix seconds of the newest message, nil for a silent channel.
    public let lastActivity: Int64?
    /// Messages newer than the last time this channel was read, excluding your
    /// own: seeing a badge for something you just sent would be nonsense.
    public let unreadCount: Int
    /// How many of the unread ones name you by a `p` tag. Always at most
    /// `unreadCount`, and counted over the same window.
    ///
    /// A mention is already what wakes a notification, so a channel list that
    /// weighed it the same as any other message was disagreeing with the app's
    /// own idea of what matters.
    public let mentionCount: Int
    /// Whether this account is on the channel's roster.
    ///
    /// The relay sends group metadata for open channels to people who are not
    /// in them, which is what makes joining possible at all: without it there
    /// would be nothing to list and nothing to tap. It also means the channel
    /// list has always held rooms this account cannot post in, with nothing
    /// saying so.
    public let isMember: Bool
    /// This account's role here, or nil when the relay publishes no roles.
    ///
    /// Advisory. Roles arrive only on a historical query, so this is a snapshot,
    /// and the relay is the only thing that actually enforces anything. Use it
    /// to avoid offering what is certain to be refused, never as permission.
    public let myRole: ChannelRole?
    /// Whether the channel is invite only. Joining a private channel is refused
    /// at the relay, so offering the button would be offering a rejection.
    public let isPrivate: Bool

    public var hasUnread: Bool { unreadCount > 0 }
    public var hasMention: Bool { mentionCount > 0 }

    public var lastActivityDate: Date? {
        lastActivity.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

public extension EventStore {
    /// Every known channel, most recently active first, silent ones after.
    nonisolated func channelSummaries(me: String = "") throws -> [ChannelSummary] {
        try reader.read { db in try Self.fetchChannelSummaries(db, me: me) }
    }

    /// Display names of everyone in each of the given channels except the
    /// viewer, ordered so a conversation is named the same way every time.
    ///
    /// Sorted by pubkey rather than by name: a display name can change the
    /// moment someone edits their profile, and a DM that silently reorders its
    /// own title is worse than one ordered by something meaningless but stable.
    static func fetchDirectMessageParticipants(
        _ db: Database,
        channels: [String],
        me: String
    ) throws -> [String: [String]] {
        guard !channels.isEmpty else { return [:] }

        let placeholders = databaseQuestionMarks(count: channels.count)
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.channel_id, m.pubkey, p.display_name
            FROM channel_member m
            LEFT JOIN profile p ON p.pubkey = m.pubkey
            WHERE m.channel_id IN (\(placeholders)) AND m.pubkey != ?
            ORDER BY m.channel_id, m.pubkey
            """, arguments: StatementArguments(channels + [me]))

        return rows.reduce(into: [String: [String]]()) { result, row in
            // Not the usual `pubkey.prefix(8)` fallback. That is tolerable on a
            // profile sheet, where someone has gone looking; as the title of a
            // row on the first screen of the app it puts a raw key in front of
            // a reader who was promised they would never see one.
            let name = (row["display_name"] as String?).flatMap { $0.isEmpty ? nil : $0 }
            result[row["channel_id"], default: []].append(name ?? "Someone new")
        }
    }

    static func fetchChannelSummaries(_ db: Database, me: String = "") throws -> [ChannelSummary] {
        // Correlated subqueries rather than joins: the channel count is small
        // (tens), and this keeps "latest message" unambiguous.
        let rows = try Row.fetchAll(db, sql: """
            SELECT c.id, c.name, c.about, c.picture, c.is_dm, c.is_private,
                   (SELECT COUNT(*) FROM channel_member m
                     WHERE m.channel_id = c.id)                       AS members,
                   (SELECT e.content FROM event e
                     WHERE e.h = c.id AND e.kind = :kind
                       AND NOT EXISTS (SELECT 1 FROM blocked b WHERE b.pubkey = e.pubkey)
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
                       AND NOT EXISTS (SELECT 1 FROM blocked b WHERE b.pubkey = e.pubkey)
                       AND NOT EXISTS (SELECT 1 FROM deletion d
                                        WHERE d.target_id = e.id
                                          AND (d.kind = 9005 OR d.deleted_by = e.pubkey))
                   )                                                  AS unread,
                   -- The same count again, narrowed to messages that name you.
                   -- A separate subquery rather than a second pass over the
                   -- unread rows, because `unread` is a COUNT and there are no
                   -- rows left to filter by the time it has one.
                   (SELECT COUNT(*) FROM event e
                     JOIN event_tag t ON t.event_id = e.id
                                     AND t.name = 'p' AND t.value = :me
                     WHERE e.h = c.id AND e.kind = :kind
                       AND e.pubkey != :me
                       AND e.created_at > COALESCE(
                             (SELECT r.last_read_at FROM read_state r
                               WHERE r.channel_id = c.id), 0)
                       AND NOT EXISTS (SELECT 1 FROM blocked b WHERE b.pubkey = e.pubkey)
                       AND NOT EXISTS (SELECT 1 FROM deletion d
                                        WHERE d.target_id = e.id
                                          AND (d.kind = 9005 OR d.deleted_by = e.pubkey))
                   )                                                  AS mentions,
                   EXISTS(SELECT 1 FROM channel_member m
                           WHERE m.channel_id = c.id AND m.pubkey = :me) AS is_member,
                   (SELECT m.role FROM channel_member m
                     WHERE m.channel_id = c.id AND m.pubkey = :me)        AS my_role
            FROM channel c
            -- A channel this account was removed from. The metadata and the
            -- messages stay in the log, because the log is append-only and they
            -- really did happen, but a room you are no longer in has no
            -- business sitting in the list waiting to be tapped.
            WHERE NOT EXISTS (
                SELECT 1 FROM channel_departure d WHERE d.channel_id = c.id
            )
            ORDER BY last_at IS NULL, last_at DESC, c.name COLLATE NOCASE ASC
            """, arguments: [
                "kind": EventKind.groupChatMessage.rawValue,
                "me": me,
            ])

        // Rosters for the DM rows only, in one query rather than one per row.
        // A channel list is tens of rows and most communities have no DMs at
        // all, so this usually fetches nothing.
        let dmIDs = rows.compactMap { ($0["is_dm"] as Bool) ? ($0["id"] as String) : nil }
        let participants = try fetchDirectMessageParticipants(db, channels: dmIDs, me: me)

        return rows.map { row in
            let id: String = row["id"]
            return ChannelSummary(
                id: id,
                name: DirectMessageName.resolve(
                    name: row["name"],
                    isDirectMessage: row["is_dm"],
                    participants: participants[id] ?? [],
                    fallback: id
                ),
                about: row["about"],
                picture: row["picture"],
                memberCount: row["members"],
                isDirectMessage: row["is_dm"],
                // Stripped here too: a channel whose newest message is a
                // picture would otherwise preview as a relay URL.
                lastMessage: (row["last_message"] as String?)
                    .map(MessageText.display),
                lastAuthor: row["last_author"],
                lastActivity: row["last_at"],
                unreadCount: row["unread"] ?? 0,
                mentionCount: row["mentions"] ?? 0,
                isMember: row["is_member"] ?? false,
                myRole: ChannelRole(stored: row["my_role"]),
                isPrivate: row["is_private"] ?? false
            )
        }
    }
}

/// A page of timeline rows with their reaction and zap tallies, fetched
/// atomically so they can never describe different moments.
public struct TimelineSnapshot: Sendable, Equatable {
    public let rows: [TimelineRow]
    public let reactions: [String: [ReactionSummary]]
    public let zaps: [String: ZapSummary]
    /// The reader's own zaps still waiting on a receipt, keyed by the message
    /// they were sent to. Separate from `zaps` on purpose: these are claims
    /// about a payment Comb cannot observe, so they are never added to a total.
    public let pendingZaps: [String: ZapAttempt]
    /// Whether this account is on the channel's roster, as of this snapshot.
    ///
    /// Nil where the question does not apply, which is a thread: a thread is
    /// only reachable from inside its channel, so the screen above it already
    /// answered. Deliberately not defaulted to true. A screen that assumed
    /// membership it had not been told about is the same mistake as a role
    /// defaulting to member.
    public let isMember: Bool?

    public init(
        rows: [TimelineRow],
        reactions: [String: [ReactionSummary]],
        zaps: [String: ZapSummary] = [:],
        pendingZaps: [String: ZapAttempt] = [:],
        isMember: Bool? = nil
    ) {
        self.rows = rows
        self.reactions = reactions
        self.zaps = zaps
        self.pendingZaps = pendingZaps
        self.isMember = isMember
    }

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
    /// `event`, `outbox`, `reaction`, `zap`, `zap_attempt`, `deletion`, `edit`,
    /// or `profile` all surface as one new value. The view layer never polls
    /// and never watches the socket.
    nonisolated func observeTimeline(
        channel: String,
        limit: Int,
        me: String?
    ) -> AsyncValueObservation<TimelineSnapshot> {
        ValueObservation
            .tracking { db -> TimelineSnapshot in
                let rows = try Self.fetchTimeline(db, channel: channel, before: nil, limit: limit)
                return try Self.snapshot(db, rows: rows, me: me, channel: channel)
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
                return try Self.snapshot(db, rows: rows, me: me)
            }
            .removeDuplicates()
            .values(in: reader)
    }

    /// The tallies for a page of rows, inside one read.
    ///
    /// Shared by both observations so they cannot drift: a tally added to one
    /// and forgotten in the other is a message that shows its zaps in the
    /// channel and loses them in the thread.
    private static func snapshot(
        _ db: Database,
        rows: [TimelineRow],
        me: String?,
        channel: String? = nil
    ) throws -> TimelineSnapshot {
        let ids = rows.map(\.id)
        let attempts = try fetchPendingZapAttempts(db)

        // Read here rather than left to the screen's own copy of the channel.
        // A pushed ChannelSummary is a value frozen when the row was tapped, so
        // joining from inside a channel changed nothing until you backed out
        // and came in again. Reading it in the observation means the answer
        // arrives the same way every other change to the screen does, and it
        // covers being added by somebody else while the screen is open.
        let isMember = try channel.map { id in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM channel_member
                               WHERE channel_id = ? AND pubkey = ?)
                """, arguments: [id, me ?? ""]) ?? false
        }

        return TimelineSnapshot(
            rows: rows,
            reactions: try fetchReactions(db, for: ids, me: me),
            zaps: try fetchZaps(db, for: ids, me: me),
            // Newest wins where the reader zapped one message more than once:
            // the marker says "waiting", not how many.
            pendingZaps: Dictionary(
                attempts.compactMap { attempt in
                    attempt.targetID.map { ($0, attempt) }
                },
                uniquingKeysWith: { first, _ in first }
            ),
            isMember: isMember
        )
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
    func markRead(channel: String, at now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        try writer.write { db in
            let newest = try Int64.fetchOne(db, sql: """
                SELECT MAX(created_at) FROM event WHERE h = ? AND kind = ?
                """, arguments: [channel, EventKind.groupChatMessage.rawValue])

            try db.execute(sql: """
                INSERT INTO read_state (channel_id, last_read_at, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(channel_id) DO UPDATE SET
                    last_read_at = MAX(read_state.last_read_at, excluded.last_read_at),
                    -- Stamped whenever this runs, even when MAX keeps the old
                    -- marker: the point of the timestamp is when this device
                    -- last had an opinion, and it just had one.
                    updated_at = excluded.updated_at
                """, arguments: [channel, newest ?? 0, now])
        }
    }

    /// Marks a channel unread from one message onward, so it can be come back
    /// to later.
    ///
    /// Deliberately not `MAX`-guarded the way `markRead` is: moving the marker
    /// backwards is the entire point, and the guard that protects `markRead`
    /// from late-arriving history would silently make this a no-op.
    ///
    /// One second before the message, so the message itself lands on the
    /// unread side of the line rather than just outside it.
    func markUnread(
        channel: String,
        from createdAt: Int64,
        at now: Int64 = Int64(Date().timeIntervalSince1970)
    ) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO read_state (channel_id, last_read_at, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(channel_id) DO UPDATE SET
                    last_read_at = excluded.last_read_at,
                    updated_at = excluded.updated_at
                """, arguments: [channel, max(0, createdAt - 1), now])
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
    /// Whether the log actually holds this person's kind 0.
    ///
    /// Without this, "we have never fetched their profile" and "they published
    /// one with no Lightning address" are the same value, and the difference
    /// matters: the first is Comb not knowing yet, the second is an answer.
    public let hasProfile: Bool
    /// How many messages of theirs the local log holds. A rough sense of how
    /// present someone is, without asking the relay anything.
    public let messageCount: Int

    public var id: String { pubkey }

    /// Never the raw npub: a name or a short key, same rule as the timeline.
    public var name: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return String(pubkey.prefix(8))
    }

    /// Whether this person can be zapped, including the case where Comb has not
    /// been told yet.
    public enum ZapCapability: Sendable, Equatable {
        case yes
        case no
        /// No profile has been seen. Worth offering anyway: the answer is one
        /// fetch away, and hiding the button spends the reader's intent on
        /// nothing.
        case unknown
    }

    public var zapCapability: ZapCapability {
        if lightningAddress?.isEmpty == false { return .yes }
        return hasProfile ? .no : .unknown
    }

    public var canReceiveZaps: Bool { zapCapability == .yes }
}

/// Someone on a channel's roster, with the role they hold in it.
///
/// A separate type rather than a field on `ProfileSummary`, because a role is a
/// fact about a person *in a channel*, and `ProfileSummary` is shared with the
/// profile sheet, which has no channel in scope.
public struct ChannelMember: Sendable, Equatable, Identifiable {
    public let profile: ProfileSummary
    public let role: ChannelRole?

    public var id: String { profile.pubkey }
    public var name: String { profile.name }
    public var picture: String? { profile.picture }
    public var pubkey: String { profile.pubkey }
    public var messageCount: Int { profile.messageCount }
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
                    nip05: nil, lightningAddress: nil, hasProfile: false,
                    messageCount: messages
                )
            }

            return ProfileSummary(
                pubkey: row["pubkey"],
                displayName: row["display_name"],
                about: row["about"],
                picture: row["picture"],
                nip05: row["nip05"],
                lightningAddress: row["lud16"],
                hasProfile: true,
                messageCount: row["messages"] ?? 0
            )
        }
    }

    /// The roster of a channel, most talkative first.
    nonisolated func members(of channel: String) throws -> [ChannelMember] {
        let rows: [(String, String?)] = try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT pubkey, role FROM channel_member WHERE channel_id = ?
                """, arguments: [channel]).map { ($0["pubkey"], $0["role"]) }
        }

        return try rows
            .compactMap { pubkey, role in
                try profile(pubkey: pubkey).map {
                    ChannelMember(profile: $0, role: ChannelRole(stored: role))
                }
            }
            // Whoever runs the room first, then the usual order. A roster is
            // read to find someone to ask, and the answer is usually near the
            // top of that hierarchy.
            .sorted {
                if $0.role?.isElevated != $1.role?.isElevated {
                    return $0.role?.isElevated == true
                }
                return $0.profile.messageCount > $1.profile.messageCount
            }
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
                  AND NOT EXISTS (SELECT 1 FROM deletion d
                                  WHERE d.target_id = e.id
                                    AND (d.kind = 9005 OR d.deleted_by = e.pubkey))
                  AND NOT EXISTS (SELECT 1 FROM blocked b WHERE b.pubkey = e.pubkey)
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
                        content: MessageText.display(row["content"]),
                        createdAt: row["created_at"]
                    )
                }
        }
    }
}
