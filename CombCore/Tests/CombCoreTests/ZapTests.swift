import Foundation
import Testing
@testable import CombCore

@Suite("Lightning address")
struct LightningAddressTests {
    @Test("resolves to a well-known lnurlp URL")
    func resolves() throws {
        let address = try #require(Zap.LightningAddress("jed@getalby.com"))
        #expect(address.name == "jed")
        #expect(address.host == "getalby.com")
        #expect(address.lnurlpURL?.absoluteString
            == "https://getalby.com/.well-known/lnurlp/jed")
    }

    @Test("rejects malformed addresses")
    func rejectsMalformed() {
        #expect(Zap.LightningAddress("no-at-sign") == nil)
        #expect(Zap.LightningAddress("@host.com") == nil)
        #expect(Zap.LightningAddress("name@") == nil)
        #expect(Zap.LightningAddress("name@nodot") == nil)
        #expect(Zap.LightningAddress("name@host/path") == nil)
    }
}

@Suite("Pay endpoint")
struct PayEndpointTests {
    @Test("recognises a Nostr-capable endpoint")
    func nostrCapable() throws {
        let json = """
        {"callback":"https://getalby.com/lnurl/pay","minSendable":1000,
         "maxSendable":100000000,"allowsNostr":true,
         "nostrPubkey":"aabbccdd00112233445566778899aabbccddeeff00112233445566778899aabb"}
        """
        let endpoint = try JSONDecoder().decode(Zap.PayEndpoint.self, from: Data(json.utf8))
        #expect(endpoint.supportsNostrZaps)
        #expect(endpoint.minSendable == 1000)
    }

    @Test("a plain endpoint without Nostr support is flagged")
    func plainEndpoint() throws {
        // Falls back to a plain lightning: payment with no verifiable receipt.
        let json = """
        {"callback":"https://x/pay","minSendable":1000,"maxSendable":1000000}
        """
        let endpoint = try JSONDecoder().decode(Zap.PayEndpoint.self, from: Data(json.utf8))
        #expect(!endpoint.supportsNostrZaps)
    }
}

@Suite("Zap request")
struct ZapRequestTests {
    @Test("builds a signed kind 9734 with the required tags")
    func buildsRequest() throws {
        let sender = try PrivateKey()
        let recipient = try PrivateKey()
        let request = try Zap.request(
            amountMillisats: 21000,
            recipient: recipient.publicKey,
            relays: [URL(string: "wss://designers.communities.buzz.xyz")!],
            comment: "great work 🐝",
            eventID: "abc123",
            with: sender
        )

        #expect(request.kind == .zapRequest)
        #expect(request.isValid)
        #expect(request.firstValue(for: "amount") == "21000")
        #expect(request.firstValue(for: "p") == recipient.publicKey.hex)
        #expect(request.firstValue(for: "e") == "abc123")
        #expect(request.content == "great work 🐝")

        let relayTag = try #require(request.tags.first { $0.first == "relays" })
        #expect(relayTag.contains("wss://designers.communities.buzz.xyz"))
    }

    @Test("omits the event tag for a profile zap")
    func profileZap() throws {
        let request = try Zap.request(
            amountMillisats: 1000,
            recipient: try PrivateKey().publicKey,
            relays: [],
            with: try PrivateKey()
        )
        #expect(request.firstValue(for: "e") == nil)
    }
}

@Suite("Zap receipt verification")
struct ZapReceiptTests {
    /// Builds a valid receipt the way an honest LNURL wallet would: the signed
    /// zap request embedded in the description tag, receipt signed by the
    /// wallet's own key.
    private func makeReceipt(
        sender: PrivateKey,
        recipient: PublicKey,
        issuer: PrivateKey,
        amount: Int64 = 21000,
        eventID: String? = "target-event",
        overrideRecipient: String? = nil
    ) throws -> NostrEvent {
        let request = try Zap.request(
            amountMillisats: amount,
            recipient: recipient,
            relays: [URL(string: "wss://relay.example")!],
            comment: "nice",
            eventID: eventID,
            with: sender
        )
        let requestJSON = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)

        return try NostrEvent.signed(
            kind: .zapReceipt,
            content: "",
            tags: [
                ["p", overrideRecipient ?? recipient.hex],
                ["bolt11", "lnbc210n1..."],
                ["description", requestJSON],
            ],
            with: issuer
        )
    }

    @Test("accepts and extracts a well-formed receipt")
    func acceptsValid() throws {
        let sender = try PrivateKey()
        let recipient = try PrivateKey()
        let wallet = try PrivateKey()

        let receiptEvent = try makeReceipt(
            sender: sender, recipient: recipient.publicKey, issuer: wallet
        )
        let receipt = try Zap.verifyReceipt(receiptEvent, expectedIssuer: wallet.publicKey)

        #expect(receipt.amountMillisats == 21000)
        #expect(receipt.sender == sender.publicKey)
        #expect(receipt.recipient == recipient.publicKey.hex)
        #expect(receipt.targetEventID == "target-event")
        #expect(receipt.comment == "nice")
    }

    @Test("rejects a receipt signed by the wrong issuer")
    func rejectsWrongIssuer() throws {
        // The core forgery defence: a receipt must be signed by the pubkey the
        // LNURL endpoint advertised, not by whoever published it to the relay.
        let sender = try PrivateKey()
        let recipient = try PrivateKey()
        let realWallet = try PrivateKey()
        let forger = try PrivateKey()

        let forged = try makeReceipt(
            sender: sender, recipient: recipient.publicKey, issuer: forger
        )
        #expect(throws: Zap.ReceiptError.wrongIssuer) {
            _ = try Zap.verifyReceipt(forged, expectedIssuer: realWallet.publicKey)
        }
    }

    @Test("rejects a receipt whose recipient was swapped")
    func rejectsRecipientSwap() throws {
        // A wallet cannot honestly redirect someone else's zap to a different
        // recipient; the receipt's p tag must match the signed request's.
        let sender = try PrivateKey()
        let recipient = try PrivateKey()
        let wallet = try PrivateKey()
        let attacker = try PrivateKey()

        let tampered = try makeReceipt(
            sender: sender,
            recipient: recipient.publicKey,
            issuer: wallet,
            overrideRecipient: attacker.publicKey.hex
        )
        #expect(throws: Zap.ReceiptError.recipientMismatch) {
            _ = try Zap.verifyReceipt(tampered, expectedIssuer: wallet.publicKey)
        }
    }

    @Test("rejects a receipt with no embedded request")
    func rejectsMissingRequest() throws {
        let wallet = try PrivateKey()
        let receipt = try NostrEvent.signed(
            kind: .zapReceipt,
            content: "",
            tags: [["p", "abc"], ["bolt11", "lnbc..."]],
            with: wallet
        )
        #expect(throws: Zap.ReceiptError.missingRequest) {
            _ = try Zap.verifyReceipt(receipt, expectedIssuer: wallet.publicKey)
        }
    }

    @Test("rejects a receipt missing its invoice")
    func rejectsMissingBolt11() throws {
        let wallet = try PrivateKey()
        let receipt = try NostrEvent.signed(
            kind: .zapReceipt, content: "", tags: [["p", "abc"]], with: wallet
        )
        #expect(throws: Zap.ReceiptError.missingBolt11) {
            _ = try Zap.verifyReceipt(receipt, expectedIssuer: wallet.publicKey)
        }
    }

    @Test("rejects a non-receipt event")
    func rejectsWrongKind() throws {
        let key = try PrivateKey()
        let note = try NostrEvent.signed(kind: .textNote, content: "hi", with: key)
        #expect(throws: Zap.ReceiptError.notAReceipt) {
            _ = try Zap.verifyReceipt(note, expectedIssuer: key.publicKey)
        }
    }
}
