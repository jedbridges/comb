import Foundation
import Testing

@testable import CombCore

/// A wallet on the other end of a connection, so a round trip can be tested
/// without a relay.
private struct Wallet {
    let key: PrivateKey
    let connection: NWC.Connection

    init() throws {
        key = try PrivateKey()
        connection = NWC.Connection(
            walletPubkey: key.publicKey,
            relays: [URL(string: "wss://relay.getalby.com/v1")!],
            secret: try PrivateKey()
        )
    }

    /// Encrypts a reply as the wallet would, with the same conversation key.
    func reply(_ body: [String: Any], to request: NostrEvent) throws -> NostrEvent {
        let json = try JSONSerialization.data(withJSONObject: body)
        let conversationKey = try NIP44.conversationKey(
            privateKey: key,
            peer: connection.secret.publicKey
        )
        return try NostrEvent.signed(
            kind: .nwcResponse,
            content: try NIP44.encrypt(
                String(decoding: json, as: UTF8.self),
                conversationKey: conversationKey
            ),
            tags: [["p", connection.secret.publicKey.hex], ["e", request.id]],
            with: key
        )
    }

    func info(encryption: String?) throws -> NostrEvent {
        var tags: [[String]] = []
        if let encryption { tags.append(["encryption", encryption]) }
        return try NostrEvent.signed(
            kind: .nwcInfo,
            content: "pay_invoice get_balance get_info",
            tags: tags,
            with: key
        )
    }
}

@Suite("NWC connection URI")
struct NWCConnectionTests {
    private let pubkey = "b889ff5b1513b641e2a139f661a661364979c5beee91842f8f0ef42ab558e9d4"
    private let secret = "71a8c14c1407c113601079c4302dab36460f0ccd0ad506f1f2dc73b5100e4f3c"

    @Test("the URI from the spec parses")
    func specExample() throws {
        let uri = "nostr+walletconnect://\(pubkey)?relay=wss%3A%2F%2Frelay.damus.io&secret=\(secret)"
        let connection = try NWC.connection(from: uri)

        #expect(connection.walletPubkey.hex == pubkey)
        #expect(connection.relays.map(\.absoluteString) == ["wss://relay.damus.io"])
        #expect(connection.secret.publicKey.hex.count == 64)
        #expect(connection.lightningAddress == nil)
    }

    @Test("the older scheme spelling is accepted")
    func legacyScheme() throws {
        // Wallets print both, and the reader pastes what they were shown.
        let uri = "nostrwalletconnect://\(pubkey)?relay=wss%3A%2F%2Fr.example&secret=\(secret)"
        #expect(throws: Never.self) { try NWC.connection(from: uri) }
    }

    @Test("more than one relay is kept in order")
    func multipleRelays() throws {
        let uri = "nostr+walletconnect://\(pubkey)"
            + "?relay=wss%3A%2F%2Fone.example&relay=wss%3A%2F%2Ftwo.example&secret=\(secret)"
        #expect(try NWC.connection(from: uri).relays.count == 2)
        #expect(try NWC.connection(from: uri).relays.first?.host() == "one.example")
    }

    @Test("a lightning address is carried when present")
    func lud16() throws {
        let uri = "nostr+walletconnect://\(pubkey)"
            + "?relay=wss%3A%2F%2Fr.example&secret=\(secret)&lud16=me%40example.com"
        #expect(try NWC.connection(from: uri).lightningAddress == "me@example.com")
    }

    @Test("surrounding whitespace from a paste is tolerated")
    func pastedWithWhitespace() throws {
        let uri = "\n  nostr+walletconnect://\(pubkey)?relay=wss%3A%2F%2Fr.example&secret=\(secret) \n"
        #expect(throws: Never.self) { try NWC.connection(from: uri) }
    }

    @Test("something that is not a wallet URI is refused")
    func notAWalletURI() throws {
        #expect(throws: NWC.ConnectionError.notAWalletURI) {
            try NWC.connection(from: "https://example.com")
        }
        #expect(throws: NWC.ConnectionError.notAWalletURI) {
            try NWC.connection(from: "")
        }
    }

    @Test("a cleartext relay is refused, because the secret travels over it")
    func insecureRelay() throws {
        // The whole credential is in this URI and every request is signed with
        // it. ws:// to a host on the internet is not a compatibility question.
        let uri = "nostr+walletconnect://\(pubkey)?relay=ws%3A%2F%2Fr.example&secret=\(secret)"
        #expect(throws: NWC.ConnectionError.insecureRelay) { try NWC.connection(from: uri) }

        let http = "nostr+walletconnect://\(pubkey)?relay=https%3A%2F%2Fr.example&secret=\(secret)"
        #expect(throws: NWC.ConnectionError.insecureRelay) { try NWC.connection(from: http) }
    }

    @Test("loopback over cleartext is allowed, for a wallet on this machine")
    func loopbackAllowed() throws {
        let uri = "nostr+walletconnect://\(pubkey)?relay=ws%3A%2F%2Flocalhost%3A8080&secret=\(secret)"
        #expect(throws: Never.self) { try NWC.connection(from: uri) }
    }

    @Test("a URI with no relay or no secret is refused")
    func missingPieces() throws {
        #expect(throws: NWC.ConnectionError.missingRelay) {
            try NWC.connection(from: "nostr+walletconnect://\(pubkey)?secret=\(secret)")
        }
        #expect(throws: NWC.ConnectionError.missingSecret) {
            try NWC.connection(from: "nostr+walletconnect://\(pubkey)?relay=wss%3A%2F%2Fr.example")
        }
    }

    @Test("a secret that is not a 32-byte key is refused")
    func malformedSecret() throws {
        #expect(throws: NWC.ConnectionError.malformedSecret) {
            try NWC.connection(from: "nostr+walletconnect://\(pubkey)?relay=wss%3A%2F%2Fr.e&secret=abcd")
        }
    }

    @Test("a malformed wallet pubkey is refused")
    func malformedPubkey() throws {
        #expect(throws: NWC.ConnectionError.malformedWalletPubkey) {
            try NWC.connection(from: "nostr+walletconnect://nothex?relay=wss%3A%2F%2Fr.e&secret=\(secret)")
        }
    }
}

/// The encryption negotiation, which decides whether Comb will talk to a wallet
/// at all.
@Suite("NWC encryption negotiation")
struct NWCEncryptionTests {
    @Test("a wallet advertising nip44_v2 is accepted")
    func supported() throws {
        let wallet = try Wallet()
        #expect(NWC.supportsNIP44(info: try wallet.info(encryption: "nip44_v2 nip04")))
        #expect(NWC.supportsNIP44(info: try wallet.info(encryption: "nip44_v2")))
    }

    /// NIP-47 says absence means NIP-04 only, so this is a definite no rather
    /// than an unknown. Comb does not implement NIP-04 and will not: it is
    /// unauthenticated, and carrying spend authorisation over it to gain
    /// compatibility is the wrong trade.
    @Test("a wallet advertising nothing is treated as nip04 only, and refused")
    func absenceMeansNIP04() throws {
        let wallet = try Wallet()
        #expect(!NWC.supportsNIP44(info: try wallet.info(encryption: nil)))
        #expect(!NWC.supportsNIP44(info: try wallet.info(encryption: "nip04")))
    }

    @Test("a wallet's supported methods are read from the info content")
    func methods() throws {
        let wallet = try Wallet()
        let methods = NWC.methods(info: try wallet.info(encryption: "nip44_v2"))
        #expect(methods.contains("pay_invoice"))
        #expect(methods.count == 3)
    }

    @Test("an event that is not an info event supports nothing")
    func wrongKind() throws {
        let key = try PrivateKey()
        let note = try NostrEvent.signed(
            kind: .textNote, content: "", tags: [["encryption", "nip44_v2"]], with: key
        )
        #expect(!NWC.supportsNIP44(info: note))
    }
}

@Suite("NWC requests")
struct NWCRequestTests {
    @Test("a pay_invoice request is encrypted, tagged and signed by the secret")
    func payInvoice() throws {
        let wallet = try Wallet()
        let request = try NWC.payInvoice("lnbc210n1xyz", connection: wallet.connection)

        #expect(request.kind == .nwcRequest)
        // Signed by the connection secret, not by any community identity, so a
        // zap paid here is not linkable to the key posting in a room.
        #expect(request.pubkey == wallet.connection.secret.publicKey.hex)
        #expect(request.firstValue(for: "p") == wallet.key.publicKey.hex)
        #expect(request.firstValue(for: "encryption") == "nip44_v2")
        #expect(request.isValid)

        // The invoice must not be readable by the relay carrying it.
        #expect(!request.content.contains("lnbc210n1xyz"))

        let key = try NIP44.conversationKey(
            privateKey: wallet.key,
            peer: wallet.connection.secret.publicKey
        )
        let plaintext = try NIP44.decrypt(request.content, conversationKey: key)
        #expect(plaintext.contains("pay_invoice"))
        #expect(plaintext.contains("lnbc210n1xyz"))
    }

    @Test("the request lands in the ephemeral band, so it is never stored")
    func isEphemeral() {
        // Load-bearing rather than incidental: it is what keeps a spend request
        // and the preimage answering it out of the event log entirely.
        #expect(EventKind.nwcRequest.isEphemeral)
        #expect(EventKind.nwcResponse.isEphemeral)
        #expect(!EventKind.nwcRequest.isBuzzExtension)
    }
}

@Suite("NWC responses")
struct NWCResponseTests {
    @Test("a settled payment hands back its preimage")
    func paid() throws {
        let wallet = try Wallet()
        let request = try NWC.payInvoice("lnbc1", connection: wallet.connection)
        let response = try wallet.reply([
            "result_type": "pay_invoice",
            "result": ["preimage": "aabbcc", "fees_paid": 12],
        ], to: request)

        #expect(
            try NWC.outcome(of: response, connection: wallet.connection)
                == .paid(preimage: "aabbcc", feesPaid: 12)
        )
    }

    @Test("a payment with no fee reported is still a payment")
    func paidWithoutFees() throws {
        let wallet = try Wallet()
        let request = try NWC.payInvoice("lnbc1", connection: wallet.connection)
        let response = try wallet.reply([
            "result_type": "pay_invoice", "result": ["preimage": "ddeeff"],
        ], to: request)

        #expect(
            try NWC.outcome(of: response, connection: wallet.connection)
                == .paid(preimage: "ddeeff", feesPaid: nil)
        )
    }

    /// The case that matters most. A preimage is what Comb publishes as proof of
    /// payment, so a wallet claiming settlement without one is claiming
    /// something unprovable.
    @Test("a settlement with no preimage is refused rather than believed")
    func settledWithoutPreimage() throws {
        let wallet = try Wallet()
        let request = try NWC.payInvoice("lnbc1", connection: wallet.connection)

        for result in [[:] as [String: Any], ["preimage": ""], ["preimage": "not hex"]] {
            let response = try wallet.reply(
                ["result_type": "pay_invoice", "result": result], to: request
            )
            #expect(throws: NWC.ResponseError.missingPreimage) {
                try NWC.outcome(of: response, connection: wallet.connection)
            }
        }
    }

    /// Without this a hostile participant on the wallet's relay could hand Comb
    /// a preimage and have it published as a payment the reader made.
    @Test("a response from a key that is not the wallet is refused")
    func wrongWallet() throws {
        let wallet = try Wallet()
        let impostor = try PrivateKey()
        let request = try NWC.payInvoice("lnbc1", connection: wallet.connection)

        // Encrypted to the right conversation, signed by the wrong key.
        let conversationKey = try NIP44.conversationKey(
            privateKey: impostor, peer: wallet.connection.secret.publicKey
        )
        let response = try NostrEvent.signed(
            kind: .nwcResponse,
            content: try NIP44.encrypt(
                #"{"result_type":"pay_invoice","result":{"preimage":"aabb"}}"#,
                conversationKey: conversationKey
            ),
            tags: [["e", request.id]],
            with: impostor
        )

        #expect(throws: NWC.ResponseError.wrongWallet) {
            try NWC.outcome(of: response, connection: wallet.connection)
        }
    }

    @Test("a refusal keeps the wallet's own code and words")
    func refused() throws {
        let wallet = try Wallet()
        let request = try NWC.payInvoice("lnbc1", connection: wallet.connection)
        let response = try wallet.reply([
            "result_type": "pay_invoice",
            "error": ["code": "INSUFFICIENT_BALANCE", "message": "balance is 3 sats"],
        ], to: request)

        #expect(
            try NWC.outcome(of: response, connection: wallet.connection)
                == .refused(code: "INSUFFICIENT_BALANCE", message: "balance is 3 sats")
        )
    }

    @Test("a wallet's message cannot forge line breaks or run long")
    func sanitisesWalletText() throws {
        // Written by whoever runs the wallet and rendered in a sheet in Comb.
        #expect(NWC.sanitized("one\n\ntwo   three") == "one two three")
        #expect(NWC.sanitized(String(repeating: "x", count: 400)).count == 120)
    }

    @Test("a refusal reads as something the reader can act on")
    func describesRefusals() {
        // Printing the code would waste the only information the failure had:
        // an empty balance is the reader's to fix and an internal error is not.
        #expect(NWC.describe(code: "INSUFFICIENT_BALANCE", message: "").contains("enough"))
        #expect(NWC.describe(code: "UNAUTHORIZED", message: "").contains("revoked"))
        #expect(NWC.describe(code: "WHAT_IS_THIS", message: "").contains("could not pay"))
        #expect(NWC.describe(code: "PAYMENT_FAILED", message: "no route").hasSuffix("It said: no route"))
    }

    @Test("a response Comb cannot decrypt is refused, not guessed at")
    func undecryptable() throws {
        let wallet = try Wallet()
        let response = try NostrEvent.signed(
            kind: .nwcResponse, content: "not a nip44 payload", tags: [], with: wallet.key
        )
        #expect(throws: NWC.ResponseError.undecryptable) {
            try NWC.outcome(of: response, connection: wallet.connection)
        }
    }

    @Test("a non-payment answer is reported as answered, not as paid")
    func otherMethods() throws {
        let wallet = try Wallet()
        let request = try NWC.request(method: .getInfo, connection: wallet.connection)
        let response = try wallet.reply([
            "result_type": "get_info", "result": ["alias": "my node"],
        ], to: request)

        #expect(try NWC.outcome(of: response, connection: wallet.connection) == .answered)
    }

    @Test("an event that is not a response is refused")
    func wrongKind() throws {
        let wallet = try Wallet()
        let note = try NostrEvent.signed(kind: .textNote, content: "", with: wallet.key)
        #expect(throws: NWC.ResponseError.notAResponse) {
            try NWC.outcome(of: note, connection: wallet.connection)
        }
    }
}
