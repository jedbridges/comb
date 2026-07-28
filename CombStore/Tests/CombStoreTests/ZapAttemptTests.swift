import CombCore
import Foundation
import Testing
@testable import CombStore

@Suite("Zap attempts")
struct ZapAttemptTests {
    private let epoch = Date(timeIntervalSince1970: 100_000)

    private func record(
        _ store: EventStore,
        requestID: String = "req-1",
        targetID: String? = "msg-1",
        recipient: String = "recipient-hex",
        issuer: String = "issuer-hex",
        amountMillisats: Int64 = 21_000,
        at date: Date
    ) async throws {
        try await store.recordZapAttempt(
            requestID: requestID,
            targetID: targetID,
            recipient: recipient,
            issuer: issuer,
            amountMillisats: amountMillisats,
            at: date
        )
    }

    @Test("a handoff is remembered so it survives the sheet closing")
    func recordsAHandoff() async throws {
        let store = try EventStore()
        try await record(store, at: epoch)

        let pending = try store.pendingZapAttempts(at: epoch)
        #expect(pending.count == 1)
        #expect(pending.first?.targetID == "msg-1")
        #expect(pending.first?.amountSats == 21)
    }

    /// The same request reaching the wallet twice is one attempt, not two.
    @Test("recording the same request twice does not double it")
    func isIdempotent() async throws {
        let store = try EventStore()
        try await record(store, at: epoch)
        try await record(store, at: epoch.addingTimeInterval(5))

        #expect(try store.pendingZapAttempts(at: epoch).count == 1)
    }

    /// The point of the whole table: an attempt is a claim about something Comb
    /// cannot observe, so it has to stop being shown.
    @Test("an attempt no receipt answered stops counting after an hour")
    func expires() async throws {
        let store = try EventStore()
        try await record(store, at: epoch)

        let almost = epoch.addingTimeInterval(EventStore.zapAttemptLifetime - 60)
        #expect(try store.pendingZapAttempts(at: almost).count == 1)

        let after = epoch.addingTimeInterval(EventStore.zapAttemptLifetime + 60)
        #expect(try store.pendingZapAttempts(at: after).isEmpty)
    }

    @Test("pruning removes what has already stopped counting")
    func prunes() async throws {
        let store = try EventStore()
        try await record(store, at: epoch)
        try await record(store, requestID: "req-2", at: epoch.addingTimeInterval(3_500))

        let removed = try await store.pruneZapAttempts(
            before: epoch.addingTimeInterval(EventStore.zapAttemptLifetime + 60)
        )
        #expect(removed == 1)
        #expect(try store.pendingZapAttempts(at: epoch.addingTimeInterval(3_600)).count == 1)
    }

    /// The issuer key is the thing a receipt cannot be checked without, and
    /// sending a zap is the one moment it can be learned without making a
    /// request the reader did not ask for.
    @Test("sending a zap caches the endpoint's signing key")
    func cachesTheIssuer() async throws {
        let store = try EventStore()
        try await record(store, at: epoch)

        #expect(try store.cachedIssuer(for: "recipient-hex") == "issuer-hex")
        #expect(try store.cachedIssuer(for: "a-stranger") == nil)
    }

    /// A recipient can move wallet provider, and the newest answer is the one
    /// worth keeping.
    @Test("a later zap refreshes a stale issuer key")
    func refreshesTheIssuer() async throws {
        let store = try EventStore()
        try await record(store, at: epoch)
        try await record(
            store, requestID: "req-2", issuer: "new-issuer",
            at: epoch.addingTimeInterval(86_400)
        )

        #expect(try store.cachedIssuer(for: "recipient-hex") == "new-issuer")
    }

    /// Local tables cannot be rebuilt from the log, so a projection rebuild
    /// must leave them alone. The outbox learned this the same way.
    @Test("a projection rebuild does not wipe attempts or issuer keys")
    func survivesAProjectionRebuild() async throws {
        let store = try EventStore()
        try await record(store, at: epoch)

        try await store.rebuildProjections()

        #expect(try store.pendingZapAttempts(at: epoch).count == 1)
        #expect(try store.cachedIssuer(for: "recipient-hex") == "issuer-hex")
    }
}

/// The three answers to "can this person be zapped", which used to be two.
@Suite("Zap capability")
struct ZapCapabilityTests {
    /// Returns both answers for one author: the one the timeline gives a
    /// message row, and the one the profile sheet gives. They have to agree.
    private func capabilities(
        metadata: String?
    ) async throws -> (row: ProfileSummary.ZapCapability, profile: ProfileSummary.ZapCapability) {
        let store = try EventStore()
        let author = try Fixture()

        var events = [try author.message("hello", at: 1_000)]
        if let metadata {
            events.append(try author.event(.metadata, metadata, at: 900))
        }
        _ = try await store.ingest(events)

        // Both reads are pulled out first: #require rewrites a bare call and
        // loses the `try` doing it.
        let rows = try store.timeline(channel: "room-1")
        let fetched = try store.profile(pubkey: author.pubkey)

        let row = try #require(rows.first)
        let profile = try #require(fetched)
        return (row.zapCapability, profile.zapCapability)
    }

    /// The bug: a member whose kind 0 was never fetched looked exactly like a
    /// member who had published one with no Lightning address, so the zap
    /// button vanished with no explanation.
    @Test("no profile at all is unknown, not a refusal")
    func unknownWithoutAProfile() async throws {
        let (row, profile) = try await capabilities(metadata: nil)
        #expect(row == .unknown)
        #expect(profile == .unknown)
    }

    @Test("a profile with no lightning address is a real no")
    func noWithAProfile() async throws {
        let (row, profile) = try await capabilities(metadata: #"{"name":"Ada"}"#)
        #expect(row == .no)
        #expect(profile == .no)
    }

    @Test("a profile with a lightning address can be zapped")
    func yesWithAnAddress() async throws {
        let (row, profile) = try await capabilities(
            metadata: #"{"name":"Ada","lud16":"ada@getalby.com"}"#
        )
        #expect(row == .yes)
        #expect(profile == .yes)
    }
}

/// Roles, and the reason they were empty strings until now.
@Suite("Channel roles")
struct ChannelRoleTests {
    /// Seeds a channel whose roster is exactly `people`, each with the role
    /// given beside them.
    ///
    /// Every member gets a kind 0 as well, and that is load-bearing rather than
    /// scenery: `members(of:)` resolves each pubkey through `profile(pubkey:)`,
    /// which returns nil for someone with no profile and no messages. Without
    /// it the roster comes back empty and an assertion on `first?.role` passes
    /// because there is no first, not because the role is right.
    private func seed(_ people: [(Fixture, String?)]) async throws -> EventStore {
        let store = try EventStore()
        let relay = try Fixture(name: "relay")

        var events = [
            try relay.event(
                .groupMetadata, #"{"name":"General"}"#, tags: [["d", "room-1"]], at: 900
            ),
        ]
        var roster: [[String]] = [["d", "room-1"]]

        for (person, role) in people {
            events.append(try person.event(.metadata, "{\"name\":\"\(person.name)\"}", at: 800))
            roster.append(role.map { ["p", person.pubkey, "", $0] } ?? ["p", person.pubkey])
        }

        events.append(try relay.event(.groupMembers, "", tags: roster, at: 1_000))
        _ = try await store.ingest(events)
        return store
    }

    /// The bug this suite exists for. NIP-29 spells a roster entry
    /// ["p", pubkey, relay_url, role], and Buzz sends the relay slot empty, so
    /// reading index 2 stored "" for every member of every channel.
    @Test("the role is read from the fourth element, not the third")
    func readsRoleFromTheRightIndex() async throws {
        let owner = try Fixture(name: "Ada")
        let plain = try Fixture(name: "Bob")
        let store = try await seed([(owner, "owner"), (plain, "member")])

        let members = try store.members(of: "room-1")
        #expect(members.count == 2)
        #expect(members.first(where: { $0.pubkey == owner.pubkey })?.role == .owner)
        #expect(members.first(where: { $0.pubkey == plain.pubkey })?.role == .member)
    }

    /// A relay that publishes no roles is saying it does not publish them. That
    /// is not the same answer as "everyone is an ordinary member", and
    /// flattening the two would hide actions from people who may be owners.
    @Test("a roster with no roles yields nil, never a guess")
    func missingRoleIsUnknown() async throws {
        let someone = try Fixture(name: "Ada")
        let store = try await seed([(someone, nil)])

        let members = try store.members(of: "room-1")
        #expect(members.count == 1)
        #expect(members.first?.role == nil)
    }

    /// The relay slot is empty, not absent, in a roster that carries no role.
    @Test("an empty role is not mistaken for one")
    func emptyRoleIsNil() async throws {
        let someone = try Fixture(name: "Ada")
        let store = try await seed([(someone, "")])

        let members = try store.members(of: "room-1")
        #expect(members.count == 1)
        #expect(members.first?.role == nil)
    }

    /// The set is the relay's to extend, so an unrecognised value must read as
    /// "no answer" rather than being coerced into one Comb knows.
    @Test("a role Comb has never heard of is unknown")
    func unknownRoleIsNil() async throws {
        let someone = try Fixture(name: "Ada")
        let store = try await seed([(someone, "archivist")])

        let members = try store.members(of: "room-1")
        #expect(members.count == 1)
        #expect(members.first?.role == nil)
    }

    @Test("the viewer's own role reaches the channel summary")
    func ownRoleOnTheSummary() async throws {
        let me = try Fixture(name: "me")
        let store = try await seed([(me, "admin")])

        let summaries = try store.channelSummaries(me: me.pubkey)
        let summary = try #require(summaries.first(where: { $0.id == "room-1" }))
        #expect(summary.myRole == .admin)
        #expect(summary.myRole?.isElevated == true)
        #expect(summary.isMember)
    }

    @Test("owners and admins sort above the rest")
    func elevatedFirst() async throws {
        let owner = try Fixture(name: "Ada")
        let plain = try Fixture(name: "Bob")
        let store = try await seed([(plain, "member"), (owner, "owner")])

        let members = try store.members(of: "room-1")
        #expect(members.count == 2)
        #expect(members.first?.pubkey == owner.pubkey)
    }

    /// The whole point of the version bump: an install whose rosters were
    /// projected by the broken parser must end up with real roles, not "".
    @Test("a projection rebuild re-derives roles from the log")
    func rebuildRecoversRoles() async throws {
        let owner = try Fixture(name: "Ada")
        let store = try await seed([(owner, "owner")])

        try await store.rebuildProjections()

        #expect(try store.members(of: "room-1").first?.role == .owner)
    }
}

/// Group state is the relay's word on who exists and who runs a channel, so
/// only the relay gets to say it.
@Suite("Relay-signed provenance")
struct RelayProvenanceTests {
    private func roster(_ signer: Fixture, owner: Fixture) throws -> NostrEvent {
        try signer.event(
            .groupMembers, "",
            tags: [["d", "room-1"], ["p", owner.pubkey, "", "owner"]],
            at: 1_000
        )
    }

    /// The attack this exists to stop: a perfectly valid signature over a
    /// roster the signer had no standing to write.
    @Test("a roster signed by someone other than the relay is refused")
    func rejectsAForgedRoster() async throws {
        let store = try EventStore()
        let relay = try Fixture(name: "relay")
        let attacker = try Fixture(name: "Mallory")
        try await store.setRelaySigningKey(relay.pubkey)

        let forged = try roster(attacker, owner: attacker)
        let result = try await store.ingest([forged])

        #expect(result.inserted.isEmpty)
        #expect(result.rejected.first?.reason == .notFromRelay)
        #expect(try store.members(of: "room-1").isEmpty)
    }

    @Test("the same roster from the relay is stored")
    func acceptsTheRelaysOwn() async throws {
        let store = try EventStore()
        let relay = try Fixture(name: "relay")
        let owner = try Fixture(name: "Ada")
        try await store.setRelaySigningKey(relay.pubkey)

        _ = try await store.ingest([
            try relay.event(
                .groupMetadata, #"{"name":"General"}"#, tags: [["d", "room-1"]], at: 900
            ),
            try owner.event(.metadata, "{}", at: 800),
            try roster(relay, owner: owner),
        ])

        #expect(try store.members(of: "room-1").first?.role == .owner)
    }

    /// Ordinary events are unaffected: the rule is about kinds the relay
    /// authors, not about who may talk.
    @Test("a message from a member is untouched by the rule")
    func leavesOrdinaryEventsAlone() async throws {
        let store = try EventStore()
        let relay = try Fixture(name: "relay")
        let member = try Fixture(name: "Ada")
        try await store.setRelaySigningKey(relay.pubkey)

        let result = try await store.ingest([try member.message("hello", at: 1_000)])
        #expect(result.inserted.count == 1)
    }

    /// A plain NIP-29 relay whose NIP-11 has no `self` cannot be checked.
    /// Refusing its group state would break the app rather than protect it.
    @Test("with no known relay key the check is skipped, not failed closed")
    func skipsWhenTheKeyIsUnknown() async throws {
        let store = try EventStore()
        let somebody = try Fixture(name: "somebody")

        let result = try await store.ingest([try roster(somebody, owner: somebody)])
        #expect(result.inserted.count == 1)
    }

    /// The key is persisted, so an offline launch and a replay reach the same
    /// verdicts the live session did rather than quietly reverting to trusting
    /// everyone.
    @Test("the relay key survives reopening the store")
    func persistsAcrossOpen() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("comb-provenance-\(UUID().uuidString).sqlite")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let relay = try Fixture(name: "relay")
        let attacker = try Fixture(name: "Mallory")

        do {
            let store = try EventStore(path: path)
            try await store.setRelaySigningKey(relay.pubkey)
        }

        let reopened = try EventStore(path: path)
        let result = try await reopened.ingest([try roster(attacker, owner: attacker)])
        #expect(result.rejected.first?.reason == .notFromRelay)
    }
}

/// Membership has to reach the screen through the observation, not through the
/// value the screen was pushed with.
@Suite("Observed membership")
struct ObservedMembershipTests {
    @Test("the timeline snapshot answers whether this account is a member")
    func snapshotCarriesMembership() async throws {
        let store = try EventStore()
        let relay = try Fixture(name: "relay")
        let me = try Fixture(name: "me")
        let other = try Fixture(name: "Ada")

        _ = try await store.ingest([
            try relay.event(
                .groupMetadata, #"{"name":"General"}"#, tags: [["d", "room-1"]], at: 900
            ),
            try other.message("hello", at: 1_000),
            // A roster this account is not on.
            try relay.event(
                .groupMembers, "",
                tags: [["d", "room-1"], ["p", other.pubkey, "", "owner"]],
                at: 1_100
            ),
        ])

        var snapshot = try await firstSnapshot(store, me: me.pubkey)
        #expect(snapshot.isMember == false)

        // Joining is the relay adding you to the roster it publishes.
        _ = try await store.ingest([
            try relay.event(
                .groupMembers, "",
                tags: [
                    ["d", "room-1"],
                    ["p", other.pubkey, "", "owner"],
                    ["p", me.pubkey, "", "member"],
                ],
                at: 1_200
            ),
        ])

        snapshot = try await firstSnapshot(store, me: me.pubkey)
        #expect(snapshot.isMember == true)
    }

    /// A thread is only reachable from inside its channel, so the screen above
    /// it already answered. Nil rather than a defaulted true.
    @Test("a thread snapshot does not claim to know")
    func threadDoesNotAnswer() async throws {
        let store = try EventStore()
        let author = try Fixture(name: "Ada")
        let root = try author.message("opener", at: 1_000)
        _ = try await store.ingest([root])

        for try await value in store.observeThread(root: root.id, me: author.pubkey) {
            #expect(value.isMember == nil)
            break
        }
    }

    private func firstSnapshot(_ store: EventStore, me: String) async throws -> TimelineSnapshot {
        for try await value in store.observeTimeline(channel: "room-1", limit: 50, me: me) {
            return value
        }
        throw CancellationError()
    }
}
