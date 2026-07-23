import CombCore
import Foundation
import Testing
@testable import CombStore

@Suite("Channel summaries", .timeLimit(.minutes(1)))
struct ChannelSummaryTests {
    private func seed(_ store: EventStore, _ fixture: Fixture) async throws {
        _ = try await store.ingest([
            try fixture.event(.groupMetadata, #"{"name":"General"}"#, tags: [["d", "general"]], at: 900),
            try fixture.event(.groupMetadata, #"{"name":"Silent"}"#, tags: [["d", "silent"]], at: 901),
            try fixture.event(
                .groupMembers, "",
                tags: [["d", "general"], ["p", "a"], ["p", "b"], ["p", "c"]],
                at: 902
            ),
            try fixture.event(.metadata, #"{"display_name":"Jed"}"#, at: 903),
            try fixture.message("older", in: "general", at: 1000),
            try fixture.message("latest", in: "general", at: 2000),
        ])
    }

    @Test("joins metadata, members, and the latest message")
    func joins() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        try await seed(store, fixture)

        let summaries = try store.channelSummaries()
        #expect(summaries.count == 2)

        let general = try #require(summaries.first)
        #expect(general.name == "General")
        #expect(general.memberCount == 3)
        #expect(general.lastMessage == "latest")
        #expect(general.lastAuthor == "Jed")
        #expect(general.lastActivity == 2000)
    }

    @Test("sorts active channels first, silent ones after by name")
    func sorts() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        try await seed(store, fixture)

        let names = try store.channelSummaries().map(\.name)
        #expect(names == ["General", "Silent"])
    }

    @Test("does not surface a deleted message as the preview")
    func skipsDeletedPreview() async throws {
        // The channel list is the most public surface in the app; a deleted
        // message must not linger there after it is gone from the timeline.
        let store = try EventStore()
        let fixture = try Fixture()
        try await seed(store, fixture)

        let latest = try #require(
            try store.timeline(channel: "general", limit: 1).first
        )
        _ = try await store.ingest([
            try fixture.event(.deletion, "", tags: [["e", latest.id]], at: 2001),
        ])

        let general = try #require(try store.channelSummaries().first)
        #expect(general.lastMessage == "older")
    }
}

@Suite("Observation", .timeLimit(.minutes(1)))
struct ObservationTests {
    @Test("emits a fresh timeline snapshot when a message arrives")
    func emitsOnInsert() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        _ = try await store.ingest([try fixture.message("first", at: 1000)])

        var iterator = store
            .observeTimeline(channel: "room-1", limit: 50, me: fixture.pubkey)
            .makeAsyncIterator()

        let initial = try #require(try await iterator.next())
        #expect(initial.rows.map(\.content) == ["first"])

        _ = try await store.ingest([try fixture.message("second", at: 2000)])

        let updated = try #require(try await iterator.next())
        #expect(updated.rows.map(\.content) == ["second", "first"])
    }

    @Test("a reaction re-fires the same observation")
    func emitsOnReaction() async throws {
        // The tracking closure reads both the timeline and the reaction table,
        // so a reaction alone must produce a new snapshot even though no
        // message changed.
        let store = try EventStore()
        let fixture = try Fixture()
        let message = try fixture.message("react to me", at: 1000)
        _ = try await store.ingest([message])

        var iterator = store
            .observeTimeline(channel: "room-1", limit: 50, me: fixture.pubkey)
            .makeAsyncIterator()
        _ = try await iterator.next()

        _ = try await store.ingest([
            try fixture.event(.reaction, "🐝", tags: [["e", message.id]], at: 1001),
        ])

        let updated = try #require(try await iterator.next())
        #expect(updated.reactions[message.id]?.first?.emoji == "🐝")
    }

    @Test("an outbox enqueue fires the observation")
    func emitsOnEnqueue() async throws {
        // Optimistic send depends on this: the pending message must appear the
        // instant it is queued, through the same observation as everything else.
        let store = try EventStore()
        let fixture = try Fixture()
        _ = try await store.ingest([try fixture.message("sent", at: 1000)])

        var iterator = store
            .observeTimeline(channel: "room-1", limit: 50, me: fixture.pubkey)
            .makeAsyncIterator()
        _ = try await iterator.next()

        try await store.enqueue(try fixture.message("pending", at: 2000), channel: "room-1")

        let updated = try #require(try await iterator.next())
        #expect(updated.rows.first?.delivery == .pending)
    }

    @Test("emits channel summaries when a channel appears")
    func emitsChannelList() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        var iterator = store.observeChannelSummaries().makeAsyncIterator()
        let initial = try #require(try await iterator.next())
        #expect(initial.isEmpty)

        _ = try await store.ingest([
            try fixture.event(.groupMetadata, #"{"name":"New Room"}"#, tags: [["d", "r1"]], at: 1000),
        ])

        let updated = try #require(try await iterator.next())
        #expect(updated.map(\.name) == ["New Room"])
    }
}

@Suite("Unread", .timeLimit(.minutes(1)))
struct UnreadTests {
    private func seed(_ store: EventStore, _ fixture: Fixture) async throws {
        _ = try await store.ingest([
            try fixture.event(.groupMetadata, #"{"name":"General"}"#, tags: [["d", "room-1"]], at: 900),
        ])
    }

    @Test("counts messages newer than the last read")
    func countsUnread() async throws {
        let store = try EventStore()
        let other = try Fixture()
        try await seed(store, other)

        _ = try await store.ingest([
            try other.message("one", at: 1000),
            try other.message("two", at: 2000),
            try other.message("three", at: 3000),
        ])

        let me = try Fixture()
        #expect(try store.channelSummaries(me: me.pubkey).first?.unreadCount == 3)

        try await store.markRead(channel: "room-1")
        #expect(try store.channelSummaries(me: me.pubkey).first?.unreadCount == 0)

        _ = try await store.ingest([try other.message("four", at: 4000)])
        #expect(try store.channelSummaries(me: me.pubkey).first?.unreadCount == 1)
    }

    @Test("your own messages never count as unread")
    func ownMessagesExcluded() async throws {
        // A badge for something you just sent would be nonsense.
        let store = try EventStore()
        let me = try Fixture()
        try await seed(store, me)

        _ = try await store.ingest([
            try me.message("mine", at: 1000),
            try me.message("also mine", at: 2000),
        ])

        #expect(try store.channelSummaries(me: me.pubkey).first?.unreadCount == 0)
    }

    @Test("deleted messages do not keep a channel unread")
    func deletedExcluded() async throws {
        let store = try EventStore()
        let other = try Fixture()
        try await seed(store, other)

        let message = try other.message("delete me", at: 1000)
        _ = try await store.ingest([message])
        #expect(try store.channelSummaries(me: "").first?.unreadCount == 1)

        _ = try await store.ingest([
            try other.event(.deletion, "", tags: [["e", message.id]], at: 1001),
        ])
        #expect(try store.channelSummaries(me: "").first?.unreadCount == 0)
    }

    @Test("backfilled history cannot mark a read channel unread again")
    func backfillDoesNotUnread() async throws {
        // Read state is a timestamp, so older history arriving later is already
        // behind the mark. An id-set approach would light the channel back up.
        let store = try EventStore()
        let other = try Fixture()
        try await seed(store, other)

        _ = try await store.ingest([try other.message("recent", at: 5000)])
        try await store.markRead(channel: "room-1")

        _ = try await store.ingest([
            try other.message("old", at: 1000),
            try other.message("older", at: 500),
        ])
        #expect(try store.channelSummaries(me: "").first?.unreadCount == 0)
    }

    @Test("marking read never moves backwards")
    func markReadMonotonic() async throws {
        let store = try EventStore()
        let other = try Fixture()
        try await seed(store, other)

        _ = try await store.ingest([try other.message("newest", at: 9000)])
        try await store.markRead(channel: "room-1")

        // A stale mark from a slow view must not reopen the unread state.
        try await store.markRead(channel: "room-1")
        #expect(try store.channelSummaries(me: "").first?.unreadCount == 0)
    }

    @Test("observation re-fires when a channel is marked read")
    func observationFires() async throws {
        let store = try EventStore()
        let other = try Fixture()
        try await seed(store, other)
        _ = try await store.ingest([try other.message("unread", at: 1000)])

        var iterator = store.observeChannelSummaries(me: "").makeAsyncIterator()
        #expect(try await iterator.next()?.first?.unreadCount == 1)

        try await store.markRead(channel: "room-1")
        #expect(try await iterator.next()?.first?.unreadCount == 0)
    }
}
