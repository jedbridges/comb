import CombCore
import Foundation
import GRDB
import Testing

@testable import CombStore

/// The six rails that decide whether somebody else's process can move a
/// reader's money.
///
/// Every one of these is a way the feature could be wrong that a person would
/// only discover from their balance, so they are tested rather than reasoned
/// about. The clock is injected throughout, because two of the checks are about
/// time and a test that cannot move the clock cannot cover them.
@Suite("Agent spending")
struct SpendingTests {
    private let day: Int64 = 86_400

    private func rig() async throws -> (store: EventStore, agent: Fixture, recipient: Fixture) {
        let store = try EventStore()
        return (store, try Fixture(name: "botA"), try Fixture(name: "Ada"))
    }

    private func intent(
        _ agent: Fixture,
        to recipient: Fixture,
        sats: Int64,
        channel: String = "room-1",
        at seconds: Int64 = 10_000
    ) async throws -> Zap.Intent {
        let event = try await Zap.intent(
            amountMillisats: sats * 1000,
            recipient: recipient.pubkey,
            groupID: channel,
            eventID: "msg-1",
            comment: "nice work",
            with: InMemorySigner(agent.key)
        )
        // The builder stamps its own time; rebuild at the moment the test wants.
        let stamped = NostrEvent(
            id: event.id, pubkey: event.pubkey, createdAt: seconds, kind: event.kind,
            tags: event.tags, content: event.content, sig: event.sig
        )
        return Zap.Intent(
            id: stamped.id, agent: stamped.pubkey, channel: channel,
            recipient: recipient.pubkey, targetEventID: "msg-1",
            amountMillisats: sats * 1000, comment: "nice work", createdAt: seconds
        )
    }

    private func grant(
        _ agent: Fixture,
        channel: String = "room-1",
        allowance: Int64 = 500,
        perZap: Int64 = 100
    ) -> SpendGrant {
        SpendGrant(
            agentPubkey: agent.pubkey,
            channelID: channel,
            allowanceMillisats: allowance * 1000,
            windowSeconds: day,
            perZapMillisats: perZap * 1000,
            createdAt: 0
        )
    }

    private func now(_ seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // MARK: - Rail 1

    /// The most absolute one. An agent nobody granted anything cannot spend, and
    /// this is not a budget question: it is an agent that may not have been
    /// invited at all.
    @Test("no grant means no spend")
    func rail1_noGrant() async throws {
        let (store, agent, recipient) = try await rig()
        let ask = try await intent(agent, to: recipient, sats: 1)

        #expect(try store.decide(ask, now: now(10_010)) == .noGrant)
    }

    // MARK: - Rail 2

    /// A grant is per channel, so an agent funded for one room cannot spend in
    /// another. Reported as the wrong channel rather than as no grant, because
    /// the two want different reactions from the reader.
    @Test("a grant is per channel and does not travel")
    func rail2_wrongChannel() async throws {
        let (store, agent, recipient) = try await rig()
        try await store.grant(grant(agent, channel: "room-1"))

        let elsewhere = try await intent(agent, to: recipient, sats: 21, channel: "room-2")
        #expect(try store.decide(elsewhere, now: now(10_010)) == .wrongChannel)

        let here = try await intent(agent, to: recipient, sats: 21, channel: "room-1")
        #expect(try store.decide(here, now: now(10_010)) == nil)
    }

    // MARK: - Rail 3

    /// One intent, one payment. Without this a hostile or buggy agent republishes
    /// a single approved ask and drains the allowance a sat at a time.
    @Test("a replayed intent pays once")
    func rail3_replay() async throws {
        let (store, agent, recipient) = try await rig()
        try await store.grant(grant(agent))
        let ask = try await intent(agent, to: recipient, sats: 50)

        // First arrival passes and claims.
        #expect(try store.decide(ask, now: now(10_010)) == nil)
        #expect(try await store.claim(ask, at: now(10_010)))

        // Second arrival is refused, and the claim refuses to double-write.
        #expect(try store.decide(ask, now: now(10_020)) == .alreadySeen)
        #expect(try await store.claim(ask, at: now(10_020)) == false)

        // And only one payment's worth counts against the window.
        #expect(
            try store.spent(
                agent: agent.pubkey, channel: "room-1", window: day, now: now(10_030)
            ) == 50_000
        )
    }

    // MARK: - Rail 4

    /// A queue of intents published while the app was closed must not spend all
    /// at once the moment it opens. That is the one way a correct allowance can
    /// still produce a surprise.
    @Test("a stale intent is refused")
    func rail4_stale() async throws {
        let (store, agent, recipient) = try await rig()
        try await store.grant(grant(agent))
        let ask = try await intent(agent, to: recipient, sats: 21, at: 10_000)

        // Inside the window.
        #expect(try store.decide(ask, now: now(10_100)) == nil)
        // Six minutes later, past the five-minute freshness.
        #expect(try store.decide(ask, now: now(10_360)) == .stale)
    }

    // MARK: - Rail 5

    /// Revoking has to bite against an intent already decided but not yet paid,
    /// or "Stop" is a suggestion.
    @Test("revoking stops a spend that was already approved")
    func rail5_revocation() async throws {
        let (store, agent, recipient) = try await rig()
        try await store.grant(grant(agent))
        let ask = try await intent(agent, to: recipient, sats: 21)

        #expect(try store.decide(ask, now: now(10_010)) == nil)

        // The reader taps Stop between the decision and the payment.
        try await store.revokeGrant(agent: agent.pubkey, channel: "room-1")

        // The check runs again at payment time, so it now refuses.
        #expect(try store.decide(ask, now: now(10_020)) == .noGrant)
    }

    /// The same rail through the sequence the app actually performs, and the
    /// reason the payment path reads the grant directly rather than re-running
    /// the whole decision.
    ///
    /// Order matters here and is easy to get backwards. The grant check runs
    /// before the already-seen check, so after a claim `decide` returns
    /// `.noGrant` when the allowance is gone and `.alreadySeen` when it is
    /// intact. Both are correct and neither is usable as a go-ahead: a caller
    /// would have to treat one specific refusal value as permission, which is a
    /// fragile way to decide whether to move money. Reading the grant is the
    /// question actually being asked.
    @Test("revoking bites after the intent has already been claimed")
    func rail5_revocationAfterClaim() async throws {
        let (store, agent, recipient) = try await rig()
        try await store.grant(grant(agent))
        let ask = try await intent(agent, to: recipient, sats: 21)

        #expect(try store.decide(ask, now: now(10_010)) == nil)
        #expect(try await store.claim(ask, at: now(10_010)))

        // Grant intact after a claim: the only thing left to report is that this
        // intent is spoken for, which says nothing about permission.
        #expect(try store.decide(ask, now: now(10_015)) == .alreadySeen)

        try await store.revokeGrant(agent: agent.pubkey, channel: "room-1")

        // Revoked: the grant check fires first, so this becomes a refusal again.
        #expect(try store.decide(ask, now: now(10_016)) == .noGrant)
        // And the question the payment path asks has the same answer.
        #expect(try store.spendGrant(agent: agent.pubkey, channel: "room-1") == nil)
    }

    // MARK: - Rail 6

    /// The ledger is local-only, and a projection rebuild must not be able to
    /// invent a grant or forget a spend. If it could, a relay would have a path
    /// to either.
    @Test("a projection rebuild cannot create a grant or erase a spend")
    func rail6_localOnly() async throws {
        let (store, agent, recipient) = try await rig()
        try await store.grant(grant(agent))
        let ask = try await intent(agent, to: recipient, sats: 50)
        _ = try await store.claim(ask, at: now(10_010))

        try await store.rebuildProjections()

        #expect(try store.spendGrants().count == 1)
        #expect(try store.spendLedger().count == 1)
        #expect(
            try store.spent(
                agent: agent.pubkey, channel: "room-1", window: day, now: now(10_020)
            ) == 50_000
        )
        // Named explicitly: presence in this list is what would make a rebuild
        // able to drop them.
        #expect(!Schema.projectionTables.contains("spend_grant"))
        #expect(!Schema.projectionTables.contains("spend_ledger"))
    }
}

/// The two dials, and how they interact.
@Suite("Spend limits")
struct SpendLimitTests {
    private let day: Int64 = 86_400

    private func now(_ seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private func intent(
        _ agent: Fixture,
        _ recipient: Fixture,
        sats: Int64,
        id: String,
        at seconds: Int64 = 10_000
    ) -> Zap.Intent {
        Zap.Intent(
            id: id, agent: agent.pubkey, channel: "room-1", recipient: recipient.pubkey,
            targetEventID: nil, amountMillisats: sats * 1000, comment: "",
            createdAt: seconds
        )
    }

    private func rig(
        allowance: Int64 = 500,
        perZap: Int64 = 100
    ) async throws -> (EventStore, Fixture, Fixture) {
        let store = try EventStore()
        let agent = try Fixture(name: "botA")
        let recipient = try Fixture(name: "Ada")
        try await store.grant(SpendGrant(
            agentPubkey: agent.pubkey, channelID: "room-1",
            allowanceMillisats: allowance * 1000, windowSeconds: day,
            perZapMillisats: perZap * 1000, createdAt: 0
        ))
        return (store, agent, recipient)
    }

    /// The dial that stops one request eating the whole allowance, and the reason
    /// there is no approve-each-spend prompt.
    @Test("a single zap over the ceiling is refused, not escalated")
    func perZapCeiling() async throws {
        let (store, agent, recipient) = try await rig(allowance: 500, perZap: 100)

        #expect(try store.decide(intent(agent, recipient, sats: 100, id: "a"), now: now(10_010)) == nil)
        #expect(
            try store.decide(intent(agent, recipient, sats: 101, id: "b"), now: now(10_010))
                == .overPerZapCeiling(ceiling: 100_000)
        )
    }

    @Test("the allowance is spent down and then refuses, naming what is left")
    func allowance() async throws {
        let (store, agent, recipient) = try await rig(allowance: 250, perZap: 100)

        for (index, sats) in [100, 100].enumerated() {
            let ask = intent(agent, recipient, sats: Int64(sats), id: "spend-\(index)")
            #expect(try store.decide(ask, now: now(10_010)) == nil)
            _ = try await store.claim(ask, at: now(10_010))
        }

        // 200 of 250 gone, so a third 100 will not fit and the refusal says so.
        let third = intent(agent, recipient, sats: 100, id: "spend-3")
        #expect(
            try store.decide(third, now: now(10_020)) == .overAllowance(remaining: 50_000)
        )
        // But 50 does fit.
        #expect(try store.decide(intent(agent, recipient, sats: 50, id: "spend-4"), now: now(10_020)) == nil)
    }

    /// The reason the window is a rolling lookback rather than a calendar day.
    /// With a midnight reset, an agent could spend a full allowance twice inside
    /// two minutes by straddling the boundary.
    @Test("the window rolls, so yesterday's spend stops counting")
    func rollingWindow() async throws {
        let (store, agent, recipient) = try await rig(allowance: 100, perZap: 100)

        let first = intent(agent, recipient, sats: 100, id: "old", at: 10_000)
        _ = try await store.claim(first, at: now(10_000))

        // Immediately after, the allowance is gone.
        let soon = intent(agent, recipient, sats: 100, id: "soon", at: 10_100)
        #expect(try store.decide(soon, now: now(10_100)) == .overAllowance(remaining: 0))

        // A day and a second later, the old spend has rolled out of the window.
        let later = intent(agent, recipient, sats: 100, id: "later", at: 10_000 + day + 1)
        #expect(try store.decide(later, now: now(10_000 + day + 1)) == nil)
    }

    /// A refusal is not a spend. Counting one would let a misbehaving agent
    /// exhaust an allowance without ever being paid anything.
    @Test("a refusal never counts against the allowance")
    func refusalsAreFree() async throws {
        let (store, agent, recipient) = try await rig(allowance: 100, perZap: 50)

        let tooBig = intent(agent, recipient, sats: 500, id: "big")
        try await store.refuse(tooBig, .overPerZapCeiling(ceiling: 50_000), at: now(10_010))

        #expect(
            try store.spent(
                agent: agent.pubkey, channel: "room-1", window: day, now: now(10_020)
            ) == 0
        )
        // And the full allowance is still available.
        #expect(try store.decide(intent(agent, recipient, sats: 50, id: "ok"), now: now(10_020)) == nil)
    }

    /// A payment that failed releases its hold. The money may still have moved,
    /// which is why the row stays and says so, but holding an allowance against a
    /// payment that did not happen is the wrong way round.
    @Test("a failed payment releases its hold on the allowance")
    func failureReleases() async throws {
        let (store, agent, recipient) = try await rig(allowance: 100, perZap: 100)

        let ask = intent(agent, recipient, sats: 100, id: "attempt")
        _ = try await store.claim(ask, at: now(10_010))
        #expect(
            try store.spent(agent: agent.pubkey, channel: "room-1", window: day, now: now(10_020)) == 100_000
        )

        try await store.settle("attempt", state: .failed, reason: "wallet unreachable")
        #expect(
            try store.spent(agent: agent.pubkey, channel: "room-1", window: day, now: now(10_020)) == 0
        )
        // The line survives so the reader can see it happened.
        #expect(try store.spendLedger().first?.state == .failed)
    }

    /// An in-flight payment holds its share immediately, so a second intent
    /// cannot slip past while the first is still with the wallet.
    @Test("a payment in flight counts before it settles")
    func inFlightHolds() async throws {
        let (store, agent, recipient) = try await rig(allowance: 100, perZap: 100)

        let first = intent(agent, recipient, sats: 100, id: "one")
        _ = try await store.claim(first, at: now(10_010))
        // Still `paying`, and already holding the whole allowance.
        #expect(try store.spendLedger().first?.state == .paying)
        #expect(
            try store.decide(intent(agent, recipient, sats: 1, id: "two"), now: now(10_011))
                == .overAllowance(remaining: 0)
        )
    }

    @Test("updating a grant replaces its dials rather than adding a second")
    func grantIsUpserted() async throws {
        let (store, agent, _) = try await rig(allowance: 500, perZap: 100)
        try await store.grant(SpendGrant(
            agentPubkey: agent.pubkey, channelID: "room-1",
            allowanceMillisats: 1_000_000, windowSeconds: day,
            perZapMillisats: 200_000, createdAt: 0
        ))

        #expect(try store.spendGrants().count == 1)
        #expect(try store.spendGrant(agent: agent.pubkey, channel: "room-1")?.allowanceSats == 1000)
    }
}

/// Reading an intent off the wire, which is the agent's whole vocabulary.
@Suite("Zap intents")
struct ZapIntentTests {
    @Test("a well-formed intent parses")
    func parses() async throws {
        let agent = try Fixture(name: "botA")
        let recipient = try Fixture(name: "Ada")
        let event = try await Zap.intent(
            amountMillisats: 21_000,
            recipient: recipient.pubkey,
            groupID: "room-1",
            eventID: "msg-1",
            comment: "for the ramp",
            with: InMemorySigner(agent.key)
        )

        let intent = try Zap.intent(from: event)
        #expect(intent.agent == agent.pubkey)
        #expect(intent.channel == "room-1")
        #expect(intent.recipient == recipient.pubkey)
        #expect(intent.targetEventID == "msg-1")
        #expect(intent.amountSats == 21)
        #expect(intent.comment == "for the ramp")
    }

    @Test("an intent with no channel cannot be matched to a grant, so it is refused")
    func missingChannel() async throws {
        let agent = try Fixture(name: "botA")
        let event = try await NostrEvent.signed(
            kind: .buzzZapIntent, content: "",
            tags: [["p", "abc"], ["amount", "1000"]], with: agent.key
        )
        #expect(throws: Zap.IntentError.missingChannel) { try Zap.intent(from: event) }
    }

    @Test("an intent with no positive amount is refused")
    func badAmount() async throws {
        let agent = try Fixture(name: "botA")
        for raw in ["0", "-5", "lots", ""] {
            let event = try await NostrEvent.signed(
                kind: .buzzZapIntent, content: "",
                tags: [["h", "room-1"], ["p", "abc"], ["amount", raw]], with: agent.key
            )
            #expect(throws: Zap.IntentError.invalidAmount) { try Zap.intent(from: event) }
        }
    }

    @Test("the kind degrades gracefully, like every Buzz extension")
    func isAnExtension() {
        #expect(EventKind.buzzZapIntent.isBuzzExtension)
    }
}
