import CryptoKit
import Foundation
import Testing

@testable import CombCore

/// Builds the pieces of a sender-attested zap.
///
/// The invoice is assembled here rather than taken from the BOLT-11 vectors,
/// because an attestation needs a payment hash whose preimage is known, and
/// the published vectors give a hash nobody has the preimage for. The encoder
/// is deliberately minimal: a timestamp, one `p` field, and a signature-shaped
/// run of zeroes, which is all the decoder reads. `Bolt11VectorTests` is what
/// checks the decoder against somebody else's encoder.
private struct Rig {
    let payer: PrivateKey
    let recipient: PrivateKey
    let group = "room-1"
    let target = String(repeating: "a", count: 64)

    init() throws {
        payer = try PrivateKey()
        recipient = try PrivateKey()
    }

    /// `millisats: nil` builds a valid open-amount invoice, which BOLT-11
    /// allows and an attestation must refuse.
    static func invoice(millisats: Int64?, preimage: Data) -> String {
        let hash = Data(SHA256.hash(data: preimage))

        var words: [UInt8] = []
        // 35-bit timestamp, big-endian, seven words.
        let timestamp: Int64 = 1_700_000_000
        for shift in stride(from: 30, through: 0, by: -5) {
            words.append(UInt8((timestamp >> shift) & 0x1F))
        }
        // The `p` field: type 1, data_length 52.
        words += [1, UInt8(52 >> 5), UInt8(52 & 0x1F)]
        words += Bech32.words(fromBytes: Array(hash))
        // 520 bits where a signature would be. Nothing reads it.
        words += Array(repeating: 0, count: 104)

        // `n` is a hundred millisatoshis, `p` a tenth of one, so between them
        // any amount is expressible exactly.
        let amount = millisats.map { $0 % 100 == 0 ? "\($0 / 100)n" : "\($0 * 10)p" } ?? ""
        return Bech32.encode(prefix: "lnbc" + amount, words: words)
    }

    func request(
        millisats: Int64,
        target: String? = nil,
        signedBy: PrivateKey? = nil
    ) async throws -> NostrEvent {
        try await Zap.request(
            amountMillisats: millisats,
            recipient: recipient.publicKey,
            relays: [URL(string: "wss://relay.example")!],
            comment: "thanks",
            eventID: target ?? self.target,
            with: InMemorySigner(signedBy ?? payer)
        )
    }

    func attestation(
        millisats: Int64 = 21_000,
        preimage: Data = Data(repeating: 0x11, count: 32),
        invoice: String? = nil,
        request: NostrEvent? = nil,
        signedBy: PrivateKey? = nil
    ) async throws -> NostrEvent {
        let zapRequest: NostrEvent
        if let request {
            zapRequest = request
        } else {
            zapRequest = try await self.request(millisats: millisats)
        }
        return try await Zap.attestation(
            request: zapRequest,
            bolt11: invoice ?? Self.invoice(millisats: millisats, preimage: preimage),
            preimage: preimage.hex,
            groupID: group,
            with: InMemorySigner(signedBy ?? payer)
        )
    }
}

/// The happy path, and what it is actually worth.
@Suite("Zap attestation")
struct ZapAttestationTests {
    @Test("a settled invoice attests to the payment its request asked for")
    func verifies() async throws {
        let rig = try Rig()
        let event = try await rig.attestation(millisats: 21_000)

        let attested = try Zap.verifyAttestation(event)
        #expect(attested.amountMillisats == 21_000)
        #expect(attested.sender.hex == rig.payer.publicKey.hex)
        #expect(attested.recipient == rig.recipient.publicKey.hex)
        #expect(attested.targetEventID == rig.target)
        #expect(attested.comment == "thanks")
    }

    @Test("it is h-tagged, so a membership-gated relay can take it")
    func carriesTheGroup() async throws {
        let rig = try Rig()
        let event = try await rig.attestation()
        // The whole reason this kind exists rather than relaying a 9735.
        #expect(event.groupID == rig.group)
        #expect(event.kind == .buzzZapAttestation)
    }

    @Test("the kind degrades gracefully on a plain NIP-29 relay")
    func isAnExtension() {
        // A client that does not know it counts nothing, which is what it
        // counts today. Required of every Buzz kind.
        #expect(EventKind.buzzZapAttestation.isBuzzExtension)
    }

    @Test("nothing about it needs the network")
    func isOffline() async throws {
        // Stated as a test because it is what lets the projector run this at
        // write time and still replay identically.
        let rig = try Rig()
        let event = try await rig.attestation()
        #expect(throws: Never.self) { try Zap.verifyAttestation(event) }
        // Nothing above touched a URLSession, a relay, or a clock.
    }
}

/// Every way of claiming a payment that did not happen the way it is described.
@Suite("Zap attestation refusals")
struct ZapAttestationRefusalTests {
    @Test("a preimage that does not open the invoice proves nothing")
    func wrongPreimage() async throws {
        let rig = try Rig()
        // An invoice for one payment, with the preimage of another.
        let event = try await rig.attestation(
            invoice: Rig.invoice(millisats: 21_000, preimage: Data(repeating: 0x22, count: 32))
        )
        #expect(throws: Zap.AttestationError.preimageMismatch) {
            try Zap.verifyAttestation(event)
        }
    }

    @Test("claiming more than the invoice charged is refused")
    func inflatedAmount() async throws {
        let rig = try Rig()
        let preimage = Data(repeating: 0x11, count: 32)
        // Pay for 21 sats, claim 210,000.
        let event = try await rig.attestation(
            preimage: preimage,
            invoice: Rig.invoice(millisats: 21_000, preimage: preimage),
            request: try await rig.request(millisats: 210_000_000)
        )
        #expect(throws: Zap.AttestationError.amountMismatch) {
            try Zap.verifyAttestation(event)
        }
    }

    @Test("an open-amount invoice cannot stand in for a specific one")
    func openAmount() async throws {
        let rig = try Rig()
        let preimage = Data(repeating: 0x11, count: 32)
        // A genuinely valid invoice, correctly settled by this preimage, that
        // simply never committed to an amount. Everything else about the
        // attestation is in order, so this reaches the amount check rather
        // than dying earlier on a broken checksum.
        let open = Rig.invoice(millisats: nil, preimage: preimage)
        #expect(try Bolt11.decode(open).amountMillisats == nil)

        let event = try await rig.attestation(preimage: preimage, invoice: open)
        #expect(throws: Zap.AttestationError.openAmountInvoice) {
            try Zap.verifyAttestation(event)
        }
    }

    @Test("somebody else's payment cannot be published as your own")
    func stolenPayment() async throws {
        let rig = try Rig()
        let thief = try PrivateKey()
        // A genuine request and a genuine preimage, wrapped and signed by
        // someone who did not send it. Without the check this passes, and a
        // member could claim every zap they ever saw.
        let event = try await rig.attestation(signedBy: thief)
        #expect(throws: Zap.AttestationError.notTheSender) {
            try Zap.verifyAttestation(event)
        }
    }

    @Test("the request must be signed, not merely present")
    func forgedRequest() async throws {
        let rig = try Rig()
        var request = try await rig.request(millisats: 21_000)
        // Keep the signature, change what it covers.
        request = NostrEvent(
            id: request.id,
            pubkey: request.pubkey,
            createdAt: request.createdAt,
            kind: request.kind,
            tags: request.tags.map { $0.first == "amount" ? ["amount", "9999000"] : $0 },
            content: request.content,
            sig: request.sig
        )
        let event = try await rig.attestation(request: request)
        #expect(throws: Zap.AttestationError.requestInvalid) {
            try Zap.verifyAttestation(event)
        }
    }

    @Test("an attestation with no embedded request is refused")
    func noRequest() async throws {
        let rig = try Rig()
        let preimage = Data(repeating: 0x11, count: 32)
        let event = try await NostrEvent.signed(
            kind: .buzzZapAttestation,
            content: "",
            tags: [
                ["h", rig.group],
                ["bolt11", Rig.invoice(millisats: 21_000, preimage: preimage)],
                ["preimage", preimage.hex],
            ],
            with: rig.payer
        )
        #expect(throws: Zap.AttestationError.missingRequest) {
            try Zap.verifyAttestation(event)
        }
    }

    @Test("an attestation with no preimage is a claim, not a proof")
    func noPreimage() async throws {
        let rig = try Rig()
        let request = try await rig.request(millisats: 21_000)
        let event = try await NostrEvent.signed(
            kind: .buzzZapAttestation,
            content: "",
            tags: [
                ["h", rig.group],
                ["bolt11", Rig.invoice(millisats: 21_000, preimage: Data(repeating: 0x11, count: 32))],
                ["description", String(decoding: try JSONEncoder().encode(request), as: UTF8.self)],
            ],
            with: rig.payer
        )
        #expect(throws: Zap.AttestationError.missingPreimage) {
            try Zap.verifyAttestation(event)
        }
    }

    @Test("redirecting a zap to a different recipient is refused")
    func recipientSwap() async throws {
        let rig = try Rig()
        let preimage = Data(repeating: 0x11, count: 32)
        let request = try await rig.request(millisats: 21_000)
        let stranger = try PrivateKey()

        // Same signed request, but the event names somebody else as paid.
        let event = try await NostrEvent.signed(
            kind: .buzzZapAttestation,
            content: "",
            tags: [
                ["h", rig.group],
                ["bolt11", Rig.invoice(millisats: 21_000, preimage: preimage)],
                ["preimage", preimage.hex],
                ["description", String(decoding: try JSONEncoder().encode(request), as: UTF8.self)],
                ["p", stranger.publicKey.hex],
                ["e", rig.target],
            ],
            with: rig.payer
        )
        #expect(throws: Zap.AttestationError.recipientMismatch) {
            try Zap.verifyAttestation(event)
        }
    }

    @Test("moving a paid zap onto a different message is refused")
    func targetSwap() async throws {
        let rig = try Rig()
        let preimage = Data(repeating: 0x11, count: 32)
        let request = try await rig.request(millisats: 21_000)

        let event = try await NostrEvent.signed(
            kind: .buzzZapAttestation,
            content: "",
            tags: [
                ["h", rig.group],
                ["bolt11", Rig.invoice(millisats: 21_000, preimage: preimage)],
                ["preimage", preimage.hex],
                ["description", String(decoding: try JSONEncoder().encode(request), as: UTF8.self)],
                ["p", rig.recipient.publicKey.hex],
                ["e", String(repeating: "b", count: 64)],
            ],
            with: rig.payer
        )
        #expect(throws: Zap.AttestationError.targetMismatch) {
            try Zap.verifyAttestation(event)
        }
    }

    @Test("a receipt is not an attestation and vice versa")
    func wrongKind() async throws {
        let rig = try Rig()
        let request = try await rig.request(millisats: 21_000)
        let notAnAttestation = try await NostrEvent.signed(
            kind: .zapReceipt, content: "", tags: [["p", rig.recipient.publicKey.hex]],
            with: rig.payer
        )
        #expect(throws: Zap.AttestationError.notAnAttestation) {
            try Zap.verifyAttestation(notAnAttestation)
        }
        let attestation = try await rig.attestation(request: request)
        #expect(throws: Zap.ReceiptError.notAReceipt) {
            try Zap.decodeReceipt(attestation)
        }
    }
}
