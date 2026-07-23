import CombCore
import Foundation
import Testing
@testable import CombStore

@Suite("Threads", .timeLimit(.minutes(1)))
struct ThreadTests {
    /// A reply to `root`, using the marked tags Buzz writes.
    private func reply(
        _ fixture: Fixture,
        _ content: String,
        to parent: String,
        root: String? = nil,
        broadcast: Bool = false,
        at seconds: Int64
    ) throws -> NostrEvent {
        var tags: [[String]] = [["h", "room-1"]]
        if let root { tags.append(["e", root, "", "root"]) }
        tags.append(["e", parent, "", "reply"])
        if broadcast { tags.append(["broadcast", "1"]) }
        return try fixture.event(.groupChatMessage, content, tags: tags, at: seconds)
    }

    @Test("a reply is kept out of the channel timeline")
    func replyExcludedFromChannel() async throws {
        // The bug this exists to prevent: every reply rendering as its own
        // top-level message, so a threaded conversation reads as a flat pile.
        let store = try EventStore()
        let fixture = try Fixture()

        let opener = try fixture.message("what should the grid be?", at: 1000)
        _ = try await store.ingest([
            opener,
            try reply(fixture, "eight columns", to: opener.id, at: 1100),
            try fixture.message("unrelated", at: 1200),
        ])

        let channel = try store.timeline(channel: "room-1")
        #expect(channel.map(\.content) == ["unrelated", "what should the grid be?"])
    }

    @Test("the opener carries its reply count and newest reply")
    func openerCarriesTally() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        let opener = try fixture.message("what should the grid be?", at: 1000)
        _ = try await store.ingest([
            opener,
            try reply(fixture, "eight", to: opener.id, at: 1100),
            try reply(fixture, "twelve", to: opener.id, root: opener.id, at: 1200),
        ])

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.replyCount == 2)
        #expect(row.lastReplyAt == 1200)
        #expect(row.hasThread)
    }

    @Test("a thread reads opener first, then replies in order")
    func threadOrder() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        let opener = try fixture.message("what should the grid be?", at: 1000)
        _ = try await store.ingest([
            opener,
            try reply(fixture, "eight", to: opener.id, at: 1100),
            try reply(fixture, "twelve", to: opener.id, root: opener.id, at: 1200),
            try fixture.message("unrelated", at: 1300),
        ])

        let thread = try store.thread(root: opener.id)
        #expect(thread.map(\.content) == ["what should the grid be?", "eight", "twelve"])
    }

    @Test("a reply to a reply stays in the same thread")
    func nestedReplyStaysInThread() async throws {
        // Threads must not splinter: answering someone inside a thread keeps the
        // original root, so everything remains one conversation.
        let store = try EventStore()
        let fixture = try Fixture()

        let opener = try fixture.message("opener", at: 1000)
        let first = try reply(fixture, "first", to: opener.id, at: 1100)
        _ = try await store.ingest([
            opener,
            first,
            try reply(fixture, "answering the first", to: first.id, root: opener.id, at: 1200),
        ])

        let thread = try store.thread(root: opener.id)
        #expect(thread.map(\.content) == ["opener", "first", "answering the first"])
        #expect(try store.timeline(channel: "room-1").count == 1)
    }

    @Test("a broadcast reply appears in the channel and in its thread")
    func broadcastReplyAppearsInBoth() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        let opener = try fixture.message("opener", at: 1000)
        _ = try await store.ingest([
            opener,
            try reply(fixture, "everyone should see this", to: opener.id, broadcast: true, at: 1100),
        ])

        let channel = try store.timeline(channel: "room-1")
        #expect(channel.map(\.content) == ["everyone should see this", "opener"])
        #expect(try store.thread(root: opener.id).count == 2)
    }

    @Test("a lone root marker leaves a message in the channel")
    func rootMarkerAloneIsNotAReply() async throws {
        // Matches Buzz: without an explicit `reply` marker the message is not a
        // reply, so hiding it from the channel would lose it entirely.
        let store = try EventStore()
        let fixture = try Fixture()

        let opener = try fixture.message("opener", at: 1000)
        _ = try await store.ingest([
            opener,
            try fixture.event(
                .groupChatMessage,
                "references without replying",
                tags: [["h", "room-1"], ["e", opener.id, "", "root"]],
                at: 1100
            ),
        ])

        #expect(try store.timeline(channel: "room-1").count == 2)
        #expect(try store.thread(root: opener.id).count == 1)
    }

    @Test("a deleted reply stops counting toward the thread")
    func deletedReplyNotCounted() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        let opener = try fixture.message("opener", at: 1000)
        let answer = try reply(fixture, "gone", to: opener.id, at: 1100)
        _ = try await store.ingest([opener, answer])
        #expect(try store.timeline(channel: "room-1").first?.replyCount == 1)

        _ = try await store.ingest([
            try fixture.event(.deletion, "", tags: [["e", answer.id]], at: 1200),
        ])

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.replyCount == 0)
        #expect(!row.hasThread)
    }

    @Test("a queued reply appears in its thread, not in the channel")
    func pendingReplyGoesToThread() async throws {
        // Optimistic send has to respect threading, or a reply flashes into the
        // channel and hops into the thread once the relay answers.
        let store = try EventStore()
        let fixture = try Fixture()

        let opener = try fixture.message("opener", at: 1000)
        _ = try await store.ingest([opener])

        let pending = try reply(fixture, "on its way", to: opener.id, root: opener.id, at: 1100)
        try await store.enqueue(pending, channel: "room-1")

        #expect(try store.timeline(channel: "room-1").map(\.content) == ["opener"])

        let thread = try store.thread(root: opener.id)
        #expect(thread.map(\.content) == ["opener", "on its way"])
        #expect(thread.last?.delivery == .pending)
    }

    @Test("a thread observation fires when a reply lands")
    func observationFires() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        let opener = try fixture.message("opener", at: 1000)
        _ = try await store.ingest([opener])

        var iterator = store
            .observeThread(root: opener.id, me: fixture.pubkey)
            .makeAsyncIterator()
        #expect(try await iterator.next()?.rows.count == 1)

        _ = try await store.ingest([try reply(fixture, "later", to: opener.id, at: 1100)])
        #expect(try await iterator.next()?.rows.count == 2)
    }
}
