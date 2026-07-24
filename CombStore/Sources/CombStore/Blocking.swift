import CombCore
import Foundation
import GRDB

/// Someone this reader has chosen not to see.
public struct BlockedPerson: Sendable, Equatable, Identifiable {
    public let pubkey: String
    public let name: String
    public let picture: String?
    public let blockedAt: Int64

    public var id: String { pubkey }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(blockedAt)) }
}

public extension EventStore {
    /// Hides everything from this person, on this device.
    ///
    /// Nothing is published and the blocked person is never told. The relay
    /// keeps delivering their messages and the log keeps storing them; every
    /// read path simply filters them out. That is the honest model for a
    /// protocol where blocking cannot be enforced server-side, and it means
    /// unblocking restores the history rather than needing a refetch.
    func block(pubkey: String, at date: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO blocked (pubkey, blocked_at) VALUES (?, ?)
                ON CONFLICT(pubkey) DO NOTHING
                """, arguments: [pubkey, Int64(date.timeIntervalSince1970)])
        }
    }

    func unblock(pubkey: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM blocked WHERE pubkey = ?", arguments: [pubkey])
        }
    }

    nonisolated func isBlocked(pubkey: String) throws -> Bool {
        try reader.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM blocked WHERE pubkey = ?)",
                arguments: [pubkey]
            ) ?? false
        }
    }

    /// Everyone blocked, newest first, joined with whatever the store knows
    /// about them so the list in Settings shows people rather than keys.
    nonisolated func blockedPeople() throws -> [BlockedPerson] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT b.pubkey, b.blocked_at,
                       COALESCE(p.display_name, substr(b.pubkey, 1, 8)) AS name,
                       p.picture
                FROM blocked b
                LEFT JOIN profile p ON p.pubkey = b.pubkey
                ORDER BY b.blocked_at DESC
                """)
            .map { row in
                BlockedPerson(
                    pubkey: row["pubkey"],
                    name: row["name"] ?? "",
                    picture: row["picture"],
                    blockedAt: row["blocked_at"]
                )
            }
        }
    }

    /// Fires whenever the blocked set changes, so a screen showing the list
    /// updates without being told to.
    nonisolated func observeBlocked() -> AsyncValueObservation<[BlockedPerson]> {
        ValueObservation
            .tracking { db in
                try Row.fetchAll(db, sql: """
                    SELECT b.pubkey, b.blocked_at,
                           COALESCE(p.display_name, substr(b.pubkey, 1, 8)) AS name,
                           p.picture
                    FROM blocked b
                    LEFT JOIN profile p ON p.pubkey = b.pubkey
                    ORDER BY b.blocked_at DESC
                    """)
                .map { row in
                    BlockedPerson(
                        pubkey: row["pubkey"],
                        name: row["name"] ?? "",
                        picture: row["picture"],
                        blockedAt: row["blocked_at"]
                    )
                }
            }
            .values(in: reader)
    }
}
