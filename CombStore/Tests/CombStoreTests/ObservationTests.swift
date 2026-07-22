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
