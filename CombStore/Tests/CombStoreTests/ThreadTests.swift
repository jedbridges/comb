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

@Suite("Message text")
struct MessageTextTests {
    @Test("strips the media markdown Buzz appends")
    func stripsMediaMarkdown() {
        let body = "might embrace the playdough aesthetic\n![image](https://relay.example/media/abc.png)"
        #expect(MessageText.withoutMediaMarkdown(body) == "might embrace the playdough aesthetic")
    }

    @Test("a picture with no caption leaves an empty body")
    func pictureOnly() {
        // Correct rather than a bug: the picture is the message, and the row
        // renders the attachment instead of an empty bubble.
        let body = "\n![image](https://relay.example/media/abc.png)"
        #expect(MessageText.withoutMediaMarkdown(body).isEmpty)
    }

    @Test("strips several attachments")
    func severalAttachments() {
        let body = "two shots![image](https://r.example/a.png)![image](https://r.example/b.png)"
        #expect(MessageText.withoutMediaMarkdown(body) == "two shots")
    }

    @Test("leaves a person's own markdown alone")
    func leavesHumanMarkdown() {
        // Only `image` and `video` are machine-written by Buzz. Anything else
        // is something a person typed and must survive.
        let body = "see ![diagram](https://example.com/d.png)"
        #expect(MessageText.withoutMediaMarkdown(body) == body)
    }

    @Test("leaves ordinary text untouched")
    func leavesPlainText() {
        #expect(MessageText.withoutMediaMarkdown("no media here") == "no media here")
        #expect(MessageText.withoutMediaMarkdown("") == "")
    }

    @Test("unwraps a Markdown autolink")
    func unwrapsAutolink() {
        // Buzz's composer writes these and its own client hides them, so a
        // link arriving in brackets is markup we failed to strip, not
        // punctuation the author typed.
        let body = "This vid explains it <https://www.youtube.com/watch?v=abc>"
        #expect(
            MessageText.display(body)
                == "This vid explains it https://www.youtube.com/watch?v=abc"
        )
    }

    @Test("unwraps several autolinks in one message")
    func unwrapsSeveralAutolinks() {
        let body = "<https://a.example/x> and <http://b.example/y>"
        #expect(MessageText.display(body) == "https://a.example/x and http://b.example/y")
    }

    @Test("leaves angle brackets that are not autolinks")
    func leavesOrdinaryAngleBrackets() {
        // The regex is narrow so ordinary writing survives: comparisons, a
        // stray emoticon, and a bracketed address with no scheme.
        #expect(MessageText.display("a < b and c > d") == "a < b and c > d")
        #expect(MessageText.display("<3") == "<3")
        #expect(MessageText.display("<not a url>") == "<not a url>")
        #expect(MessageText.display("< https://spaced.example >") == "< https://spaced.example >")
    }

    @Test("strips media markdown and unwraps autolinks together")
    func displayDoesBoth() {
        let body = "shot <https://example.com/a>\n![image](https://relay.example/m/1.png)"
        #expect(MessageText.display(body) == "shot https://example.com/a")
    }
}

@Suite("Ownership of edits and deletions", .timeLimit(.minutes(1)))
struct OwnershipTests {
    // Hosted Buzz enforces these rules server-side. These tests exist because
    // Comb also speaks to plain NIP-29 relays, where the only thing standing
    // between a hostile member and everyone else's message history is the
    // read-time predicates under test here.

    @Test("a foreign edit does not rewrite someone else's message")
    func foreignEditIgnored() async throws {
        let store = try EventStore()
        let author = try Fixture()
        let attacker = try Fixture()

        let message = try author.message("the original", at: 1000)
        _ = try await store.ingest([
            message,
            try attacker.event(
                .buzzEdit, "rewritten by someone else",
                tags: [["h", "room-1"], ["e", message.id]], at: 1100
            ),
        ])

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.content == "the original")
        #expect(!row.isEdited)
    }

    @Test("the author's own edit still applies")
    func ownEditApplies() async throws {
        let store = try EventStore()
        let author = try Fixture()

        let message = try author.message("tpyo", at: 1000)
        _ = try await store.ingest([
            message,
            try author.event(
                .buzzEdit, "typo",
                tags: [["h", "room-1"], ["e", message.id]], at: 1100
            ),
        ])

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.content == "typo")
        #expect(row.isEdited)
    }

    @Test("a foreign kind 5 does not delete someone else's message")
    func foreignDeletionIgnored() async throws {
        let store = try EventStore()
        let author = try Fixture()
        let attacker = try Fixture()

        let message = try author.message("still here", at: 1000)
        _ = try await store.ingest([
            message,
            try attacker.event(.deletion, "", tags: [["e", message.id]], at: 1100),
        ])

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(!row.isDeleted)
    }

    @Test("a moderator tombstone deletes regardless of author")
    func moderatorDeletionHonoured() async throws {
        // Kind 9005 is the relay's moderation surface: in NIP-29 the relay is
        // the group authority, so a 9005 it accepted is followed.
        let store = try EventStore()
        let author = try Fixture()
        let moderator = try Fixture()

        let message = try author.message("moderated away", at: 1000)
        _ = try await store.ingest([
            message,
            try moderator.event(
                .groupDeleteEvent, "",
                tags: [["h", "room-1"], ["e", message.id]], at: 1100
            ),
        ])

        let row = try #require(try store.timeline(channel: "room-1").first)
        #expect(row.isDeleted)
    }

    @Test("a foreign kind 5 cannot erase someone else's reaction")
    func foreignReactionDeletionIgnored() async throws {
        let store = try EventStore()
        let author = try Fixture()
        let reactor = try Fixture()
        let attacker = try Fixture()

        let message = try author.message("react to me", at: 1000)
        let reaction = try reactor.event(
            .reaction, "🔥", tags: [["e", message.id]], at: 1100
        )
        _ = try await store.ingest([
            message,
            reaction,
            try attacker.event(.deletion, "", tags: [["e", reaction.id]], at: 1200),
        ])

        let tallies = try store.reactions(for: [message.id], me: nil)
        #expect(tallies[message.id]?.first?.count == 1)
    }

    @Test("a foreign kind 5 does not blank the channel preview or unread")
    func foreignDeletionDoesNotTouchSummaries() async throws {
        let store = try EventStore()
        let author = try Fixture()
        let attacker = try Fixture()

        _ = try await store.ingest([
            try author.event(.groupMetadata, #"{"name":"General"}"#, tags: [["d", "room-1"]], at: 900),
        ])
        let message = try author.message("the preview", at: 1000)
        _ = try await store.ingest([
            message,
            try attacker.event(.deletion, "", tags: [["e", message.id]], at: 1100),
        ])

        let summary = try #require(try store.channelSummaries(me: "").first)
        #expect(summary.lastMessage == "the preview")
        #expect(summary.unreadCount == 1)
    }
}
