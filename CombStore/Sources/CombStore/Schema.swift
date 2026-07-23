import Foundation
import GRDB

/// The database schema.
///
/// Two kinds of table live here and they have very different lifecycles.
///
/// `event` and `event_tag` are the source of truth: append-only, never updated,
/// and migrated with real care because losing them means refetching everything
/// from a relay that may no longer hold it.
///
/// Everything else is a projection over that log. Projections are dropped and
/// rebuilt whenever `projectionVersion` changes, so adding a column or fixing a
/// parsing bug costs a version bump rather than a migration and a resync.
enum Schema {
    /// Bump when any projection's shape or meaning changes. On next open, every
    /// projection table is dropped and replayed from `event`.
    static let projectionVersion = 2

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Guards against a projection bug being papered over by a stale table
        // during development. Harmless in release: the log is untouched.
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = false
        #endif

        migrator.registerMigration("v1.log") { db in
            // ── Source of truth ────────────────────────────────────────────
            //
            // Deliberately NOT `WITHOUT ROWID`, here and everywhere below, even
            // though the content-addressed TEXT primary keys make it look
            // attractive. SQLite's update hook does not fire for WITHOUT ROWID
            // tables, and GRDB's ValueObservation depends on that hook: with it,
            // the initial fetch works and then no change is ever noticed again.
            // The UI is built entirely on observation, so the hidden-rowid cost
            // is the price of the architecture working at all.
            try db.execute(sql: """
                CREATE TABLE event (
                    id          TEXT PRIMARY KEY NOT NULL,
                    pubkey      TEXT NOT NULL,
                    created_at  INTEGER NOT NULL,
                    kind        INTEGER NOT NULL,
                    content     TEXT NOT NULL,
                    tags        TEXT NOT NULL,
                    sig         TEXT NOT NULL,
                    h           TEXT,
                    received_at INTEGER NOT NULL
                )
                """)

            // Serves the timeline query directly: channel, kind, newest first.
            try db.execute(sql: """
                CREATE INDEX event_timeline ON event(h, kind, created_at DESC, id)
                """)
            try db.execute(sql: "CREATE INDEX event_author ON event(pubkey, created_at DESC)")
            try db.execute(sql: "CREATE INDEX event_kind ON event(kind, created_at DESC)")

            // Single-letter tags only. Multi-character tags are addressed by
            // reading the event's own tags JSON; NIP-01 only indexes single
            // letters, and indexing everything would double the write cost.
            try db.execute(sql: """
                CREATE TABLE event_tag (
                    event_id TEXT NOT NULL REFERENCES event(id) ON DELETE CASCADE,
                    name     TEXT NOT NULL,
                    value    TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    PRIMARY KEY (event_id, name, position)
                )
                """)
            try db.execute(sql: "CREATE INDEX event_tag_lookup ON event_tag(name, value)")
        }

        migrator.registerMigration("v1.local") { db in
            // ── Local-only state, not derived from any event ───────────────

            // Messages signed but not yet acknowledged by the relay. The event id
            // exists the moment we sign, so an outbox row and its eventual event
            // row share an identity and the UI never sees a swap.
            //
            // `pubkey` and `content` are duplicated out of `payload` so the
            // timeline can union event rows and outbox rows in one statement
            // without extracting JSON in SQL.
            try db.execute(sql: """
                CREATE TABLE outbox (
                    event_id   TEXT PRIMARY KEY NOT NULL,
                    channel_id TEXT NOT NULL,
                    pubkey     TEXT NOT NULL,
                    content    TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    payload    TEXT NOT NULL,
                    state      TEXT NOT NULL,
                    attempts   INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX outbox_channel ON outbox(channel_id, created_at)")

            try db.execute(sql: """
                CREATE TABLE sync_cursor (
                    channel_id        TEXT PRIMARY KEY NOT NULL,
                    oldest_created_at INTEGER,
                    newest_created_at INTEGER,
                    backfill_complete INTEGER NOT NULL DEFAULT 0
                )
                """)

            try db.execute(sql: """
                CREATE TABLE read_state (
                    channel_id   TEXT PRIMARY KEY NOT NULL,
                    last_read_at INTEGER NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE meta (
                    key   TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                )
                """)
        }

        migrator.registerMigration("v1.projections") { db in
            try createProjectionTables(db)
        }

        return migrator
    }

    /// Creates every projection table. Separated from the migration so the
    /// rebuild path can drop and recreate them without touching the migrator.
    static func createProjectionTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE channel (
                id              TEXT PRIMARY KEY NOT NULL,
                name            TEXT,
                about           TEXT,
                picture         TEXT,
                is_private      INTEGER NOT NULL DEFAULT 0,
                source_event_id TEXT NOT NULL,
                updated_at      INTEGER NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE channel_member (
                channel_id TEXT NOT NULL,
                pubkey     TEXT NOT NULL,
                role       TEXT,
                PRIMARY KEY (channel_id, pubkey)
            )
            """)

        try db.execute(sql: """
            CREATE TABLE profile (
                pubkey          TEXT PRIMARY KEY NOT NULL,
                display_name    TEXT,
                picture         TEXT,
                about           TEXT,
                nip05           TEXT,
                lud16           TEXT,
                source_event_id TEXT NOT NULL,
                created_at      INTEGER NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE reaction (
                event_id   TEXT PRIMARY KEY NOT NULL,
                target_id  TEXT NOT NULL,
                pubkey     TEXT NOT NULL,
                emoji      TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX reaction_target ON reaction(target_id)")

        // The deleted event stays in the log. Relays may or may not honour a
        // deletion, and the UI wants to render "message deleted" rather than a
        // hole in the conversation.
        try db.execute(sql: """
            CREATE TABLE deletion (
                event_id   TEXT PRIMARY KEY NOT NULL,
                target_id  TEXT NOT NULL,
                deleted_by TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX deletion_target ON deletion(target_id)")

        // Buzz extension (kind 40003). Absent on a plain NIP-29 relay, in which
        // case messages simply never appear edited.
        try db.execute(sql: """
            CREATE TABLE edit (
                event_id   TEXT PRIMARY KEY NOT NULL,
                target_id  TEXT NOT NULL,
                pubkey     TEXT NOT NULL,
                content    TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX edit_target ON edit(target_id, created_at DESC)")

        // Buzz extension (kind 40002). The renderer falls back to the plain
        // `content` of the target when this is missing.
        try db.execute(sql: """
            CREATE TABLE rich_content (
                target_id TEXT PRIMARY KEY NOT NULL,
                event_id  TEXT NOT NULL,
                payload   TEXT NOT NULL
            )
            """)
    }

    static let projectionTables = [
        "rich_content", "edit", "deletion", "reaction",
        "profile", "channel_member", "channel",
    ]

    static func dropProjectionTables(_ db: Database) throws {
        for table in projectionTables {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
    }
}
