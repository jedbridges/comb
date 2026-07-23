import CombCore
import Foundation
import GRDB

/// Lifecycle of a message we sent.
public enum OutboxState: String, Sendable {
    /// Signed and queued, not yet handed to the relay.
    case pending
    /// Handed to the relay, waiting on its OK.
    case sending
    /// The relay said no, or the connection failed.
    case failed
}

/// A queued send, with everything needed to retry it without re-signing.
public struct OutboxEntry: Sendable, Equatable, Identifiable {
    public let event: NostrEvent
    public let channelID: String
    public let state: OutboxState
    public let attempts: Int
    public let lastError: String?

    public var id: String { event.id }
}

public extension EventStore {
    /// Queues a signed message for sending.
    ///
    /// Called before the relay is contacted. Because a Nostr event id is a hash
    /// of its own contents, the id already exists at this point, so the queued
    /// row and the eventual log row share one identity. The UI sees a message
    /// change state rather than being replaced, which is what lets SwiftUI
    /// animate it instead of reinserting it.
    func enqueue(_ event: NostrEvent, channel: String) throws {
        // Thread position is denormalized out of the event's tags so a queued
        // reply lands in its thread immediately, rather than showing up in the
        // channel and hopping into the thread once the relay answers.
        let reference = event.threadReference

        try writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO outbox
                        (event_id, channel_id, pubkey, content, created_at, payload,
                         state, attempts, root_id, parent_id, tags)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                    ON CONFLICT(event_id) DO NOTHING
                    """,
                arguments: [
                    event.id,
                    channel,
                    event.pubkey,
                    event.content,
                    event.createdAt,
                    String(decoding: try JSONEncoder().encode(event), as: UTF8.self),
                    OutboxState.pending.rawValue,
                    reference.rootID,
                    reference.parentID,
                    String(decoding: try JSONEncoder().encode(event.tags), as: UTF8.self),
                ]
            )
        }
    }

    /// Records that the relay accepted a queued message.
    ///
    /// Moves it into the log and drops the queue row in one transaction, so the
    /// timeline can never observe it as both pending and sent, or as neither.
    ///
    /// The event goes through the same verification as anything from a relay.
    /// Trusting it because we signed it would put an unverified path into the
    /// log, and the value of a single choke point is that there are no exceptions.
    func confirmSent(_ event: NostrEvent) throws {
        guard event.isValid else { throw OutboxError.invalidEvent(event.id) }
        let receivedAt = Int64(Date().timeIntervalSince1970)

        try writer.write { db in
            _ = try Self.write(event, receivedAt: receivedAt, into: db)
            try db.execute(
                sql: "DELETE FROM outbox WHERE event_id = ?",
                arguments: [event.id]
            )
        }
    }

    /// Marks a queued message as handed to the relay.
    func markSending(_ eventID: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                    UPDATE outbox SET state = ?, attempts = attempts + 1
                    WHERE event_id = ?
                    """,
                arguments: [OutboxState.sending.rawValue, eventID]
            )
        }
    }

    /// Records a rejection or a send failure, with a reason to show the user.
    func markFailed(_ eventID: String, error: String?) throws {
        try writer.write { db in
            try db.execute(
                sql: "UPDATE outbox SET state = ?, last_error = ? WHERE event_id = ?",
                arguments: [OutboxState.failed.rawValue, error, eventID]
            )
        }
    }

    /// Drops a queued message without sending it, for a user-cancelled retry.
    func discard(_ eventID: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE event_id = ?", arguments: [eventID])
        }
    }

    /// Everything still queued, oldest first.
    ///
    /// Rows left in `sending` are included: that state means the app stopped
    /// between handing a message to the relay and hearing back, so the outcome
    /// is unknown. Resending is safe because the relay deduplicates by event id,
    /// whereas dropping it would silently lose a message the user believes they
    /// sent.
    nonisolated func pendingSends(channel: String? = nil) throws -> [OutboxEntry] {
        let filter = channel == nil ? "" : "WHERE channel_id = :channel"
        let sql = "SELECT * FROM outbox \(filter) ORDER BY created_at ASC, event_id ASC"

        return try reader.read { db in
            try Row.fetchAll(db, sql: sql, arguments: ["channel": channel])
                .compactMap { row in
                    let payload: String = row["payload"]
                    guard let event = try? JSONDecoder().decode(
                        NostrEvent.self,
                        from: Data(payload.utf8)
                    ) else { return nil }

                    return OutboxEntry(
                        event: event,
                        channelID: row["channel_id"],
                        state: OutboxState(rawValue: row["state"]) ?? .pending,
                        attempts: row["attempts"],
                        lastError: row["last_error"]
                    )
                }
        }
    }

    nonisolated func pendingSendCount() throws -> Int {
        try reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox") ?? 0
        }
    }
}

public enum OutboxError: Error, Equatable {
    /// A queued event failed verification on confirmation, which would mean it
    /// was altered between signing and acknowledgement.
    case invalidEvent(String)
}
