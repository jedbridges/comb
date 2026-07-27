import CombCore
import Foundation
import Testing
@testable import CombStore

@Suite("Activity")
struct ActivityTests {
    /// A channel plus the viewer's own message in it, which is what replies and
    /// reactions need something to point at.
    private func room(
        _ store: EventStore,
        me: Fixture,
        author: Fixture
    ) async throws -> NostrEvent {
        let mine = try me.message("something I said", at: 1000)
        _ = try await store.ingest([
            try author.event(
                .groupMetadata, #"{"name":"General"}"#, tags: [["d", "room-1"]], at: 900
            ),
            mine,
        ])
        return mine
    }

    @Test("a message that names you arrives as a mention")
    func mention() async throws {
        let store = try EventStore()
        let me = try Fixture()
        let author = try Fixture(name: "Ada")
        _ = try await room(store, me: me, author: author)

        _ = try await store.ingest([
            try author.event(
                .groupChatMessage, "hey you",
                tags: [["h", "room-1"], ["p", me.pubkey]], at: 1100
            ),
        ])

        let items = try store.activity(for: me.pubkey)
        #expect(items.count == 1)
        #expect(items.first?.kind == .mention)
        #expect(items.first?.text == "hey you")
        #expect(items.first?.channelName == "General")
    }

    @Test("a reply to your message arrives as a reply")
    func reply() async throws {
        let store = try EventStore()
        let me = try Fixture()
        let author = try Fixture(name: "Ada")
        let mine = try await room(store, me: me, author: author)

        _ = try await store.ingest([
            try author.event(
                .groupChatMessage, "good point",
                tags: [["h", "room-1"], ["e", mine.id, "", "reply"]], at: 1100
            ),
        ])

        let items = try store.activity(for: me.pubkey)
        #expect(items.count == 1)
        #expect(items.first?.kind == .reply)
        // Tapping opens the message that was answered, not the answer.
        #expect(items.first?.targetID == mine.id)
    }

    @Test("a reply that also tags you is only counted once")
    func replyIsNotAlsoAMention() async throws {
        // Nostr replies conventionally p-tag the author they answer, so without
        // the exclusion nearly every reply would show up twice.
        let store = try EventStore()
        let me = try Fixture()
        let author = try Fixture(name: "Ada")
        let mine = try await room(store, me: me, author: author)

        _ = try await store.ingest([
            try author.event(
                .groupChatMessage, "good point",
                tags: [
                    ["h", "room-1"],
                    ["e", mine.id, "", "reply"],
                    ["p", me.pubkey],
                ],
                at: 1100
            ),
        ])

        let items = try store.activity(for: me.pubkey)
        #expect(items.count == 1)
        #expect(items.first?.kind == .reply)
    }

    @Test("a reaction to your message arrives with its emoji")
    func reaction() async throws {
        let store = try EventStore()
        let me = try Fixture()
        let author = try Fixture(name: "Ada")
        let mine = try await room(store, me: me, author: author)

        _ = try await store.ingest([
            try author.event(.reaction, "🔥", tags: [["e", mine.id]], at: 1100),
        ])

        let items = try store.activity(for: me.pubkey)
        #expect(items.count == 1)
        #expect(items.first?.kind == .reaction)
        #expect(items.first?.text == "🔥")
        #expect(items.first?.targetID == mine.id)
    }

    @Test("a custom emoji reaction carries its image")
    func customEmojiReaction() async throws {
        let store = try EventStore()
        let me = try Fixture()
        let author = try Fixture(name: "Ada")
        let mine = try await room(store, me: me, author: author)

        _ = try await store.ingest([
            try author.event(
                .reaction, ":party:",
                tags: [
                    ["e", mine.id],
                    ["emoji", "party", "https://cdn.example/party.png"],
                ],
                at: 1100
            ),
        ])

        let items = try store.activity(for: me.pubkey)
        #expect(items.first?.emojiURL == "https://cdn.example/party.png")
    }

    @Test("your own activity is not reported back to you")
    func ignoresSelf() async throws {
        let store = try EventStore()
        let me = try Fixture()
        let author = try Fixture(name: "Ada")
        let mine = try await room(store, me: me, author: author)

        _ = try await store.ingest([
            // Reacting to and replying to yourself is not news.
            try me.event(.reaction, "🔥", tags: [["e", mine.id]], at: 1100),
            try me.event(
                .groupChatMessage, "and another thing",
                tags: [["h", "room-1"], ["e", mine.id, "", "reply"]], at: 1200
            ),
        ])

        #expect(try store.activity(for: me.pubkey).isEmpty)
    }

    @Test("a withdrawn reaction leaves")
    func withdrawnReaction() async throws {
        let store = try EventStore()
        let me = try Fixture()
        let author = try Fixture(name: "Ada")
        let mine = try await room(store, me: me, author: author)

        let reaction = try author.event(.reaction, "🔥", tags: [["e", mine.id]], at: 1100)
        _ = try await store.ingest([reaction])
        #expect(try store.activity(for: me.pubkey).count == 1)

        _ = try await store.ingest([
            try author.event(.deletion, "", tags: [["e", reaction.id]], at: 1200),
        ])
        #expect(try store.activity(for: me.pubkey).isEmpty)
    }

    @Test("a blocked person's activity is hidden")
    func blocked() async throws {
        let store = try EventStore()
        let me = try Fixture()
        let author = try Fixture(name: "Ada")
        let mine = try await room(store, me: me, author: author)

        _ = try await store.ingest([
            try author.event(.reaction, "🔥", tags: [["e", mine.id]], at: 1100),
        ])
        #expect(try store.activity(for: me.pubkey).count == 1)

        try await store.block(pubkey: author.pubkey)
        #expect(try store.activity(for: me.pubkey).isEmpty)
    }

    @Test("newest first, across all three kinds")
    func ordering() async throws {
        let store = try EventStore()
        let me = try Fixture()
        let author = try Fixture(name: "Ada")
        let mine = try await room(store, me: me, author: author)

        _ = try await store.ingest([
            try author.event(
                .groupChatMessage, "naming you",
                tags: [["h", "room-1"], ["p", me.pubkey]], at: 1100
            ),
            try author.event(.reaction, "🔥", tags: [["e", mine.id]], at: 1200),
            try author.event(
                .groupChatMessage, "answering you",
                tags: [["h", "room-1"], ["e", mine.id, "", "reply"]], at: 1300
            ),
        ])

        let items = try store.activity(for: me.pubkey)
        #expect(items.map(\.kind) == [.reply, .reaction, .mention])
    }
}
