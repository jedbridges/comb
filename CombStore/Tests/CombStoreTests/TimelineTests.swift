import CombCore
import Foundation
import Testing
@testable import CombStore

@Suite("Timeline")
struct TimelineTests {
    @Test("returns messages newest first")
    func newestFirst() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest([
            try fixture.message("first", at: 1000),
            try fixture.message("second", at: 2000),
            try fixture.message("third", at: 3000),
        ])

        let rows = try store.timeline(channel: "room-1")
        #expect(rows.map(\.content) == ["third", "second", "first"])
    }

    @Test("scopes to one channel")
    func scopesToChannel() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest([
            try fixture.message("in room 1", in: "room-1", at: 1000),
            try fixture.message("in room 2", in: "room-2", at: 2000),
        ])

        #expect(try store.timeline(channel: "room-1").map(\.content) == ["in room 1"])
        #expect(try store.timeline(channel: "room-2").map(\.content) == ["in room 2"])
    }

    @Test("excludes non-message kinds")
    func excludesOtherKinds() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let message = try fixture.message("real message", at: 1000)

        _ = try await store.ingest([
            message,
            try fixture.event(.reaction, "🐝", tags: [["h", "room-1"], ["e", message.id]], at: 1001),
            try fixture.event(.metadata, #"{"name":"x"}"#, tags: [["h", "room-1"]], at: 1002),
        ])

        #expect(try store.timeline(channel: "room-1").count == 1)
    }

    // MARK: - Pagination

    @Test("paginates without skipping or repeating")
    func paginates() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        let events = try (0..<25).map {
            try fixture.message("m\($0)", at: 1000 + Int64($0))
        }
        _ = try await store.ingest(events)

        var seen: [String] = []
        var cursor: TimelineCursor?
        while true {
            let page = try store.timeline(channel: "room-1", before: cursor, limit: 10)
            if page.isEmpty { break }
            seen.append(contentsOf: page.map(\.content))
            cursor = TimelineCursor(row: page.last!)
        }

        #expect(seen.count == 25)
        #expect(Set(seen).count == 25, "no message may appear on two pages")
        #expect(seen.first == "m24")
        #expect(seen.last == "m0")
    }

    @Test("paginates correctly through same-second events")
    func paginatesSameSecond() async throws {
        // The reason the cursor is (created_at, id) and not created_at alone.
        // Relays routinely deliver many events sharing a timestamp; a
        // timestamp-only cursor either skips the rest of that second or serves
        // them again forever.
        let store = try EventStore()
        let fixture = try Fixture()

        let events = try (0..<20).map { try fixture.message("same-\($0)", at: 1000) }
        _ = try await store.ingest(events)

        var seen: [String] = []
        var cursor: TimelineCursor?
        for _ in 0..<10 {
            let page = try store.timeline(channel: "room-1", before: cursor, limit: 5)
            if page.isEmpty { break }
            seen.append(contentsOf: page.map(\.id))
            cursor = TimelineCursor(row: page.last!)
        }

        #expect(seen.count == 20)
        #expect(Set(seen).count == 20)
    }

    @Test("a cursor stays stable when older events arrive underneath it")
    func cursorStableUnderInsert() async throws {
        // Backfill inserts older history while the user is paging. The cursor is
        // a value, not an offset, so rows do not shift under it.
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest(try (10..<20).map {
            try fixture.message("m\($0)", at: 1000 + Int64($0))
        })

        let firstPage = try store.timeline(channel: "room-1", limit: 5)
        let cursor = TimelineCursor(row: firstPage.last!)

        _ = try await store.ingest(try (0..<10).map {
            try fixture.message("m\($0)", at: 1000 + Int64($0))
        })

        let secondPage = try store.timeline(channel: "room-1", before: cursor, limit: 5)
        #expect(Set(firstPage.map(\.id)).isDisjoint(with: secondPage.map(\.id)))
        #expect(secondPage.map(\.content) == ["m14", "m13", "m12", "m11", "m10"])
    }

    // MARK: - Content resolution

    @Test("shows the newest edit in place of the original")
    func appliesEdits() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let message = try fixture.message("teh typo", at: 1000)

        _ = try await store.ingest([
            message,
            try fixture.event(.buzzEdit, "the typo", tags: [["e", message.id]], at: 1001),
            try fixture.event(.buzzEdit, "no typo", tags: [["e", message.id]], at: 1002),
        ])

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.content == "no typo")
        #expect(row.isEdited)
    }

    @Test("falls back to the original when no edit exists")
    func noEditFallback() async throws {
        // A plain NIP-29 relay has no kind 40003 at all, and messages must read
        // normally there.
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest([try fixture.message("as written", at: 1000)])

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.content == "as written")
        #expect(!row.isEdited)
    }

    @Test("flags deleted messages but keeps them in the timeline")
    func flagsDeleted() async throws {
        // The UI renders "message deleted" rather than a hole, so the row has to
        // survive the deletion.
        let store = try EventStore()
        let fixture = try Fixture()
        let message = try fixture.message("delete me", at: 1000)

        _ = try await store.ingest([
            message,
            try fixture.event(.deletion, "", tags: [["e", message.id]], at: 1001),
        ])

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.isDeleted)
    }

    @Test("joins author profile details")
    func joinsProfile() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest([
            try fixture.event(.metadata, #"{"display_name":"Jed","picture":"https://x/y"}"#, at: 900),
            try fixture.message("hello", at: 1000),
        ])

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.authorName == "Jed")
        #expect(row.displayName == "Jed")
        #expect(row.authorPicture == "https://x/y")
    }

    @Test("falls back to a short key when no profile is known")
    func fallsBackToShortKey() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest([try fixture.message("hello", at: 1000)])

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.authorName == nil)
        // Not an npub: onboarding's whole premise is that a first-time user
        // never has to reason about keys.
        #expect(row.displayName == String(fixture.pubkey.prefix(8)))
    }

    @Test("resolves NIP-10 reply targets")
    func resolvesReplies() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let root = try fixture.message("root", at: 1000)
        let reply = try fixture.event(
            .groupChatMessage,
            "reply",
            tags: [["h", "room-1"], ["e", root.id, "", "reply"]],
            at: 1001
        )

        _ = try await store.ingest([root, reply])

        let rows = try store.timeline(channel: "room-1")
        #expect(rows[0].replyTo == root.id)
        #expect(rows[1].replyTo == nil)
    }

    // MARK: - Reactions

    @Test("aggregates reactions per message")
    func aggregatesReactions() async throws {
        let store = try EventStore()
        let author = try Fixture()
        let other = try Fixture()
        let message = try author.message("react to me", at: 1000)

        _ = try await store.ingest([
            message,
            try author.event(.reaction, "🐝", tags: [["e", message.id]], at: 1001),
            try other.event(.reaction, "🐝", tags: [["e", message.id]], at: 1002),
            try other.event(.reaction, "🔥", tags: [["e", message.id]], at: 1003),
        ])

        let summaries = try #require(
            try store.reactions(for: [message.id], me: author.pubkey)[message.id]
        )

        #expect(summaries.count == 2)
        // Ordered by count so the most popular reaction reads first.
        #expect(summaries[0].emoji == "🐝")
        #expect(summaries[0].count == 2)
        #expect(summaries[0].includesMe)
        #expect(summaries[1].emoji == "🔥")
        #expect(!summaries[1].includesMe)
    }

    @Test("returns nothing for messages with no reactions")
    func noReactions() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let message = try fixture.message("quiet", at: 1000)
        _ = try await store.ingest([message])

        #expect(try store.reactions(for: [message.id], me: fixture.pubkey).isEmpty)
        #expect(try store.reactions(for: [], me: nil).isEmpty)
    }
}

// MARK: - Outbox

@Suite("Outbox")
struct OutboxTests {
    @Test("a queued message appears in the timeline immediately")
    func pendingAppearsInTimeline() async throws {
        // The point of optimistic send: the message is on screen before the
        // relay has heard of it.
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.message("optimistic", at: 1000)

        try await store.enqueue(event, channel: "room-1")

        let rows = try store.timeline(channel: "room-1")
        #expect(rows.count == 1)
        #expect(rows[0].content == "optimistic")
        #expect(rows[0].delivery == .pending)
        #expect(rows[0].id == event.id)
    }

    @Test("a queued message sorts by time among sent ones")
    func pendingSortsInPlace() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest([
            try fixture.message("older", at: 1000),
            try fixture.message("newer", at: 3000),
        ])
        try await store.enqueue(try fixture.message("mine", at: 2000), channel: "room-1")

        // Unioning in SQL rather than keeping a separate pending list is what
        // makes this work without the two views disagreeing about order.
        #expect(try store.timeline(channel: "room-1").map(\.content) == ["newer", "mine", "older"])
    }

    @Test("confirming moves a message from pending to sent with the same identity")
    func confirmKeepsIdentity() async throws {
        // The id is a hash of the contents, so the queued row and the log row
        // are the same object as far as the UI is concerned. SwiftUI animates
        // the state change instead of replacing the row.
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.message("sent", at: 1000)

        try await store.enqueue(event, channel: "room-1")
        let before = try #require(try store.timeline(channel: "room-1").first)

        try await store.confirmSent(event)
        let after = try #require(try store.timeline(channel: "room-1").first)

        #expect(before.id == after.id)
        #expect(before.delivery == .pending)
        #expect(after.delivery == .sent)
        #expect(try store.timeline(channel: "room-1").count == 1)
        #expect(try store.pendingSendCount() == 0)
        #expect(try await store.count() == 1)
    }

    @Test("an echo arriving before the OK does not duplicate the message")
    func echoBeforeAck() async throws {
        // The live subscription frequently returns our own message before the
        // OK does. Both paths key on the same id, so the second one is a no-op.
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.message("echoed", at: 1000)

        try await store.enqueue(event, channel: "room-1")
        _ = try await store.ingest([event])       // echo lands first
        try await store.confirmSent(event)        // OK arrives after

        let rows = try store.timeline(channel: "room-1")
        #expect(rows.count == 1)
        #expect(rows[0].delivery == .sent)
        #expect(try store.pendingSendCount() == 0)
    }

    @Test("a rejected message stays visible with its reason")
    func failedStaysVisible() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.message("rejected", at: 1000)

        try await store.enqueue(event, channel: "room-1")
        try await store.markSending(event.id)
        try await store.markFailed(event.id, error: "restricted: not a member")

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.delivery == .failed("restricted: not a member"))
        // Losing the text the user typed would be the worst possible outcome.
        #expect(row.content == "rejected")
    }

    @Test("queued sends survive for retry, including ones left mid-flight")
    func pendingSurviveRestart() async throws {
        // A row still marked `sending` means the app stopped between handing the
        // message over and hearing back. Resending is safe because the relay
        // deduplicates by id; dropping it would silently lose a message the user
        // believes they sent.
        let store = try EventStore()
        let fixture = try Fixture()
        let queued = try fixture.message("queued", at: 1000)
        let inFlight = try fixture.message("in flight", at: 1001)

        try await store.enqueue(queued, channel: "room-1")
        try await store.enqueue(inFlight, channel: "room-1")
        try await store.markSending(inFlight.id)

        let pending = try store.pendingSends()
        #expect(pending.count == 2)
        #expect(pending.map(\.event.content) == ["queued", "in flight"])
        // The full signed event round trips, so a retry needs no re-signing.
        #expect(pending[0].event == queued)
        #expect(pending[1].state == .sending)
        #expect(pending[1].attempts == 1)
    }

    @Test("filters queued sends by channel")
    func filtersByChannel() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        try await store.enqueue(try fixture.message("a", in: "room-1", at: 1000), channel: "room-1")
        try await store.enqueue(try fixture.message("b", in: "room-2", at: 1001), channel: "room-2")

        #expect(try store.pendingSends(channel: "room-1").count == 1)
        #expect(try store.pendingSends().count == 2)
    }

    @Test("discarding removes a queued message entirely")
    func discard() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.message("cancelled", at: 1000)

        try await store.enqueue(event, channel: "room-1")
        try await store.discard(event.id)

        #expect(try store.timeline(channel: "room-1").isEmpty)
        #expect(try store.pendingSendCount() == 0)
    }

    @Test("refuses to confirm an event that fails verification")
    func refusesInvalidConfirm() async throws {
        // Our own events go through the same verification as anything from a
        // relay. An exception here would put an unverified path into the log,
        // and the value of one choke point is that there are no exceptions.
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.message("real", at: 1000)
        let tampered = NostrEvent(
            id: event.id, pubkey: event.pubkey, createdAt: event.createdAt,
            kind: event.kind, tags: event.tags, content: "altered", sig: event.sig
        )

        try await store.enqueue(event, channel: "room-1")

        await #expect(throws: OutboxError.invalidEvent(event.id)) {
            try await store.confirmSent(tampered)
        }
        #expect(try await store.count() == 0)
    }

    @Test("enqueueing the same message twice is a no-op")
    func enqueueIsIdempotent() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let event = try fixture.message("once", at: 1000)

        try await store.enqueue(event, channel: "room-1")
        try await store.enqueue(event, channel: "room-1")

        #expect(try store.pendingSendCount() == 1)
        #expect(try store.timeline(channel: "room-1").count == 1)
    }
}
