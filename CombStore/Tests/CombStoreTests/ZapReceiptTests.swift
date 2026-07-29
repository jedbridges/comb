import CombCore
import Foundation
import GRDB
import Testing
@testable import CombStore

@Suite("Zap receipts")
struct ZapReceiptTests {
    /// A kind 9735 wrapping a signed 9734, as a wallet would publish it.
    private func receipt(
        sender: Fixture,
        recipient: Fixture,
        issuer: Fixture,
        amount: Int64 = 21_000,
        target: String? = "msg-1",
        bolt11: String = "lnbc210n1...",
        at seconds: Int64 = 1_100
    ) throws -> NostrEvent {
        let request = try Zap.request(
            amountMillisats: amount,
            recipient: recipient.key.publicKey,
            relays: [URL(string: "wss://relay.example")!],
            comment: "for the good post",
            eventID: target,
            with: sender.key
        )
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)

        return try issuer.event(
            .zapReceipt,
            tags: [
                ["p", recipient.pubkey],
                ["bolt11", bolt11],
                ["description", json],
            ],
            at: seconds
        )
    }

    /// A channel with one message to hang zaps off.
    private func room(_ store: EventStore, author: Fixture) async throws -> NostrEvent {
        let message = try author.event(
            .groupChatMessage, "worth something", tags: [["h", "room-1"]], at: 1_000
        )
        _ = try await store.ingest([
            try author.event(
                .groupMetadata, #"{"name":"General"}"#, tags: [["d", "room-1"]], at: 900
            ),
            message,
        ])
        return message
    }

    @Test("a receipt becomes a zap on the message it names")
    func projectsAZap() async throws {
        let store = try EventStore()
        let author = try Fixture(name: "Ada")
        let sender = try Fixture(name: "Bob")
        let wallet = try Fixture()

        let message = try await room(store, author: author)
        _ = try await store.ingest([
            try receipt(sender: sender, recipient: author, issuer: wallet, target: message.id),
        ])

        let zaps = try store.zapTotals(for: [message.id])
        let summary = try #require(zaps[message.id])
        #expect(summary.totalSats == 21)
        #expect(summary.count == 1)
    }

    /// The sender comes from the embedded request, which the sender signed, not
    /// from the receipt's own pubkey. That is what makes it unforgeable.
    @Test("the sender is taken from the signed request, not the receipt")
    func senderComesFromTheRequest() async throws {
        let store = try EventStore()
        let author = try Fixture(name: "Ada")
        let sender = try Fixture(name: "Bob")
        let wallet = try Fixture()

        let message = try await room(store, author: author)
        _ = try await store.ingest([
            try receipt(sender: sender, recipient: author, issuer: wallet, target: message.id),
        ])

        let zappers = try store.zappers(for: message.id)
        #expect(zappers.count == 1)
        #expect(zappers.first?.pubkey == sender.pubkey)
        #expect(zappers.first?.comment == "for the good post")
    }

    /// The replay defence. A hostile relay cannot inflate a total by
    /// republishing a genuine receipt under fresh event ids.
    @Test("the same payment republished counts once")
    func deduplicatesOnBolt11() async throws {
        let store = try EventStore()
        let author = try Fixture(name: "Ada")
        let sender = try Fixture(name: "Bob")
        let wallet = try Fixture()

        let message = try await room(store, author: author)
        _ = try await store.ingest([
            try receipt(
                sender: sender, recipient: author, issuer: wallet,
                target: message.id, bolt11: "lnbc-same", at: 1_100
            ),
            try receipt(
                sender: sender, recipient: author, issuer: wallet,
                target: message.id, bolt11: "lnbc-same", at: 1_200
            ),
        ])

        let summary = try #require(try store.zapTotals(for: [message.id])[message.id])
        #expect(summary.count == 1)
        #expect(summary.totalSats == 21)
    }

    /// Same rule as reactions: someone the reader asked never to see again does
    /// not get to come back as a number on a message.
    @Test("a blocked sender's zap is not counted")
    func excludesBlockedSenders() async throws {
        let store = try EventStore()
        let author = try Fixture(name: "Ada")
        let sender = try Fixture(name: "Bob")
        let wallet = try Fixture()

        let message = try await room(store, author: author)
        _ = try await store.ingest([
            try receipt(sender: sender, recipient: author, issuer: wallet, target: message.id),
        ])
        try await store.block(pubkey: sender.pubkey)

        #expect(try store.zapTotals(for: [message.id]).isEmpty)
        #expect(try store.zappers(for: message.id).isEmpty)
    }

    /// A 9735 is signed by the recipient's wallet, so its sender cannot delete
    /// it. Honouring a kind 5 from anyone else would hand every member of the
    /// relay a way to erase other people's zaps.
    @Test("a third party's deletion does not erase a zap")
    func ignoresDeletions() async throws {
        let store = try EventStore()
        let author = try Fixture(name: "Ada")
        let sender = try Fixture(name: "Bob")
        let wallet = try Fixture()
        let vandal = try Fixture()

        let message = try await room(store, author: author)
        let event = try receipt(
            sender: sender, recipient: author, issuer: wallet, target: message.id
        )
        _ = try await store.ingest([
            event,
            try vandal.event(.deletion, tags: [["e", event.id]], at: 1_300),
        ])

        #expect(try store.zapTotals(for: [message.id])[message.id]?.count == 1)
    }

    /// A receipt whose embedded request will not verify writes no row. It stays
    /// in the log, like an unauthorised deletion.
    @Test("a receipt with no embedded request is stored but not counted")
    func skipsUndecodableReceipts() async throws {
        let store = try EventStore()
        let author = try Fixture(name: "Ada")
        let wallet = try Fixture()

        let message = try await room(store, author: author)
        _ = try await store.ingest([
            try wallet.event(
                .zapReceipt,
                tags: [["p", author.pubkey], ["bolt11", "lnbc-nothing"]],
                at: 1_100
            ),
        ])

        #expect(try store.zapTotals(for: [message.id]).isEmpty)
    }

    /// Without a cached endpoint key there is no way to tell a genuine receipt
    /// from one someone minted for themselves, and the UI has to be able to say
    /// so rather than presenting both as the same number.
    @Test("issuersKnown is false until the reader has zapped that recipient")
    func reportsWhetherIssuersAreKnown() async throws {
        let store = try EventStore()
        let author = try Fixture(name: "Ada")
        let sender = try Fixture(name: "Bob")
        let wallet = try Fixture()

        let message = try await room(store, author: author)
        _ = try await store.ingest([
            try receipt(sender: sender, recipient: author, issuer: wallet, target: message.id),
        ])

        #expect(try store.zapTotals(for: [message.id])[message.id]?.issuersKnown == false)

        // Sending a zap to the same person is what teaches Comb that key.
        try await store.recordZapAttempt(
            requestID: "req-1", targetID: nil, recipient: author.pubkey,
            issuer: wallet.pubkey, amountMillisats: 1_000
        )

        #expect(try store.zapTotals(for: [message.id])[message.id]?.issuersKnown == true)
    }

    @Test("zaps survive a projection rebuild unchanged")
    func rebuildsIdentically() async throws {
        let store = try EventStore()
        let author = try Fixture(name: "Ada")
        let sender = try Fixture(name: "Bob")
        let wallet = try Fixture()

        let message = try await room(store, author: author)
        _ = try await store.ingest([
            try receipt(sender: sender, recipient: author, issuer: wallet, target: message.id),
        ])

        let before = try store.zapTotals(for: [message.id])
        try await store.rebuildProjections()
        #expect(try store.zapTotals(for: [message.id]) == before)
    }
}

extension EventStore {
    /// Test-side access to the aggregate the timeline observation uses.
    nonisolated func zapTotals(for ids: [String]) throws -> [String: ZapSummary] {
        try reader.read { db in try EventStore.fetchZaps(db, for: ids, me: nil) }
    }
}

/// The pending marker's whole life: it appears at handoff, disappears when its
/// receipt lands, and expires if one never does.
@Suite("Pending zap resolution")
struct PendingZapResolutionTests {
    @Test("a receipt for the attempt stops it being pending")
    func receiptResolvesTheAttempt() async throws {
        let store = try EventStore()
        let author = try Fixture(name: "Ada")
        let sender = try Fixture(name: "Bob")
        let wallet = try Fixture()

        let message = try author.event(
            .groupChatMessage, "worth something", tags: [["h", "room-1"]], at: 1_000
        )
        _ = try await store.ingest([message])

        let request = try Zap.request(
            amountMillisats: 21_000,
            recipient: author.key.publicKey,
            relays: [URL(string: "wss://relay.example")!],
            comment: "",
            eventID: message.id,
            with: sender.key
        )
        try await store.recordZapAttempt(
            requestID: request.id,
            targetID: message.id,
            recipient: author.pubkey,
            issuer: wallet.pubkey,
            amountMillisats: 21_000
        )
        #expect(try store.pendingZapAttempts().count == 1)

        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        _ = try await store.ingest([
            try wallet.event(
                .zapReceipt,
                tags: [
                    ["p", author.pubkey],
                    ["bolt11", "lnbc-paid"],
                    ["description", json],
                ],
                at: 1_100
            ),
        ])

        // The claim is gone and the attested total has taken its place.
        #expect(try store.pendingZapAttempts().isEmpty)
        #expect(try store.zapTotals(for: [message.id])[message.id]?.totalSats == 21)
    }
}

/// The upgrade an existing install actually takes: a database written before
/// the `zap` table existed, opened by a build that expects it.
@Suite("Projection version 8 upgrade")
struct ZapProjectionUpgradeTests {
    @Test("an older database gains the zap table and keeps its local state")
    func upgradesFromSeven() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("comb-upgrade-\(UUID().uuidString).sqlite")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let author = try Fixture(name: "Ada")
        let sender = try Fixture(name: "Bob")
        let wallet = try Fixture()
        let message = try author.event(
            .groupChatMessage, "worth something", tags: [["h", "room-1"]], at: 1_000
        )

        let request = try Zap.request(
            amountMillisats: 21_000,
            recipient: author.key.publicKey,
            relays: [URL(string: "wss://relay.example")!],
            eventID: message.id,
            with: sender.key
        )
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let receiptEvent = try wallet.event(
            .zapReceipt,
            tags: [
                ["p", author.pubkey],
                ["bolt11", "lnbc-upgrade"],
                ["description", json],
            ],
            at: 1_100
        )

        do {
            let store = try EventStore(path: path)
            _ = try await store.ingest([message, receiptEvent])
            try await store.recordZapAttempt(
                requestID: "some-older-attempt",
                targetID: message.id,
                recipient: author.pubkey,
                issuer: wallet.pubkey,
                amountMillisats: 5_000
            )

        }

        // Wind the database back to how a build without zaps left it: the log
        // intact, the projection table absent, the version stale. Done on a
        // separate connection, because the store deliberately hands out a
        // reader and nothing else.
        try await DatabaseQueue(path: path).write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS zap")
            try db.execute(sql: """
                INSERT INTO meta (key, value) VALUES ('projection_version', '7')
                ON CONFLICT(key) DO UPDATE SET value = '7'
                """)
        }

        // Reopening runs the migrations and the staleness check, which is the
        // code path a real upgrade takes.
        let upgraded = try EventStore(path: path)

        // The receipt was in the log all along and is now counted.
        #expect(try upgraded.zapTotals(for: [message.id])[message.id]?.totalSats == 21)

        // And the local tables, which no rebuild may touch, are still here.
        #expect(try upgraded.cachedIssuer(for: author.pubkey) == wallet.pubkey)
        #expect(try upgraded.pendingZapAttempts().count == 1)
    }
}
