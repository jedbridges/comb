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
