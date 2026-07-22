import CombCore
import Foundation
import GRDB
import Testing
@testable import CombStore

// MARK: - Helpers

/// Builds signed events for tests. One key per instance so authorship is stable.
struct Fixture {
    let key: PrivateKey

    init() throws {
        key = try PrivateKey()
    }

    var pubkey: String { key.publicKey.hex }

    func event(
        _ kind: EventKind,
        _ content: String = "",
        tags: [[String]] = [],
        at seconds: Int64 = 1_700_000_000
    ) throws -> NostrEvent {
        try NostrEvent.signed(
            kind: kind,
            content: content,
            tags: tags,
            createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
            with: key
        )
    }

    func message(
        _ content: String,
        in channel: String = "room-1",
        at seconds: Int64 = 1_700_000_000
    ) throws -> NostrEvent {
        try event(.groupChatMessage, content, tags: [["h", channel]], at: seconds)
    }
}

/// Read helpers for tests.
///
/// All of these are `nonisolated` and pull their values out inside the read
/// closure. GRDB's `Row` is not `Sendable` by design (it is a window onto a
/// statement, only valid during the read), so it cannot cross the actor
/// boundary. Returning plain strings and counts is the fix, not a workaround.
extension EventStore {
    /// Dumps every projection table as sorted text, so live and rebuilt
    /// projections can be compared as a whole rather than field by field.
    nonisolated func projectionSnapshot() throws -> String {
        try reader.read { db in
            var out = ""
            for table in Schema.projectionTables.sorted() {
                out += "── \(table)\n"
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table)")
                out += rows.map(\.description).sorted().joined(separator: "\n")
                out += "\n"
            }
            return out
        }
    }

    /// One column of a query, in query order.
    nonisolated func strings(_ sql: String, _ column: String) throws -> [String?] {
        try reader.read { db in
            try Row.fetchAll(db, sql: sql).map { $0[column] as String? }
        }
    }

    nonisolated func rowCount(_ table: String) throws -> Int {
        try reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }
}

// MARK: - Ingest

@Suite("Ingest")
struct IngestTests {
    @Test("stores a valid event")
    func storesValid() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.message("hello")

        let result = try await store.ingest([event])

        #expect(result.inserted == [event.id])
        #expect(result.rejected.isEmpty)
        #expect(try await store.count() == 1)

        let stored = try await store.event(id: event.id)
        // The round trip must reproduce the event exactly, or its id would no
        // longer match its contents.
        #expect(stored == event)
        #expect(stored?.isValid == true)
    }

    @Test("rejects an event whose content was swapped after signing")
    func rejectsTamperedContent() async throws {
        // The attack this defends against: a relay serves an event with altered
        // content but keeps the original id and signature. The signature still
        // verifies over that id, so only recomputing the id from the contents
        // catches it. This is the single most important test in the package.
        let store = try EventStore()
        let fixture = try Fixture()
        let original = try fixture.message("send 1 sat to alice")

        let tampered = NostrEvent(
            id: original.id,
            pubkey: original.pubkey,
            createdAt: original.createdAt,
            kind: original.kind,
            tags: original.tags,
            content: "send 1000 sats to mallory",
            sig: original.sig
        )

        let result = try await store.ingest([tampered])

        #expect(result.inserted.isEmpty)
        #expect(result.rejected == [Rejection(id: original.id, reason: .idMismatch)])
        #expect(try await store.count() == 0)
    }

    @Test("rejects an event signed by someone else")
    func rejectsForgedAuthor() async throws {
        let store = try EventStore()
        let victim = try Fixture()
        let attacker = try Fixture()

        let real = try attacker.message("I am the victim")
        // Same contents and signature, but claiming the victim's identity. The
        // id is recomputed over the swapped pubkey so this fails on id first.
        let forged = NostrEvent(
            id: real.id,
            pubkey: victim.pubkey,
            createdAt: real.createdAt,
            kind: real.kind,
            tags: real.tags,
            content: real.content,
            sig: real.sig
        )

        let result = try await store.ingest([forged])

        #expect(result.inserted.isEmpty)
        #expect(result.rejected.count == 1)
        #expect(try await store.count() == 0)
    }

    @Test("rejects a well-formed event with a corrupted signature")
    func rejectsBadSignature() async throws {
        // Here the id is a correct hash of the contents, so only the signature
        // check can catch it. Exercises the other half of validation.
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.message("hello")

        var corruptedSig = Array(event.sig)
        corruptedSig[0] = corruptedSig[0] == "a" ? "b" : "a"

        let forged = NostrEvent(
            id: event.id,
            pubkey: event.pubkey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: event.content,
            sig: String(corruptedSig)
        )

        let result = try await store.ingest([forged])

        #expect(result.rejected == [Rejection(id: event.id, reason: .badSignature)])
        #expect(try await store.count() == 0)
    }

    @Test("keeps valid events from a batch containing an invalid one")
    func partialBatch() async throws {
        // A relay serving one bad event must not cost us the whole batch.
        let store = try EventStore()
        let fixture = try Fixture()
        let good1 = try fixture.message("first", at: 1000)
        let good2 = try fixture.message("second", at: 2000)
        let bad = NostrEvent(
            id: good1.id, pubkey: good1.pubkey, createdAt: good1.createdAt,
            kind: good1.kind, tags: good1.tags, content: "altered", sig: good1.sig
        )

        let result = try await store.ingest([good1, bad, good2])

        #expect(result.inserted.count == 2)
        #expect(result.rejected.count == 1)
        #expect(try await store.count() == 2)
    }

    @Test("treats a repeat of the same event as a duplicate")
    func deduplicates() async throws {
        // Reconnect overlap and echoes of our own sends both land here, so this
        // has to be free and silent rather than an error.
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.message("hello")

        _ = try await store.ingest([event])
        let second = try await store.ingest([event])

        #expect(second.inserted.isEmpty)
        #expect(second.duplicates == [event.id])
        #expect(try await store.count() == 1)
    }

    @Test("deduplicates within a single batch")
    func deduplicatesWithinBatch() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.message("hello")

        let result = try await store.ingest([event, event, event])

        #expect(result.inserted == [event.id])
        #expect(result.duplicates.count == 2)
        #expect(try await store.count() == 1)
    }

    @Test("diverts ephemeral kinds instead of storing them")
    func divertsEphemeral() async throws {
        // Presence and typing are meaningless within seconds. Storing them would
        // grow the log without bound for data nobody reads.
        let store = try EventStore()
        let fixture = try Fixture()
        let presence = try fixture.event(.buzzPresence, "online", tags: [["h", "room-1"]])
        let typing = try fixture.event(.buzzTyping, "", tags: [["h", "room-1"]])
        let message = try fixture.message("real")

        let result = try await store.ingest([presence, typing, message])

        #expect(result.ephemeral.count == 2)
        #expect(result.inserted == [message.id])
        #expect(try await store.count() == 1)
    }

    @Test("still verifies ephemeral events before handing them on")
    func verifiesEphemeral() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let real = try fixture.event(.buzzPresence, "online")
        let forged = NostrEvent(
            id: real.id, pubkey: real.pubkey, createdAt: real.createdAt,
            kind: real.kind, tags: real.tags, content: "away", sig: real.sig
        )

        let result = try await store.ingest([forged])

        #expect(result.ephemeral.isEmpty)
        #expect(result.rejected.count == 1)
    }

    @Test("indexes single-letter tags only")
    func indexesSingleLetterTags() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.event(
            .groupChatMessage,
            "x",
            tags: [["h", "room-1"], ["p", "abc"], ["client", "comb"], ["relay", "wss://x"]]
        )

        _ = try await store.ingest([event])

        let names = try store.strings("SELECT name FROM event_tag ORDER BY name", "name")
        // Multi-character tags are readable from the event's own tags JSON;
        // indexing them would double write cost for lookups nobody performs.
        #expect(names == ["h", "p"])
    }

    @Test("handles an empty batch")
    func emptyBatch() async throws {
        let store = try EventStore()
        let result = try await store.ingest([])
        #expect(result.isEmpty)
    }
}

// MARK: - Projections

@Suite("Projections")
struct ProjectionTests {
    @Test("projects channel metadata from kind 39000")
    func projectsChannel() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.event(
            .groupMetadata,
            #"{"name":"Design","about":"Where design happens"}"#,
            tags: [["d", "room-1"]]
        )

        _ = try await store.ingest([event])

        #expect(try store.rowCount("channel") == 1)
        #expect(try store.strings("SELECT id FROM channel", "id") == ["room-1"])
        #expect(try store.strings("SELECT name FROM channel", "name") == ["Design"])
        #expect(try store.strings("SELECT about FROM channel", "about") == ["Where design happens"])
    }

    @Test("ignores a stale channel update arriving after a newer one")
    func ignoresStaleChannel() async throws {
        // Addressable events replace by (pubkey, kind, d), and a relay can resend
        // an older one after reconnect. Applying it would revert the name.
        let store = try EventStore()
        let fixture = try Fixture()
        let newer = try fixture.event(
            .groupMetadata, #"{"name":"Current"}"#, tags: [["d", "room-1"]], at: 2000
        )
        let older = try fixture.event(
            .groupMetadata, #"{"name":"Outdated"}"#, tags: [["d", "room-1"]], at: 1000
        )

        _ = try await store.ingest([newer])
        _ = try await store.ingest([older])

        #expect(try store.strings("SELECT name FROM channel", "name") == ["Current"])
    }

    @Test("replaces the member roster rather than merging it")
    func replacesRoster() async throws {
        // Kind 39002 is authoritative and complete. Merging would leave removed
        // members visible forever.
        let store = try EventStore()
        let fixture = try Fixture()
        let first = try fixture.event(
            .groupMembers, "",
            tags: [["d", "room-1"], ["p", "alice"], ["p", "bob"]],
            at: 1000
        )
        let second = try fixture.event(
            .groupMembers, "",
            tags: [["d", "room-1"], ["p", "alice"]],
            at: 2000
        )

        _ = try await store.ingest([first])
        #expect(try store.rowCount("channel_member") == 2)

        _ = try await store.ingest([second])
        #expect(try store.strings("SELECT pubkey FROM channel_member", "pubkey") == ["alice"])
    }

    @Test("projects a profile and prefers display_name")
    func projectsProfile() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.event(
            .metadata,
            #"{"name":"jed","display_name":"Jed Bridges","picture":"https://x/y.png"}"#
        )

        _ = try await store.ingest([event])

        #expect(try store.strings("SELECT display_name FROM profile", "display_name") == ["Jed Bridges"])
        #expect(try store.strings("SELECT picture FROM profile", "picture") == ["https://x/y.png"])
    }

    @Test("falls back to name when display_name is absent or empty")
    func profileFallback() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest([
            try fixture.event(.metadata, #"{"name":"jed","display_name":""}"#),
        ])

        // An empty display_name must not render as a blank name in the UI.
        #expect(try store.strings("SELECT display_name FROM profile", "display_name") == ["jed"])
    }

    @Test("survives malformed profile JSON")
    func malformedProfile() async throws {
        // Relays serve whatever clients wrote. A broken kind 0 must not take
        // down ingest for the whole batch.
        let store = try EventStore()
        let fixture = try Fixture()
        let broken = try fixture.event(.metadata, "not json at all")
        let message = try fixture.message("still fine")

        let result = try await store.ingest([broken, message])

        #expect(result.inserted.count == 2)
        #expect(try store.rowCount("profile") == 1)
    }

    @Test("projects reactions and treats bare + as a like")
    func projectsReactions() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let target = try fixture.message("react to me")
        let plus = try fixture.event(.reaction, "+", tags: [["e", target.id]], at: 1001)
        let emoji = try fixture.event(.reaction, "🐝", tags: [["e", target.id]], at: 1002)

        _ = try await store.ingest([target, plus, emoji])

        #expect(try store.strings("SELECT emoji FROM reaction ORDER BY created_at", "emoji") == ["❤️", "🐝"])
    }

    @Test("records deletions without removing the original")
    func recordsDeletions() async throws {
        // The relay decides whether a deletion is honoured. Keeping the original
        // lets the UI render "message deleted" rather than a hole.
        let store = try EventStore()
        let fixture = try Fixture()
        let target = try fixture.message("delete me")
        let deletion = try fixture.event(.deletion, "", tags: [["e", target.id]], at: 1001)

        _ = try await store.ingest([target, deletion])

        #expect(try store.rowCount("deletion") == 1)
        #expect(try await store.event(id: target.id) != nil)
    }

    @Test("projects Buzz-only edits and rich content")
    func projectsBuzzExtensions() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let target = try fixture.message("origional")
        let edit = try fixture.event(.buzzEdit, "original", tags: [["e", target.id]], at: 1001)
        let rich = try fixture.event(
            .buzzRichContent, #"{"blocks":[]}"#, tags: [["e", target.id]], at: 1002
        )

        _ = try await store.ingest([target, edit, rich])

        #expect(try store.rowCount("edit") == 1)
        #expect(try store.rowCount("rich_content") == 1)
    }

    @Test("needs no projection for plain messages")
    func messagesNeedNoProjection() async throws {
        // Kind 9 is read straight from the log. If this ever changes, the
        // timeline query and the projection would need to agree.
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest([try fixture.message("hello")])

        #expect(try store.projectionSnapshot().contains("room-1") == false)
    }
}

// MARK: - Rebuild

@Suite("Projection rebuild")
struct RebuildTests {
    /// A mixed history touching every projector, deliberately out of order so
    /// replay ordering is actually exercised.
    private func history(_ fixture: Fixture) throws -> [NostrEvent] {
        let target = try fixture.message("react and edit me", at: 1000)
        return [
            try fixture.event(.groupMetadata, #"{"name":"Old"}"#, tags: [["d", "room-1"]], at: 900),
            try fixture.event(.groupMetadata, #"{"name":"New"}"#, tags: [["d", "room-1"]], at: 1500),
            try fixture.event(
                .groupMembers, "", tags: [["d", "room-1"], ["p", "alice"], ["p", "bob"]], at: 1100
            ),
            try fixture.event(.groupMembers, "", tags: [["d", "room-1"], ["p", "alice"]], at: 1600),
            try fixture.event(.metadata, #"{"display_name":"Old Name"}"#, at: 950),
            try fixture.event(.metadata, #"{"display_name":"New Name"}"#, at: 1700),
            target,
            try fixture.event(.reaction, "🐝", tags: [["e", target.id]], at: 1200),
            try fixture.event(.buzzEdit, "edited", tags: [["e", target.id]], at: 1300),
            try fixture.event(.buzzRichContent, #"{"b":1}"#, tags: [["e", target.id]], at: 1400),
            try fixture.event(.deletion, "", tags: [["e", target.id]], at: 1800),
        ]
    }

    @Test("replaying the log reproduces the live projections exactly")
    func rebuildMatchesLive() async throws {
        // This is what makes the append-only design pay off: a projection bug is
        // fixed by bumping a version and replaying, with no refetch from a relay
        // that may no longer hold the history. If the two paths can diverge, that
        // guarantee is worthless.
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest(try history(fixture))
        let live = try store.projectionSnapshot()

        try await store.rebuildProjections()
        let rebuilt = try store.projectionSnapshot()

        #expect(live == rebuilt)
    }

    @Test("rebuild settles on newest-wins regardless of arrival order")
    func rebuildRespectsOrdering() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        // Shuffled arrival: the relay gives no ordering guarantee across a batch.
        _ = try await store.ingest(try history(fixture).shuffled())
        try await store.rebuildProjections()

        #expect(try store.strings("SELECT name FROM channel", "name") == ["New"])
        #expect(try store.strings("SELECT display_name FROM profile", "display_name") == ["New Name"])
        #expect(try store.rowCount("channel_member") == 1)
    }

    @Test("rebuild is idempotent")
    func rebuildIsIdempotent() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        _ = try await store.ingest(try history(fixture))

        try await store.rebuildProjections()
        let first = try store.projectionSnapshot()
        try await store.rebuildProjections()
        let second = try store.projectionSnapshot()

        #expect(first == second)
    }

    @Test("rebuild leaves the log untouched")
    func rebuildPreservesLog() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let events = try history(fixture)
        _ = try await store.ingest(events)

        let before = try await store.count()
        try await store.rebuildProjections()

        #expect(try await store.count() == before)
        for event in events {
            #expect(try await store.event(id: event.id) == event)
        }
    }
}

// MARK: - Scale

@Suite("Scale")
struct ScaleTests {
    @Test("holds dedupe and ordering across a large history", .timeLimit(.minutes(2)))
    func largeHistory() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        // 2,000 rather than the 10,000 in the plan: every event costs a real
        // Schnorr verification on both the fixture and the ingest side, and this
        // suite has to stay fast enough to run on every save.
        let events = try (0..<2000).map { index in
            try fixture.message("message \(index)", at: 1_700_000_000 + Int64(index))
        }

        let first = try await store.ingest(events)
        #expect(first.inserted.count == 2000)
        #expect(try await store.count() == 2000)

        // Replaying the same history, as a reconnect would.
        let second = try await store.ingest(events)
        #expect(second.inserted.isEmpty)
        #expect(second.duplicates.count == 2000)
        #expect(try await store.count() == 2000)
    }
}
