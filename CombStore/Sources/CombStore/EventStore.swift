import CombCore
import Foundation
import GRDB

/// The persistence layer, and the only place events enter the app's storage.
///
/// `ingest` is the single choke point where verification happens. Nothing else
/// writes to `event`, and nothing re-verifies on read, so the invariant "every
/// stored event was cryptographically valid at the moment it was stored" holds
/// as long as this one function is correct. That is why it has adversarial tests.
public actor EventStore {
    /// Internal rather than private so the outbox extension can share the same
    /// connection, and with it the same transaction semantics.
    let writer: any DatabaseWriter

    /// Exposed so read-only observation can be set up outside the actor.
    /// Callers get a reader, never a writer.
    public nonisolated let reader: any DatabaseReader

    /// The key this relay signs group state with, from its NIP-11 `self` field.
    ///
    /// Held in `meta` rather than only in memory, so a replay reaches the same
    /// verdicts offline as live ingest did. Nil means the relay does not
    /// publish one, and the check is skipped: a plain NIP-29 relay that never
    /// heard of NIP-11 `self` must still work, and refusing its group state
    /// would break the app rather than protect it.
    private var relaySigningKey: String?

    // MARK: - Lifecycle

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        self.writer = pool
        self.reader = pool
        try Self.prepare(pool)
        self.relaySigningKey = try Self.storedRelaySigningKey(pool)
    }

    /// An in-memory store, for tests.
    public init() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        self.writer = queue
        self.reader = queue
        try Self.prepare(queue)
        self.relaySigningKey = try Self.storedRelaySigningKey(queue)
    }

    /// Records the key this relay signs group state with, learned from its
    /// NIP-11 document.
    ///
    /// Idempotent, and safe to call on every connect: the relay's key does not
    /// change often, and when it does the newest answer is the one to keep.
    /// Passing nil clears it, which turns the check off rather than rejecting
    /// everything.
    public func setRelaySigningKey(_ pubkey: String?) throws {
        relaySigningKey = pubkey
        try writer.write { db in
            if let pubkey {
                try db.execute(sql: """
                    INSERT INTO meta (key, value) VALUES ('relay_signing_key', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """, arguments: [pubkey])
            } else {
                try db.execute(sql: "DELETE FROM meta WHERE key = 'relay_signing_key'")
            }
        }
    }

    /// Read once at open, so an offline launch and a replay both apply the same
    /// rule the live session did.
    private static func storedRelaySigningKey(_ reader: any DatabaseReader) throws -> String? {
        try reader.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM meta WHERE key = 'relay_signing_key'"
            )
        }
    }

    private static func prepare(_ writer: any DatabaseWriter) throws {
        try Schema.migrator.migrate(writer)
        try rebuildProjectionsIfStale(writer)
    }

    /// Returns once no write is in flight, and guarantees nothing about after.
    ///
    /// A barrier rather than a query: GRDB serialises writes, so an empty one
    /// cannot begin until whatever transaction was open has committed, and
    /// awaiting it is how a caller learns the database is not mid-write.
    ///
    /// This exists for backgrounding. iOS terminates a process that is
    /// suspended while holding a lock on a database file rather than resuming
    /// it, so any moment the app volunteers as a good one to suspend it, by
    /// reporting a background task complete, has to be a moment no transaction
    /// is open. Cancelling the work that was writing is not enough, because a
    /// transaction already in progress does not check for cancellation and
    /// finishes on its own schedule.
    public nonisolated func settle() async {
        try? await writer.write { _ in }
    }

    // MARK: - Verification

    /// What checking one event concluded.
    private enum Verdict {
        case valid
        case idMismatch
        case badSignature
    }

    /// Checks every event, using every core.
    ///
    /// Verification is what ingest costs. Measured over a thousand events, the
    /// id recomputation is around seven milliseconds and the hex decoding
    /// eleven; the BIP-340 signature check is five hundred and thirty. That is
    /// elliptic curve arithmetic and no amount of restructuring makes it
    /// cheaper, so the only lever left is doing it on more than one core at a
    /// time.
    ///
    /// Which suits it: each check reads one event, writes one slot, and shares
    /// nothing. A bootstrap of fourteen hundred events measured eight hundred
    /// and twelve milliseconds in a single line and a hundred and forty-eight
    /// across eight cores. That time is on the path of every cold start, every
    /// reconnect, and every background wake, where it is spent against a budget
    /// with about twenty seconds in it.
    ///
    /// One event is left alone. Below that the split costs more than it saves,
    /// and a lone event arriving live is the most common ingest there is.
    private static func verdicts(for events: [NostrEvent]) -> [Verdict] {
        let count = events.count
        let chunks = min(ProcessInfo.processInfo.activeProcessorCount, count)
        guard chunks > 1 else { return events.map(verdict(for:)) }

        // Pre-filled rather than left uninitialised, so the array is valid
        // whatever the split does. Every index is written by exactly one chunk.
        var verdicts = [Verdict](repeating: .idMismatch, count: count)
        let size = (count + chunks - 1) / chunks

        verdicts.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let start = chunk * size
                let end = min(start + size, count)
                guard start < end else { return }
                // Distinct indices per chunk, so the writes never overlap.
                for index in start..<end {
                    slots[index] = verdict(for: events[index])
                }
            }
        }
        return verdicts
    }

    /// The id is recomputed before the signature is checked, and deliberately
    /// twice: `isValid` repeats it internally, because a signature that
    /// verifies over a swapped id is exactly what that pairing exists to catch
    /// and neither half is safe to trust alone. The repeat costs under one per
    /// cent of the check and buys an invariant that cannot be got wrong here.
    private static func verdict(for event: NostrEvent) -> Verdict {
        guard event.hasValidID else { return .idMismatch }
        return event.isValid ? .valid : .badSignature
    }

    // MARK: - Ingest

    /// Verifies and stores a batch, returning what happened to each event.
    ///
    /// The whole batch is one transaction. Partial application would leave the
    /// log and its projections describing different worlds.
    @discardableResult
    public func ingest(_ events: [NostrEvent]) throws -> IngestResult {
        guard !events.isEmpty else { return IngestResult() }

        var result = IngestResult()
        var valid: [NostrEvent] = []
        valid.reserveCapacity(events.count)

        // Verification happens before the transaction so a slow batch of
        // signature checks never holds the write lock.
        //
        // Judged in parallel, sorted through serially. Splitting it this way is
        // what keeps the result deterministic: the expensive part is a pure
        // function of one event and cares nothing for order, while the order
        // events are stored in is observable, so only the first half is spread
        // across cores.
        let verdicts = Self.verdicts(for: events)

        for (event, verdict) in zip(events, verdicts) {
            switch verdict {
            case .idMismatch:
                result.rejected.append(Rejection(id: event.id, reason: .idMismatch))
            case .badSignature:
                result.rejected.append(Rejection(id: event.id, reason: .badSignature))
            case .valid:
                // Applied here rather than inside `verdicts`, which is spread
                // across cores and deliberately a pure function of one event.
                // This one needs state, and it is a string comparison, so it
                // belongs on the cheap serial side of the split.
                if let relaySigningKey,
                   event.kind.isRelaySigned,
                   event.pubkey != relaySigningKey {
                    result.rejected.append(
                        Rejection(id: event.id, reason: .notFromRelay)
                    )
                    continue
                }

                // Ephemeral kinds are diverted rather than stored. Presence and
                // typing are meaningless within seconds, and writing them would
                // grow the log without bound. They are still verified, because
                // the caller is going to act on them.
                if event.kind.isEphemeral {
                    result.ephemeral.append(event)
                } else {
                    valid.append(event)
                }
            }
        }

        guard !valid.isEmpty else { return result }

        let receivedAt = Int64(Date().timeIntervalSince1970)

        try writer.write { db in
            for event in valid {
                if try Self.write(event, receivedAt: receivedAt, into: db) {
                    result.inserted.append(event.id)
                } else {
                    result.duplicates.append(event.id)
                }
            }
        }

        return result
    }

    /// Writes one already-verified event and its projections.
    ///
    /// Returns false when the event was already present. Callers must have
    /// verified it: this is below the choke point, not part of it.
    ///
    /// Shared with the outbox confirmation path so a message we sent lands in
    /// the log by exactly the same route as one that arrived from the relay.
    static func write(
        _ event: NostrEvent,
        receivedAt: Int64,
        into db: Database
    ) throws -> Bool {
        // The id is a content address, so a second copy of an event is by
        // definition identical and can be ignored outright. This is what makes
        // reconnect overlap and echoed sends free.
        try db.execute(
            sql: """
                INSERT INTO event (id, pubkey, created_at, kind, content, tags, sig, h, received_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
            arguments: [
                event.id,
                event.pubkey,
                event.createdAt,
                event.kind.rawValue,
                event.content,
                try encodeTags(event.tags),
                event.sig,
                event.groupID,
                receivedAt,
            ]
        )

        // ON CONFLICT DO NOTHING means zero changes is the signal that this
        // event was already in the log.
        guard db.changesCount > 0 else { return false }

        try insertTags(event, into: db)
        try Projector.project(event, into: db)
        return true
    }

    /// Indexes single-letter tags for `#e` / `#p` style lookups.
    private static func insertTags(_ event: NostrEvent, into db: Database) throws {
        for (position, tag) in event.tags.enumerated() {
            guard let name = tag.first, name.count == 1, tag.count > 1 else { continue }
            try db.execute(
                sql: "INSERT INTO event_tag (event_id, name, value, position) VALUES (?, ?, ?, ?)",
                arguments: [event.id, name, tag[1], position]
            )
        }
    }

    private static func encodeTags(_ tags: [[String]]) throws -> String {
        let data = try JSONEncoder().encode(tags)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Reads

    /// Reconstructs an event from the log. Used by tests and by the outbox
    /// reconciliation path; the UI reads projections and timeline rows instead.
    public func event(id: String) throws -> NostrEvent? {
        try reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM event WHERE id = ?", arguments: [id])
                .map(Self.decode)
        }
    }

    public func count(kind: EventKind? = nil) throws -> Int {
        try reader.read { db in
            if let kind {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM event WHERE kind = ?",
                    arguments: [kind.rawValue]
                ) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
        }
    }

    static func decode(_ row: Row) -> NostrEvent {
        let tagsJSON: String = row["tags"]
        let tags = (try? JSONDecoder().decode([[String]].self, from: Data(tagsJSON.utf8))) ?? []

        return NostrEvent(
            id: row["id"],
            pubkey: row["pubkey"],
            createdAt: row["created_at"],
            kind: EventKind(rawValue: row["kind"]),
            tags: tags,
            content: row["content"],
            sig: row["sig"]
        )
    }

    // MARK: - Projection rebuild

    /// Drops and replays every projection when their version has moved on.
    ///
    /// This is the payoff of keeping the log authoritative: a projection bug is
    /// fixed by bumping a constant, not by resyncing from a relay that may no
    /// longer hold the history.
    private static func rebuildProjectionsIfStale(_ writer: any DatabaseWriter) throws {
        try writer.write { db in
            let stored = try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = 'projection_version'"
            )
            guard stored != String(Schema.projectionVersion) else { return }

            try Schema.dropProjectionTables(db)
            try Schema.createProjectionTables(db)
            try replayProjections(db)

            try db.execute(
                sql: """
                    INSERT INTO meta (key, value) VALUES ('projection_version', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [String(Schema.projectionVersion)]
            )
        }
    }

    /// Replays the whole log in the order it happened.
    ///
    /// Order matters: projections use "newer wins" comparisons, so replaying out
    /// of order would settle on different rows than live ingest did. The `id`
    /// tiebreak keeps same-second events in a stable order.
    private static func replayProjections(_ db: Database) throws {
        let cursor = try Row.fetchCursor(
            db,
            sql: "SELECT * FROM event ORDER BY created_at ASC, id ASC"
        )
        while let row = try cursor.next() {
            try Projector.project(decode(row), into: db)
        }
    }

    /// Forces a rebuild. Exposed for tests that assert live and replayed
    /// projections agree.
    public func rebuildProjections() throws {
        try writer.write { db in
            try Schema.dropProjectionTables(db)
            try Schema.createProjectionTables(db)
            try Self.replayProjections(db)
        }
    }
}

// MARK: - Results

public struct IngestResult: Sendable, Equatable {
    /// Events newly written to the log.
    public var inserted: [String] = []
    /// Events already present. Expected and harmless: reconnect overlap and
    /// echoes of our own sends both land here.
    public var duplicates: [String] = []
    /// Verified but deliberately not stored.
    public var ephemeral: [NostrEvent] = []
    /// Events that failed verification and were discarded.
    public var rejected: [Rejection] = []

    public var isEmpty: Bool {
        inserted.isEmpty && duplicates.isEmpty && ephemeral.isEmpty && rejected.isEmpty
    }
}

public struct Rejection: Sendable, Equatable {
    public let id: String
    public let reason: Reason

    public enum Reason: Sendable, Equatable {
        /// The id does not match a hash of the contents, so the event was
        /// altered after signing.
        case idMismatch
        /// The id is intact but the signature does not verify under the claimed
        /// pubkey.
        case badSignature
        /// A relay-signed kind arrived signed by somebody who is not the relay.
        ///
        /// The signature is perfectly valid; the signer simply has no standing
        /// to make this claim. Group metadata and rosters are the relay's word
        /// on who exists and who runs a channel, so anyone able to publish could
        /// otherwise name themselves an owner and have Comb believe it.
        case notFromRelay
    }
}
