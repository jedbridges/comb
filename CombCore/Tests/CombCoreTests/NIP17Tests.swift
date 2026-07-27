import Foundation
import Testing
@testable import CombCore

@Suite("NIP-17 private messages")
struct NIP17Tests {
    @Test("a wrapped message opens for its recipient")
    func roundTrip() throws {
        let alice = try PrivateKey()
        let bob = try PrivateKey()

        let wraps = try NIP17.wrap(
            content: "meet at six",
            to: [bob.publicKey.hex],
            from: alice
        )
        let forBob = try #require(wraps.first { $0.tags.contains(["p", bob.publicKey.hex]) })

        let message = try NIP17.open(giftWrap: forBob, recipient: bob)
        #expect(message.content == "meet at six")
        #expect(message.sender == alice.publicKey.hex)
        #expect(message.recipients == [bob.publicKey.hex])
    }

    @Test("the sender gets a copy addressed to themselves")
    func copyToSelf() throws {
        // Without it a sent message is unreadable by the person who sent it:
        // a gift wrap opens for exactly one key, and that key was the
        // recipient's.
        let alice = try PrivateKey()
        let bob = try PrivateKey()

        let wraps = try NIP17.wrap(content: "meet at six", to: [bob.publicKey.hex], from: alice)
        #expect(wraps.count == 2)

        let forAlice = try #require(wraps.first { $0.tags.contains(["p", alice.publicKey.hex]) })
        #expect(try NIP17.open(giftWrap: forAlice, recipient: alice).content == "meet at six")
    }

    @Test("addressing yourself does not produce two copies")
    func selfAddressedIsNotDuplicated() throws {
        let alice = try PrivateKey()
        let wraps = try NIP17.wrap(
            content: "note to self",
            to: [alice.publicKey.hex],
            from: alice
        )
        #expect(wraps.count == 1)
    }

    @Test("a stranger cannot open it")
    func strangerCannotOpen() throws {
        let alice = try PrivateKey()
        let bob = try PrivateKey()
        let eve = try PrivateKey()

        let wraps = try NIP17.wrap(content: "secret", to: [bob.publicKey.hex], from: alice)
        let forBob = try #require(wraps.first { $0.tags.contains(["p", bob.publicKey.hex]) })

        #expect(throws: NIP17.Failure.malformed) {
            try NIP17.open(giftWrap: forBob, recipient: eve)
        }
    }

    @Test("the wrap's own key says nothing about the sender")
    func wrapKeyIsThrowaway() throws {
        // If the wrap were signed by the sender, the relay would learn who was
        // talking to whom just by reading the envelope.
        let alice = try PrivateKey()
        let bob = try PrivateKey()

        let wraps = try NIP17.wrap(content: "hello", to: [bob.publicKey.hex], from: alice)
        for wrap in wraps {
            #expect(wrap.pubkey != alice.publicKey.hex)
            #expect(wrap.pubkey != bob.publicKey.hex)
        }
        // And never the same key twice, or the relay could link them.
        #expect(Set(wraps.map(\.pubkey)).count == wraps.count)
    }

    @Test("a rumor claiming someone else is refused")
    func refusesImpersonation() throws {
        // The attack the scheme turns on. A rumor is unsigned, so Eve can put
        // Alice's pubkey in one, seal it herself, and send it to Bob. Only the
        // seal signature establishes the sender, and it says Eve.
        let alice = try PrivateKey()
        let bob = try PrivateKey()
        let eve = try PrivateKey()

        let forgedRumor = NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: alice.publicKey.hex,
            createdAt: 1_700_000_000,
            kind: .directMessage,
            tags: [["p", bob.publicKey.hex]],
            content: "transfer the money",
            sig: ""
        )

        let wrap = try handWrap(rumor: forgedRumor, sealedBy: eve, to: bob)

        #expect(throws: NIP17.Failure.senderMismatch) {
            try NIP17.open(giftWrap: wrap, recipient: bob)
        }
    }

    @Test("a seal that does not verify is refused")
    func refusesBrokenSeal() throws {
        let bob = try PrivateKey()
        let eve = try PrivateKey()

        let rumor = NostrEvent(
            id: String(repeating: "0", count: 64),
            pubkey: eve.publicKey.hex,
            createdAt: 1_700_000_000,
            kind: .directMessage,
            tags: [["p", bob.publicKey.hex]],
            content: "hello",
            sig: ""
        )

        let wrap = try handWrap(rumor: rumor, sealedBy: eve, to: bob, corruptSeal: true)

        #expect(throws: NIP17.Failure.unverifiedSeal) {
            try NIP17.open(giftWrap: wrap, recipient: bob)
        }
    }

    @Test("only a gift wrap is accepted")
    func refusesOtherKinds() throws {
        let bob = try PrivateKey()
        let note = try NostrEvent.signed(kind: .groupChatMessage, content: "hi", with: bob)

        #expect(throws: NIP17.Failure.notAGiftWrap) {
            try NIP17.open(giftWrap: note, recipient: bob)
        }
    }

    @Test("the id is recomputed rather than believed")
    func recomputesID() throws {
        // An unsigned rumor's id is not vouched for by anything, so a sender
        // could claim any id they liked and collide with a real message.
        let alice = try PrivateKey()
        let bob = try PrivateKey()

        let rumor = NostrEvent(
            id: String(repeating: "f", count: 64),
            pubkey: alice.publicKey.hex,
            createdAt: 1_700_000_000,
            kind: .directMessage,
            tags: [["p", bob.publicKey.hex]],
            content: "hello",
            sig: ""
        )
        let wrap = try handWrap(rumor: rumor, sealedBy: alice, to: bob)

        let message = try NIP17.open(giftWrap: wrap, recipient: bob)
        #expect(message.id != String(repeating: "f", count: 64))
        #expect(message.id == NostrEvent.computeID(
            pubkey: rumor.pubkey,
            createdAt: rumor.createdAt,
            kind: rumor.kind,
            tags: rumor.tags,
            content: rumor.content
        ).hex)
    }

    @Test("the wrap is backdated so the relay cannot time the conversation")
    func wrapIsBackdated() throws {
        let alice = try PrivateKey()
        let bob = try PrivateKey()
        let now = Int64(Date().timeIntervalSince1970)

        // Repeated, because the fuzz is random and a single draw could land
        // near zero by chance.
        var sawBackdating = false
        for _ in 0..<12 {
            let wraps = try NIP17.wrap(content: "hi", to: [bob.publicKey.hex], from: alice)
            let wrap = try #require(wraps.first)
            #expect(wrap.createdAt <= now)
            if wrap.createdAt < now - 60 { sawBackdating = true }
        }
        #expect(sawBackdating)
    }

    @Test("the subject rides through")
    func carriesSubject() throws {
        let alice = try PrivateKey()
        let bob = try PrivateKey()

        let wraps = try NIP17.wrap(
            content: "about the grid",
            to: [bob.publicKey.hex],
            subject: "Grid",
            from: alice
        )
        let forBob = try #require(wraps.first { $0.tags.contains(["p", bob.publicKey.hex]) })
        #expect(try NIP17.open(giftWrap: forBob, recipient: bob).subject == "Grid")
    }

    /// Builds the two inner layers by hand, so a test can put something in them
    /// that `wrap` would never produce.
    private func handWrap(
        rumor: NostrEvent,
        sealedBy sender: PrivateKey,
        to recipient: PrivateKey,
        corruptSeal: Bool = false
    ) throws -> NostrEvent {
        let rumorJSON = String(decoding: try JSONEncoder().encode(rumor), as: UTF8.self)

        var seal = try NostrEvent.signed(
            kind: .seal,
            content: try NIP44.encrypt(
                rumorJSON,
                conversationKey: try NIP44.conversationKey(
                    privateKey: sender, peer: recipient.publicKey
                )
            ),
            with: sender
        )
        if corruptSeal {
            // Same signature over different content: the id no longer matches,
            // which is exactly what full validation is for.
            seal = NostrEvent(
                id: seal.id,
                pubkey: seal.pubkey,
                createdAt: seal.createdAt,
                kind: seal.kind,
                tags: seal.tags,
                content: seal.content,
                sig: String(repeating: "0", count: 128)
            )
        }

        let ephemeral = try PrivateKey()
        return try NostrEvent.signed(
            kind: .giftWrap,
            content: try NIP44.encrypt(
                String(decoding: try JSONEncoder().encode(seal), as: UTF8.self),
                conversationKey: try NIP44.conversationKey(
                    privateKey: ephemeral, peer: recipient.publicKey
                )
            ),
            tags: [["p", recipient.publicKey.hex]],
            with: ephemeral
        )
    }
}
