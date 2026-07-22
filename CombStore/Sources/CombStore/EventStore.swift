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

    // MARK: - Lifecycle

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        self.writer = pool
        self.reader = pool
        try Self.prepare(pool)
    }

    /// An in-memory store, for tests.
    public init() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        self.writer = queue
        self.reader = queue
        try Self.prepare(queue)
    }

    private static func prepare(_ writer: any DatabaseWriter) throws {
        try Schema.migrator.migrate(writer)
        try rebuildProjectionsIfStale(writer)
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
        for event in events {
            // Ephemeral kinds are diverted rather than stored. Presence and
            // typing are meaningless within seconds, and writing them would grow
            // the log without bound. They are still verified, because the caller
            // is going to act on them.
            guard event.hasValidID else {
                result.rejected.append(Rejection(id: event.id, reason: .idMismatch))
                continue
            }
            guard event.isValid else {
                result.rejected.append(Rejection(id: event.id, reason: .badSignature))
                continue
            }
            if event.kind.isEphemeral {
                result.ephemeral.append(event)
            } else {
                valid.append(event)
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
    }
}
