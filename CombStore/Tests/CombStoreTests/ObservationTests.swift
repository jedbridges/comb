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

    @Test("marking unread reopens a read channel from a chosen message")
    func markUnreadReopens() async throws {
        let store = try EventStore()
        let other = try Fixture()
        try await seed(store, other)

        let target = try other.message("come back to this", at: 5000)
        _ = try await store.ingest([
            target,
            try other.message("and this", at: 6000),
            try other.message("and this too", at: 7000),
        ])
        try await store.markRead(channel: "room-1")
        #expect(try store.channelSummaries(me: "").first?.unreadCount == 0)

        // From the target down: the target and the two after it, three unread.
        try await store.markUnread(channel: "room-1", from: target.createdAt)
        #expect(try store.channelSummaries(me: "").first?.unreadCount == 3)
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

@Suite("Profiles and search", .timeLimit(.minutes(1)))
struct ProfileSearchTests {
    @Test("joins a profile with how much they have said")
    func profileWithCount() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest([
            try fixture.event(
                .metadata,
                #"{"display_name":"Ada","about":"type systems","lud16":"ada@getalby.com"}"#,
                at: 900
            ),
            try fixture.message("one", at: 1000),
            try fixture.message("two", at: 2000),
        ])

        let profile = try #require(try store.profile(pubkey: fixture.pubkey))
        #expect(profile.name == "Ada")
        #expect(profile.about == "type systems")
        #expect(profile.messageCount == 2)
        #expect(profile.canReceiveZaps)
    }

    @Test("shows someone present without a profile event")
    func profilelessMember() async throws {
        // Plenty of people never publish a kind 0. Showing what we know beats
        // showing nothing.
        let store = try EventStore()
        let fixture = try Fixture()
        _ = try await store.ingest([try fixture.message("hello", at: 1000)])

        let profile = try #require(try store.profile(pubkey: fixture.pubkey))
        #expect(profile.displayName == nil)
        #expect(profile.name == String(fixture.pubkey.prefix(8)))
        #expect(profile.messageCount == 1)
    }

    @Test("returns nothing for a stranger")
    func unknownPubkey() throws {
        let store = try EventStore()
        #expect(try store.profile(pubkey: String(repeating: "a", count: 64)) == nil)
    }

    @Test("finds messages by text, newest first")
    func findsMessages() async throws {
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest([
            try fixture.event(.groupMetadata, #"{"name":"General"}"#, tags: [["d", "room-1"]], at: 900),
            try fixture.message("the gutters breathe", at: 1000),
            try fixture.message("nothing to do with it", at: 2000),
            try fixture.message("gutters at 20 then", at: 3000),
        ])

        let hits = try store.search("gutters")
        #expect(hits.count == 2)
        #expect(hits.first?.content == "gutters at 20 then")
        #expect(hits.first?.channelName == "General")
    }

    @Test("ignores deleted messages")
    func skipsDeleted() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        let message = try fixture.message("findable", at: 1000)

        _ = try await store.ingest([message])
        #expect(try store.search("findable").count == 1)

        _ = try await store.ingest([
            try fixture.event(.deletion, "", tags: [["e", message.id]], at: 1001),
        ])
        #expect(try store.search("findable").isEmpty)
    }

    @Test("treats wildcards in the query literally")
    func escapesWildcards() async throws {
        // A bare LIKE would make "%" match everything, so a user typing a
        // percent sign would get the whole log back.
        let store = try EventStore()
        let fixture = try Fixture()

        _ = try await store.ingest([
            try fixture.message("100% certain", at: 1000),
            try fixture.message("nothing relevant", at: 2000),
        ])

        #expect(try store.search("100%").count == 1)
        #expect(try store.search("%").isEmpty, "a lone wildcard must not match everything")
    }

    @Test("needs a real query")
    func ignoresShortQueries() async throws {
        let store = try EventStore()
        let fixture = try Fixture()
        _ = try await store.ingest([try fixture.message("anything", at: 1000)])

        #expect(try store.search("").isEmpty)
        #expect(try store.search("a").isEmpty)
    }
}

@Suite("Blocking", .timeLimit(.minutes(1)))
struct BlockingTests {
    private func seed(_ store: EventStore, _ fixture: Fixture) async throws {
        _ = try await store.ingest([
            try fixture.event(
                .groupMetadata, #"{"name":"General"}"#,
                tags: [["d", "room-1"]], at: 900
            ),
        ])
    }

    @Test("a blocked person's messages leave the timeline")
    func hidesMessages() async throws {
        let store = try EventStore()
        let other = try Fixture()
        try await seed(store, other)
        _ = try await store.ingest([try other.message("hello", at: 5000)])
        #expect(try store.timeline(channel: "room-1").count == 1)

        try await store.block(pubkey: other.pubkey)
        #expect(try store.timeline(channel: "room-1").isEmpty)
    }

    @Test("unblocking restores the history without a refetch")
    func unblockRestores() async throws {
        let store = try EventStore()
        let other = try Fixture()
        try await seed(store, other)
        _ = try await store.ingest([try other.message("still here", at: 5000)])

        try await store.block(pubkey: other.pubkey)
        try await store.unblock(pubkey: other.pubkey)

        // The event never left the log, so the row comes straight back.
        #expect(try store.timeline(channel: "room-1").first?.content == "still here")
    }

    @Test("a blocked person does not drive the preview or the unread badge")
    func hidesFromChannelList() async throws {
        let store = try EventStore()
        let other = try Fixture()
        try await seed(store, other)
        _ = try await store.ingest([try other.message("noisy", at: 5000)])
        #expect(try store.channelSummaries(me: "").first?.unreadCount == 1)

        try await store.block(pubkey: other.pubkey)
        let summary = try store.channelSummaries(me: "").first
        #expect(summary?.unreadCount == 0)
        #expect(summary?.lastMessage == nil)
    }

    @Test("a blocked person never produces a mention notification")
    func hidesMentions() async throws {
        let store = try EventStore()
        let me = try Fixture()
        let other = try Fixture()
        _ = try await store.ingest([
            try other.event(
                .groupChatMessage, "hey @you",
                tags: [["h", "room-1"], ["p", me.pubkey]], at: 5000
            )
        ])
        #expect(try store.mentions(of: me.pubkey, since: 1000).count == 1)

        try await store.block(pubkey: other.pubkey)
        #expect(try store.mentions(of: me.pubkey, since: 1000).isEmpty)
    }

    @Test("blocking is idempotent and survives being repeated")
    func idempotent() async throws {
        let store = try EventStore()
        let other = try Fixture()
        try await store.block(pubkey: other.pubkey)
        try await store.block(pubkey: other.pubkey)
        #expect(try store.blockedPeople().count == 1)
        #expect(try store.isBlocked(pubkey: other.pubkey))
    }
}

@Suite("Direct message naming", .timeLimit(.minutes(1)))
struct DirectMessageNameTests {
    /// Buzz sends a DM channel with a bare `hidden` tag and a placeholder name,
    /// and expects the client to title it from the roster.
    private func seedDM(
        _ store: EventStore,
        relay: Fixture,
        name: String,
        members: [Fixture],
        hidden: Bool = true
    ) async throws {
        var tags: [[String]] = [["d", "dm-1"]]
        if hidden { tags.append(["hidden"]) }

        var events = [
            try relay.event(
                .groupMetadata, #"{"name":"\#(name)"}"#, tags: tags, at: 900
            ),
            try relay.event(
                .groupMembers, "",
                tags: [["d", "dm-1"]] + members.map { ["p", $0.pubkey] },
                at: 901
            ),
        ]
        for member in members {
            events.append(
                try member.event(
                    .metadata, #"{"display_name":"\#(member.name)"}"#, at: 902
                )
            )
        }
        _ = try await store.ingest(events)
    }

    @Test("titles a placeholder DM with the other people in it")
    func namesFromRoster() async throws {
        let store = try EventStore()
        let relay = try Fixture()
        let me = try Fixture(name: "Me")
        let alice = try Fixture(name: "Alice")

        try await seedDM(store, relay: relay, name: "dm", members: [me, alice])

        let dm = try #require(try store.channelSummaries(me: me.pubkey).first)
        #expect(dm.isDirectMessage)
        // Only the other person: a conversation titled with your own name
        // among the others reads as a list of strangers plus you.
        #expect(dm.name == "Alice")
    }

    @Test("orders participants stably, not by a name that can change")
    func stableOrder() async throws {
        let store = try EventStore()
        let relay = try Fixture()
        let me = try Fixture(name: "Me")
        let alice = try Fixture(name: "Alice")
        let bob = try Fixture(name: "Bob")

        try await seedDM(store, relay: relay, name: "Group DM (3)", members: [me, alice, bob])

        let dm = try #require(try store.channelSummaries(me: me.pubkey).first)
        // Ordered by pubkey, so the expectation is derived the same way rather
        // than hardcoded: the keys are random per run.
        let expected = [alice, bob]
            .sorted { $0.pubkey < $1.pubkey }
            .map(\.name)
            .joined(separator: " & ")
        #expect(dm.name == expected)
    }

    @Test("keeps a name the operator actually chose")
    func keepsRealName() async throws {
        let store = try EventStore()
        let relay = try Fixture()
        let me = try Fixture(name: "Me")
        let alice = try Fixture(name: "Alice")

        try await seedDM(store, relay: relay, name: "Release planning", members: [me, alice])

        let dm = try #require(try store.channelSummaries(me: me.pubkey).first)
        #expect(dm.isDirectMessage)
        #expect(dm.name == "Release planning")
    }

    @Test("leaves an ordinary channel alone")
    func ordinaryChannelUnaffected() async throws {
        let store = try EventStore()
        let relay = try Fixture()
        let me = try Fixture(name: "Me")

        try await seedDM(store, relay: relay, name: "dm", members: [me], hidden: false)

        let channel = try #require(try store.channelSummaries(me: me.pubkey).first)
        #expect(!channel.isDirectMessage)
        // Without the hidden tag this is just a room unfortunately called "dm".
        #expect(channel.name == "dm")
    }

    @Test("recognises the placeholder names Buzz actually sends")
    func placeholders() {
        #expect(DirectMessageName.isPlaceholder("dm"))
        #expect(DirectMessageName.isPlaceholder("DM"))
        #expect(DirectMessageName.isPlaceholder(" Direct Message "))
        #expect(DirectMessageName.isPlaceholder("Group DM"))
        #expect(DirectMessageName.isPlaceholder("Group DM (12)"))
        #expect(DirectMessageName.isPlaceholder(""))
        #expect(DirectMessageName.isPlaceholder(nil))

        #expect(!DirectMessageName.isPlaceholder("Release planning"))
        #expect(!DirectMessageName.isPlaceholder("dm-notes"))
        #expect(!DirectMessageName.isPlaceholder("Group DM planning"))
    }

    @Test("caps a crowded conversation with a count")
    func capsParticipants() {
        #expect(DirectMessageName.label(participants: []) == nil)
        #expect(DirectMessageName.label(participants: ["A"]) == "A")
        #expect(DirectMessageName.label(participants: ["A", "B"]) == "A & B")
        // Three is already an overflow: only two names are ever spelled out.
        #expect(DirectMessageName.label(participants: ["A", "B", "C"]) == "A, B & 1 other")
        #expect(
            DirectMessageName.label(participants: ["A", "B", "C", "D", "E"])
                == "A, B & 3 others"
        )
    }

    @Test("never shows the relay's placeholder, even before the roster lands")
    func rosterMissing() {
        // Group state and membership are separate events, so this window is
        // real on every cold launch. It must not render as "dm".
        #expect(
            DirectMessageName.resolve(
                name: "dm", isDirectMessage: true, participants: [], fallback: "dm-1"
            ) == "Direct message"
        )
        #expect(
            DirectMessageName.resolve(
                name: "Group DM (4)", isDirectMessage: true, participants: [], fallback: "dm-1"
            ) == "Direct message"
        )
    }
}

@Suite("Membership changes", .timeLimit(.minutes(1)))
struct MembershipChangeTests {
    /// The relay signs these, and only ever sends them scoped to the reader.
    private func seedChannel(_ store: EventStore, relay: Fixture) async throws {
        _ = try await store.ingest([
            try relay.event(
                .groupMetadata, #"{"name":"General"}"#, tags: [["d", "general"]], at: 900
            ),
            try relay.event(
                .groupMetadata, #"{"name":"Fonts"}"#, tags: [["d", "fonts"]], at: 901
            ),
        ])
    }

    @Test("a channel this account was removed from leaves the list")
    func removalHidesChannel() async throws {
        let store = try EventStore()
        let relay = try Fixture()
        let me = try Fixture()
        try await seedChannel(store, relay: relay)
        #expect(try store.channelSummaries().count == 2)

        _ = try await store.ingest([
            try relay.event(
                .buzzMemberRemoved, "",
                tags: [["p", me.pubkey], ["h", "general"]], at: 1000
            ),
        ])

        #expect(try store.channelSummaries().map(\.name) == ["Fonts"])
    }

    @Test("survives a projection rebuild")
    func removalSurvivesRebuild() async throws {
        // The whole point of projecting the departure rather than deleting the
        // channel row: a rebuild replays the log, and a delete would be undone.
        let store = try EventStore()
        let relay = try Fixture()
        let me = try Fixture()
        try await seedChannel(store, relay: relay)
        _ = try await store.ingest([
            try relay.event(
                .buzzMemberRemoved, "",
                tags: [["p", me.pubkey], ["h", "general"]], at: 1000
            ),
        ])

        try await store.rebuildProjections()
        #expect(try store.channelSummaries().map(\.name) == ["Fonts"])
    }

    @Test("being added back brings it home")
    func readdRestoresChannel() async throws {
        let store = try EventStore()
        let relay = try Fixture()
        let me = try Fixture()
        try await seedChannel(store, relay: relay)

        _ = try await store.ingest([
            try relay.event(
                .buzzMemberRemoved, "",
                tags: [["p", me.pubkey], ["h", "general"]], at: 1000
            ),
            try relay.event(
                .buzzMemberAdded, "",
                tags: [["p", me.pubkey], ["h", "general"]], at: 2000
            ),
        ])

        #expect(try store.channelSummaries().count == 2)
        // And still after a replay, which is where an order-dependent
        // implementation would settle on the wrong one of the two.
        try await store.rebuildProjections()
        #expect(try store.channelSummaries().count == 2)
    }

    @Test("an older re-add does not undo a newer removal")
    func staleAddIgnored() async throws {
        // A relay resending an old notice after a reconnect must not put back
        // a channel the account has since been removed from.
        let store = try EventStore()
        let relay = try Fixture()
        let me = try Fixture()
        try await seedChannel(store, relay: relay)

        _ = try await store.ingest([
            try relay.event(
                .buzzMemberRemoved, "",
                tags: [["p", me.pubkey], ["h", "general"]], at: 2000
            ),
        ])
        _ = try await store.ingest([
            try relay.event(
                .buzzMemberAdded, "",
                tags: [["p", me.pubkey], ["h", "general"]], at: 1000
            ),
        ])

        #expect(try store.channelSummaries().map(\.name) == ["Fonts"])
    }

    @Test("a notice without a channel is ignored rather than fatal")
    func missingChannelTag() async throws {
        let store = try EventStore()
        let relay = try Fixture()
        let me = try Fixture()
        try await seedChannel(store, relay: relay)

        _ = try await store.ingest([
            try relay.event(.buzzMemberRemoved, "", tags: [["p", me.pubkey]], at: 1000),
        ])

        #expect(try store.channelSummaries().count == 2)
    }
}

@Suite("Profile document", .timeLimit(.minutes(1)))
struct ProfileDocumentTests {
    private func summary(
        picture: String? = nil,
        about: String? = nil,
        nip05: String? = nil,
        lud16: String? = nil
    ) -> ProfileSummary {
        ProfileSummary(
            pubkey: "abc", displayName: "Old", about: about, picture: picture,
            nip05: nip05, lightningAddress: lud16, hasProfile: true, messageCount: 1
        )
    }

    @Test("a rename keeps the avatar, bio, handle, and lightning address")
    func renamePreservesEverythingElse() {
        // The bug this exists for: kind 0 is replaceable, so publishing only
        // the name deleted all four of these for anyone who renamed themselves.
        let document = ProfileDocument.rename(
            to: "Jed",
            preserving: summary(
                picture: "https://example.test/a.jpg",
                about: "https://x.com/someone",
                nip05: "jed@example.test",
                lud16: "jed@wallet.test"
            )
        )

        #expect(document["name"] == "Jed")
        #expect(document["display_name"] == "Jed")
        #expect(document["picture"] == "https://example.test/a.jpg")
        #expect(document["about"] == "https://x.com/someone")
        #expect(document["nip05"] == "jed@example.test")
        #expect(document["lud16"] == "jed@wallet.test")
    }

    @Test("writes both spellings of the name")
    func bothSpellings() {
        // Clients disagree about which one they read, so neither is optional.
        let document = ProfileDocument.rename(to: "Jed", preserving: nil)
        #expect(document["name"] == "Jed")
        #expect(document["display_name"] == "Jed")
        #expect(document.count == 2)
    }

    @Test("omits empty fields rather than publishing them blank")
    func dropsEmpties() {
        // An empty string is a present field to a reader, and some clients
        // render it as a blank avatar rather than falling back.
        let document = ProfileDocument.rename(
            to: "Jed",
            preserving: summary(picture: "", about: "", nip05: "", lud16: "")
        )
        #expect(document.count == 2)
        #expect(document["picture"] == nil)
    }

    @Test("carries whichever fields happen to be known")
    func partialProfile() {
        let document = ProfileDocument.rename(
            to: "Jed",
            preserving: summary(picture: "https://example.test/a.jpg")
        )
        #expect(document["picture"] == "https://example.test/a.jpg")
        #expect(document["about"] == nil)
        #expect(document.count == 3)
    }

    @Test("an account with no profile yet publishes just the name")
    func noExistingProfile() {
        #expect(ProfileDocument.rename(to: "Jed", preserving: nil).count == 2)
    }
}
