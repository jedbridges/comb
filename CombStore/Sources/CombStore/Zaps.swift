import CombCore
import Foundation
import GRDB

/// A zap this reader handed to a wallet, still waiting on its receipt.
///
/// Deliberately not called a "sent zap". Comb produced an invoice and opened it
/// with `lightning:`; whether a wallet ever paid it is something only a receipt
/// can answer, and a receipt may never arrive.
public struct ZapAttempt: Sendable, Equatable, Identifiable {
    public let requestID: String
    public let targetID: String?
    public let recipient: String
    public let issuer: String
    public let amountMillisats: Int64
    public let createdAt: Int64

    public init(
        requestID: String,
        targetID: String?,
        recipient: String,
        issuer: String,
        amountMillisats: Int64,
        createdAt: Int64
    ) {
        self.requestID = requestID
        self.targetID = targetID
        self.recipient = recipient
        self.issuer = issuer
        self.amountMillisats = amountMillisats
        self.createdAt = createdAt
    }

    public var id: String { requestID }
    public var amountSats: Int64 { amountMillisats / 1000 }
}

public extension EventStore {
    /// How long an unanswered attempt stays visible.
    ///
    /// An attempt is a claim about something Comb cannot observe, so it has to
    /// expire. An hour is generous for a payment that either happened in the
    /// wallet within a minute or did not happen at all, and short enough that an
    /// abandoned zap does not sit on a message all week implying otherwise.
    static var zapAttemptLifetime: TimeInterval { 3600 }

    /// Records that an invoice was handed to a wallet.
    ///
    /// Written at the handoff rather than on return, because returning to Comb
    /// is not evidence of anything: the reader may have paid, cancelled, or
    /// never seen the wallet open. Persisting here is what lets the pending
    /// marker survive the sheet closing and the app being killed.
    func recordZapAttempt(
        requestID: String,
        targetID: String?,
        recipient: String,
        issuer: String,
        amountMillisats: Int64,
        at date: Date = Date()
    ) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO zap_attempt
                    (request_id, target_id, recipient, issuer, amount_msats, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(request_id) DO NOTHING
                """, arguments: [
                    requestID, targetID, recipient, issuer,
                    amountMillisats, Int64(date.timeIntervalSince1970),
                ])

            // The endpoint's signing key, learned for free on the way to the
            // invoice. Refreshed on every zap because a recipient can move
            // wallet provider, and the newest answer is the one to trust.
            try db.execute(sql: """
                INSERT INTO lnurl_issuer (pubkey, issuer_pubkey, fetched_at)
                VALUES (?, ?, ?)
                ON CONFLICT(pubkey) DO UPDATE SET
                    issuer_pubkey = excluded.issuer_pubkey,
                    fetched_at = excluded.fetched_at
                """, arguments: [recipient, issuer, Int64(date.timeIntervalSince1970)])
        }
    }

    /// Removes attempts old enough that no receipt is coming.
    @discardableResult
    func pruneZapAttempts(before date: Date = Date()) throws -> Int {
        let cutoff = Int64(date.addingTimeInterval(-Self.zapAttemptLifetime).timeIntervalSince1970)
        return try writer.write { db in
            try db.execute(
                sql: "DELETE FROM zap_attempt WHERE created_at < ?",
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }

    /// The reader's own unanswered attempts, newest first.
    nonisolated func pendingZapAttempts(at date: Date = Date()) throws -> [ZapAttempt] {
        try reader.read { db in try Self.fetchPendingZapAttempts(db, at: date) }
    }

    /// Shared with the timeline observation, which needs the same rows inside
    /// its own read.
    static func fetchPendingZapAttempts(
        _ db: Database,
        at date: Date = Date()
    ) throws -> [ZapAttempt] {
        let cutoff = Int64(date.addingTimeInterval(-zapAttemptLifetime).timeIntervalSince1970)
        return try Row.fetchAll(db, sql: """
            SELECT request_id, target_id, recipient, issuer, amount_msats, created_at
            FROM zap_attempt
            WHERE created_at >= ?
              -- Answered attempts stop being pending. Done here rather than by
              -- deleting the row when the receipt lands: the projector writes
              -- the zap, and a projector that also mutated local state would
              -- no longer be replayable without side effects. Filtering at read
              -- time is self-correcting and leaves the rebuild pure.
              AND NOT EXISTS (
                    SELECT 1 FROM zap z WHERE z.request_id = zap_attempt.request_id
                  )
            ORDER BY created_at DESC
            """, arguments: [cutoff]).map { row in
            ZapAttempt(
                requestID: row["request_id"],
                targetID: row["target_id"],
                recipient: row["recipient"],
                issuer: row["issuer"],
                amountMillisats: row["amount_msats"],
                createdAt: row["created_at"]
            )
        }
    }

    /// The key an endpoint signs receipts with, if this reader has ever zapped
    /// them. Absent for everyone else, which is the point: learning it for a
    /// stranger would mean a request to their wallet host that the reader never
    /// asked for.
    nonisolated func cachedIssuer(for pubkey: String) throws -> String? {
        try reader.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT issuer_pubkey FROM lnurl_issuer WHERE pubkey = ?",
                arguments: [pubkey]
            )
        }
    }
}
