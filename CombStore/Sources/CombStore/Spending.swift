import CombCore
import Foundation
import GRDB

/// What one agent may spend, in one channel.
///
/// Two dials and no more. An allowance over a rolling window, and a ceiling on
/// any single zap. Deliberately no approve-each-spend threshold: that converts an
/// autonomous grant into a stream of interruptions, and a stream of approvals
/// trains people to approve reflexively, at which point the approval means
/// nothing and the safety was imaginary. The ceiling covers the same risk without
/// teaching anyone to say yes.
///
/// Also deliberately no recipient rules. They combine badly, they are hard to
/// state in one sentence, and they buy little once an allowance already bounds
/// the damage.
public struct SpendGrant: Sendable, Equatable, Identifiable {
    public let agentPubkey: String
    public let channelID: String
    public let allowanceMillisats: Int64
    public let windowSeconds: Int64
    public let perZapMillisats: Int64
    public let createdAt: Int64

    public init(
        agentPubkey: String,
        channelID: String,
        allowanceMillisats: Int64,
        windowSeconds: Int64,
        perZapMillisats: Int64,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.agentPubkey = agentPubkey
        self.channelID = channelID
        self.allowanceMillisats = allowanceMillisats
        self.windowSeconds = windowSeconds
        self.perZapMillisats = perZapMillisats
        self.createdAt = createdAt
    }

    public var id: String { agentPubkey + ":" + channelID }
    public var allowanceSats: Int64 { allowanceMillisats / 1000 }
    public var perZapSats: Int64 { perZapMillisats / 1000 }

    /// A day is the unit anyone will actually reason about, so it is worth
    /// naming rather than making the reader divide by 86,400.
    public var windowIsADay: Bool { windowSeconds == 86_400 }
}

/// Where a spend request got to.
public enum SpendState: String, Sendable {
    /// Refused before any money moved. Never counts against an allowance.
    case refused
    /// Handed to a wallet, no answer yet. Counts against the allowance from the
    /// moment it is written, because the alternative is a second intent slipping
    /// through while the first is still in flight.
    case paying
    case paid
    /// Attempted and did not work. The money may or may not have moved, so the
    /// ledger keeps it and the reader can see it.
    case failed
}

/// One line of what an agent did, or was stopped from doing.
public struct SpendRecord: Sendable, Equatable, Identifiable {
    public let intentID: String
    public let agentPubkey: String
    public let channelID: String
    public let targetID: String?
    public let recipient: String
    public let amountMillisats: Int64
    public let state: SpendState
    public let reason: String?
    public let createdAt: Int64
    public let settledAt: Int64?

    public var id: String { intentID }
    public var amountSats: Int64 { amountMillisats / 1000 }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
}

/// Why an intent was not acted on.
///
/// Fine grained because the reader sees these in the ledger, and "refused" on its
/// own is useless: an agent over its ceiling is doing something reasonable badly,
/// an agent with no grant may be an agent nobody invited, and a stale intent is
/// probably an app that was closed. Those want different reactions.
public enum SpendRefusal: Equatable, Sendable {
    case noGrant
    case wrongChannel
    case overPerZapCeiling(ceiling: Int64)
    case overAllowance(remaining: Int64)
    /// Older than the freshness window. Without this, a week of intents queued
    /// while the app was closed would drain an allowance the moment it opens.
    case stale
    /// Already in the ledger. One intent, one payment.
    case alreadySeen

    public var sentence: String {
        switch self {
        case .noGrant:
            "No allowance for this agent here."
        case .wrongChannel:
            "Its allowance is for a different channel."
        case .overPerZapCeiling(let ceiling):
            "Over the \((ceiling / 1000).formatted()) sat limit for one zap."
        case .overAllowance(let remaining):
            remaining > 0
                ? "Only \((remaining / 1000).formatted()) sats left in the window."
                : "The allowance for this window is spent."
        case .stale:
            "Asked too long ago to act on."
        case .alreadySeen:
            "Already handled."
        }
    }
}

public extension EventStore {
    /// How fresh an intent has to be to be acted on.
    ///
    /// Five minutes, because an agent asking is a live request and a queue of
    /// them is not. Without this, opening the app after a week away would let
    /// every intent published in the meantime spend at once, which is the one
    /// way a correct allowance can still produce a surprise.
    static var intentFreshness: TimeInterval { 300 }

    // MARK: - Grants

    func grant(_ grant: SpendGrant) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO spend_grant
                    (agent_pubkey, channel_id, allowance_msats, window_seconds,
                     per_zap_msats, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(agent_pubkey, channel_id) DO UPDATE SET
                    allowance_msats = excluded.allowance_msats,
                    window_seconds  = excluded.window_seconds,
                    per_zap_msats   = excluded.per_zap_msats
                """, arguments: [
                    grant.agentPubkey, grant.channelID, grant.allowanceMillisats,
                    grant.windowSeconds, grant.perZapMillisats, grant.createdAt,
                ])
        }
    }

    /// Takes an allowance away, immediately.
    ///
    /// Nothing in flight is honoured on the strength of a grant that existed
    /// when the intent arrived: the check runs against the grant at the moment
    /// of payment, so revoking stops a spend that has been decided but not yet
    /// made.
    func revokeGrant(agent: String, channel: String) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM spend_grant WHERE agent_pubkey = ? AND channel_id = ?",
                arguments: [agent, channel]
            )
        }
    }

    nonisolated func spendGrant(agent: String, channel: String) throws -> SpendGrant? {
        try reader.read { db in try Self.fetchGrant(db, agent: agent, channel: channel) }
    }

    /// Every allowance this reader has given, newest first.
    nonisolated func spendGrants() throws -> [SpendGrant] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM spend_grant ORDER BY created_at DESC
                """).map(Self.grant(from:))
        }
    }

    static func fetchGrant(
        _ db: Database,
        agent: String,
        channel: String
    ) throws -> SpendGrant? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM spend_grant WHERE agent_pubkey = ? AND channel_id = ?
            """, arguments: [agent, channel]).map(grant(from:))
    }

    private static func grant(from row: Row) -> SpendGrant {
        SpendGrant(
            agentPubkey: row["agent_pubkey"],
            channelID: row["channel_id"],
            allowanceMillisats: row["allowance_msats"],
            windowSeconds: row["window_seconds"],
            perZapMillisats: row["per_zap_msats"],
            createdAt: row["created_at"]
        )
    }

    // MARK: - The window

    /// What an agent has already committed inside its window.
    ///
    /// Summed over `settled_at`, so a refusal never counts and a payment still in
    /// flight does. SQL rather than a timer: the window is a lookback, it needs
    /// no upkeep, and it survives the app being killed, which an in-memory
    /// window would not.
    nonisolated func spent(
        agent: String,
        channel: String,
        window: Int64,
        now: Date = Date()
    ) throws -> Int64 {
        try reader.read { db in
            try Self.fetchSpent(db, agent: agent, channel: channel, window: window, now: now)
        }
    }

    static func fetchSpent(
        _ db: Database,
        agent: String,
        channel: String,
        window: Int64,
        now: Date = Date()
    ) throws -> Int64 {
        let cutoff = Int64(now.timeIntervalSince1970) - window
        return try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(amount_msats), 0) FROM spend_ledger
            WHERE agent_pubkey = ? AND channel_id = ?
              AND settled_at IS NOT NULL AND settled_at >= ?
            """, arguments: [agent, channel, cutoff]) ?? 0
    }

    // MARK: - The decision

    /// Whether an intent may be paid, and why not when it may not.
    ///
    /// Every check in one place, and deliberately not spread across the caller:
    /// this is the function that decides whether somebody's money moves, so it
    /// should be readable in one sitting and testable without a relay, a wallet
    /// or a UI.
    ///
    /// `now` is injectable because two of the five checks are about time, and a
    /// test that cannot control the clock cannot cover them.
    nonisolated func decide(
        _ intent: Zap.Intent,
        now: Date = Date()
    ) throws -> SpendRefusal? {
        try reader.read { db in
            // Cheapest and most absolute first. No grant is not a budget
            // question, it is an agent nobody authorised.
            guard let grant = try Self.fetchGrant(
                db, agent: intent.agent, channel: intent.channel
            ) else {
                // Told apart so the ledger can say something useful: an agent
                // with an allowance somewhere else is a misconfiguration, and one
                // with none at all may be uninvited.
                let elsewhere = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM spend_grant WHERE agent_pubkey = ?)
                    """, arguments: [intent.agent]) ?? false
                return elsewhere ? .wrongChannel : .noGrant
            }

            // Before the amount checks: a replay of an intent already paid must
            // not be reported as over budget, which would read as the allowance
            // being the problem.
            let seen = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM spend_ledger WHERE intent_id = ?)
                """, arguments: [intent.id]) ?? false
            if seen { return .alreadySeen }

            if now.timeIntervalSince(intent.date) > Self.intentFreshness { return .stale }

            if intent.amountMillisats > grant.perZapMillisats {
                return .overPerZapCeiling(ceiling: grant.perZapMillisats)
            }

            let already = try Self.fetchSpent(
                db, agent: intent.agent, channel: intent.channel,
                window: grant.windowSeconds, now: now
            )
            let remaining = grant.allowanceMillisats - already
            if intent.amountMillisats > remaining {
                return .overAllowance(remaining: max(0, remaining))
            }

            return nil
        }
    }

    // MARK: - The ledger

    /// Claims an intent and marks it in flight.
    ///
    /// Returns false when it was already claimed, which is what makes the
    /// decision and the payment atomic against a second arrival of the same
    /// intent: the insert is the lock, so two deliveries cannot both pass the
    /// check and both pay.
    func claim(_ intent: Zap.Intent, at date: Date = Date()) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO spend_ledger
                    (intent_id, agent_pubkey, channel_id, target_id, recipient,
                     amount_msats, state, created_at, settled_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(intent_id) DO NOTHING
                """, arguments: [
                    intent.id, intent.agent, intent.channel, intent.targetEventID,
                    intent.recipient, intent.amountMillisats,
                    SpendState.paying.rawValue, Int64(date.timeIntervalSince1970),
                    // Counted against the window from now, because an in-flight
                    // payment is money the reader has committed.
                    Int64(date.timeIntervalSince1970),
                ])
            return db.changesCount == 1
        }
    }

    /// Records a refusal, so the reader can see what was stopped and why.
    func refuse(_ intent: Zap.Intent, _ refusal: SpendRefusal, at date: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO spend_ledger
                    (intent_id, agent_pubkey, channel_id, target_id, recipient,
                     amount_msats, state, reason, created_at, settled_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(intent_id) DO NOTHING
                """, arguments: [
                    intent.id, intent.agent, intent.channel, intent.targetEventID,
                    intent.recipient, intent.amountMillisats,
                    SpendState.refused.rawValue, refusal.sentence,
                    Int64(date.timeIntervalSince1970),
                ])
        }
    }

    func settle(_ intentID: String, state: SpendState, reason: String? = nil) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE spend_ledger
                SET state = ?, reason = ?,
                    -- A failure stops counting against the allowance. The money
                    -- may still have moved, which is why the row stays and says
                    -- so, but holding an allowance against a payment that did
                    -- not happen would be the wrong way round.
                    settled_at = CASE WHEN ? = 'failed' THEN NULL ELSE settled_at END
                WHERE intent_id = ?
                """, arguments: [state.rawValue, reason, state.rawValue, intentID])
        }
    }

    /// What agents have done here, newest first.
    nonisolated func spendLedger(limit: Int = 100) throws -> [SpendRecord] {
        try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM spend_ledger ORDER BY created_at DESC LIMIT ?
                """, arguments: [limit]).map { row in
                SpendRecord(
                    intentID: row["intent_id"],
                    agentPubkey: row["agent_pubkey"],
                    channelID: row["channel_id"],
                    targetID: row["target_id"],
                    recipient: row["recipient"],
                    amountMillisats: row["amount_msats"],
                    state: SpendState(rawValue: row["state"]) ?? .failed,
                    reason: row["reason"],
                    createdAt: row["created_at"],
                    settledAt: row["settled_at"]
                )
            }
        }
    }

    /// Emits the grants and the ledger whenever either changes, so a meter
    /// counting down does it live.
    nonisolated func observeSpending() -> AsyncValueObservation<[SpendRecord]> {
        ValueObservation
            .tracking { db -> [SpendRecord] in
                try Row.fetchAll(db, sql: """
                    SELECT * FROM spend_ledger ORDER BY created_at DESC LIMIT 100
                    """).map { row in
                    SpendRecord(
                        intentID: row["intent_id"],
                        agentPubkey: row["agent_pubkey"],
                        channelID: row["channel_id"],
                        targetID: row["target_id"],
                        recipient: row["recipient"],
                        amountMillisats: row["amount_msats"],
                        state: SpendState(rawValue: row["state"]) ?? .failed,
                        reason: row["reason"],
                        createdAt: row["created_at"],
                        settledAt: row["settled_at"]
                    )
                }
            }
            .removeDuplicates()
            .values(in: reader)
    }
}
