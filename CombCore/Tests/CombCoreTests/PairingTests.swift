import Foundation
import Testing
@testable import CombCore

/// Vectors produced by an independent Python implementation of secp256k1 scalar
/// multiplication and RFC 5869 HKDF, not by this code.
///
/// That implementation is itself checked against RFC 5869 Test Case 1, which
/// caught a dropped counter byte in its HKDF expand step. Without that check the
/// vectors would have been confidently wrong and this file would have "proved"
/// the Swift matched them by being changed to agree.
///
/// Every derivation here has to agree byte for byte with Buzz's desktop client
/// or the two devices compute different session ids and never find each other.
/// Testing this implementation against itself would prove nothing about that.
enum PairingVector {
    static let privateKeyA = "0000000000000000000000000000000000000000000000000000000000000003"
    static let privateKeyB = "00000000000000000000000000000000000000000000000000000000000000f1"
    static let publicKeyA = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"
    static let publicKeyB = "7985fdfd127c0567c6f53ec1bb63ec3158e597c40bfe747c83cddfc910641917"
    static let sessionSecret = String(repeating: "a1", count: 32)

    static let sharedSecret = "3273472718537d38e9b8c397a5cc322d1c77c0c615eded39dcebc020debe2205"
    static let sessionID = "aec9786105f2930d391035217ca6eb6afdcd45035a068316f983fdfb678d48a0"
    static let sasInput = "2d5549c27e27fe0684bef3c5d8aacdcf3264d0f5823492d80a584da196da1ce0"
    static let sasCode = "564162"
    static let transcriptHash = "5c75cdd1b9bc5e5243a6914852e0c3fc878532d028bf3ab76053ccb24c098447"

    static var keyA: PrivateKey { try! PrivateKey(data: Data(hex: privateKeyA)!) }
    static var keyB: PrivateKey { try! PrivateKey(data: Data(hex: privateKeyB)!) }
    static var pubA: PublicKey { PublicKey(hex: publicKeyA)! }
    static var pubB: PublicKey { PublicKey(hex: publicKeyB)! }
    static var secret: Data { Data(hex: sessionSecret)! }
}

@Suite("Pairing key agreement")
struct PairingKeyAgreementTests {
    @Test("derives the public keys the vectors expect")
    func derivesPublicKeys() {
        #expect(PairingVector.keyA.publicKey.hex == PairingVector.publicKeyA)
        #expect(PairingVector.keyB.publicKey.hex == PairingVector.publicKeyB)
    }

    @Test("computes the raw unhashed x-coordinate")
    func computesSharedSecret() throws {
        // The usual secp256k1 ECDH hashes the shared point with SHA-256. This
        // protocol feeds the bare coordinate into HKDF, so taking the default
        // would silently produce a different secret than the other device and
        // pairing would fail with no useful error.
        let shared = try Pairing.sharedSecret(
            privateKey: PairingVector.keyA,
            peer: PairingVector.pubB
        )
        #expect(shared.hex == PairingVector.sharedSecret)
        #expect(shared.count == 32)
    }

    @Test("both devices agree on the same secret")
    func agreementIsSymmetric() throws {
        // The whole point of ECDH, and the thing that breaks first if either
        // side lifts the x-only key with the wrong parity.
        let fromA = try Pairing.sharedSecret(
            privateKey: PairingVector.keyA,
            peer: PairingVector.pubB
        )
        let fromB = try Pairing.sharedSecret(
            privateKey: PairingVector.keyB,
            peer: PairingVector.pubA
        )
        #expect(fromA == fromB)
    }

    @Test("a different peer yields a different secret")
    func differentPeerDiffers() throws {
        let stranger = try PrivateKey()
        let shared = try Pairing.sharedSecret(
            privateKey: PairingVector.keyA,
            peer: stranger.publicKey
        )
        #expect(shared.hex != PairingVector.sharedSecret)
    }
}

@Suite("Pairing derivations")
struct PairingDerivationTests {
    @Test("derives the session id from the QR secret alone")
    func derivesSessionID() {
        // Both devices need this before they have agreed on anything, which is
        // how they find each other on the pairing relay.
        let id = Pairing.sessionID(sessionSecret: PairingVector.secret)
        #expect(id.hex == PairingVector.sessionID)
    }

    @Test("derives the short authentication string")
    func derivesSAS() {
        let sas = Pairing.shortAuthentication(
            sharedSecret: Data(hex: PairingVector.sharedSecret)!,
            sessionSecret: PairingVector.secret
        )
        #expect(sas.input.hex == PairingVector.sasInput)
        #expect(sas.code == PairingVector.sasCode)
        #expect(sas.code.count == 6)
    }

    @Test("zero-pads a small code to six digits")
    func padsShortCodes() {
        // One time in a thousand the value is under 100000. A five-digit code
        // on one device and six on the other is a comparison people will fail.
        let sas = Pairing.shortAuthentication(
            sharedSecret: Data(repeating: 0, count: 32),
            sessionSecret: Data(repeating: 0, count: 32)
        )
        // Computed outside the macro: #expect cannot expand a rethrowing call.
        let isAllDigits = sas.code.allSatisfy(\.isNumber)
        #expect(sas.code.count == 6)
        #expect(isAllDigits)
    }

    @Test("the SAS depends on the QR secret, not just the shared secret")
    func sasBindsToSession() {
        // This is what makes a machine in the middle visible. It can complete
        // ECDH, but it never saw the QR code, so it cannot produce matching
        // digits for the humans to compare.
        let shared = Data(hex: PairingVector.sharedSecret)!
        let other = Pairing.shortAuthentication(
            sharedSecret: shared,
            sessionSecret: Data(repeating: 0x99, count: 32)
        )
        #expect(other.code != PairingVector.sasCode)
    }

    @Test("derives the transcript hash over every session parameter")
    func derivesTranscriptHash() {
        let hash = Pairing.transcriptHash(
            sessionID: Data(hex: PairingVector.sessionID)!,
            sourcePubkey: PairingVector.pubA,
            targetPubkey: PairingVector.pubB,
            sasInput: Data(hex: PairingVector.sasInput)!,
            sessionSecret: PairingVector.secret
        )
        #expect(hash.hex == PairingVector.transcriptHash)
    }

    @Test("the transcript changes if the identities are swapped")
    func transcriptIsOrdered() {
        // Order matters: source and target are distinct roles, and a transcript
        // that ignored the order would let an attacker swap them after the
        // digits have been read aloud.
        let swapped = Pairing.transcriptHash(
            sessionID: Data(hex: PairingVector.sessionID)!,
            sourcePubkey: PairingVector.pubB,
            targetPubkey: PairingVector.pubA,
            sasInput: Data(hex: PairingVector.sasInput)!,
            sessionSecret: PairingVector.secret
        )
        #expect(swapped.hex != PairingVector.transcriptHash)
    }

    @Test("compares transcripts without an early exit")
    func constantTimeComparison() {
        let value = Data(hex: PairingVector.transcriptHash)!
        var differsAtEnd = value
        differsAtEnd[31] ^= 0x01
        var differsAtStart = value
        differsAtStart[0] ^= 0x01

        #expect(Pairing.constantTimeEquals(value, value))
        #expect(!Pairing.constantTimeEquals(value, differsAtEnd))
        #expect(!Pairing.constantTimeEquals(value, differsAtStart))
        #expect(!Pairing.constantTimeEquals(value, value.dropLast()))
    }
}

@Suite("nostrpair URI")
struct PairingURITests {
    static func uri(
        pubkey: String = PairingVector.publicKeyA,
        secret: String = PairingVector.sessionSecret,
        relay: String = "wss%3A%2F%2Fpairing.buzz.xyz",
        version: String = "1"
    ) -> String {
        "nostrpair://\(pubkey)?secret=\(secret)&relay=\(relay)&v=\(version)"
    }

    @Test("parses a well-formed invitation")
    func parsesValid() throws {
        let invitation = try Pairing.parse(Self.uri())

        #expect(invitation.sourcePubkey.hex == PairingVector.publicKeyA)
        #expect(invitation.sessionSecret.hex == PairingVector.sessionSecret)
        #expect(invitation.relays.map(\.absoluteString) == ["wss://pairing.buzz.xyz"])
        #expect(invitation.version == 1)
    }

    @Test("accepts several relays")
    func parsesMultipleRelays() throws {
        let uri = "nostrpair://\(PairingVector.publicKeyA)"
            + "?secret=\(PairingVector.sessionSecret)"
            + "&relay=wss%3A%2F%2Fone.example&relay=wss%3A%2F%2Ftwo.example"
        #expect(try Pairing.parse(uri).relays.count == 2)
    }

    @Test("defaults to version 1")
    func defaultsVersion() throws {
        let uri = "nostrpair://\(PairingVector.publicKeyA)"
            + "?secret=\(PairingVector.sessionSecret)&relay=wss%3A%2F%2Fa.example"
        #expect(try Pairing.parse(uri).version == 1)
    }

    @Test("rejects a future protocol version")
    func rejectsFutureVersion() {
        // Better to tell someone to update than to guess at a handshake whose
        // rules have changed.
        #expect(throws: PairingError.unsupportedVersion(2)) {
            try Pairing.parse(Self.uri(version: "2"))
        }
    }

    @Test("rejects an all-zero session secret")
    func rejectsZeroSecret() {
        // Means the offering device generated no randomness, which makes the
        // session id and the SAS predictable to anyone watching.
        #expect(throws: PairingError.invalidSessionSecret) {
            try Pairing.parse(Self.uri(secret: String(repeating: "00", count: 32)))
        }
    }

    @Test("rejects uppercase hex")
    func rejectsUppercaseHex() {
        // The spec fixes lowercase, and accepting both would mean two devices
        // could hash the same logical value differently.
        #expect(throws: PairingError.invalidPubkey) {
            try Pairing.parse(Self.uri(pubkey: PairingVector.publicKeyA.uppercased()))
        }
        #expect(throws: PairingError.invalidSessionSecret) {
            try Pairing.parse(Self.uri(secret: PairingVector.sessionSecret.uppercased()))
        }
    }

    @Test("rejects a non-websocket relay")
    func rejectsBadRelay() {
        // This URL comes from a camera pointed at an arbitrary screen. An
        // http:// entry here would be somewhere to send an identity.
        #expect(throws: PairingError.self) {
            try Pairing.parse(Self.uri(relay: "https%3A%2F%2Fevil.example"))
        }
    }

    @Test("requires at least one relay")
    func requiresRelay() {
        let uri = "nostrpair://\(PairingVector.publicKeyA)?secret=\(PairingVector.sessionSecret)"
        #expect(throws: PairingError.noRelays) { try Pairing.parse(uri) }
    }

    @Test("rejects malformed input")
    func rejectsMalformed() {
        #expect(throws: PairingError.notAPairingURI) {
            try Pairing.parse("https://example.com")
        }
        #expect(throws: PairingError.missingQuery) {
            try Pairing.parse("nostrpair://\(PairingVector.publicKeyA)")
        }
        #expect(throws: PairingError.invalidPubkey) {
            try Pairing.parse("nostrpair://tooshort?secret=\(PairingVector.sessionSecret)")
        }
        #expect(throws: PairingError.uriTooLong) {
            try Pairing.parse(Pairing.uriScheme + String(repeating: "a", count: 3000))
        }
    }

    @Test("ignores unknown query parameters")
    func ignoresUnknownParameters() throws {
        // Forward compatibility: a newer desktop build may add parameters this
        // version does not know about, and refusing them would break pairing
        // for no reason.
        let uri = Self.uri() + "&future=whatever"
        #expect(try Pairing.parse(uri).version == 1)
    }
}

@Suite("Pairing round trip")
struct PairingRoundTripTests {
    @Test("two devices reach the same code and transcript")
    func fullHandshake() throws {
        // The whole flow as it runs in the app: desktop offers, phone scans,
        // both derive independently and must land on identical values.
        let desktop = try PrivateKey()
        let phone = try PrivateKey()
        let sessionSecret = Data((0..<32).map { _ in UInt8.random(in: 1...255) })

        let uri = "nostrpair://\(desktop.publicKey.hex)"
            + "?secret=\(sessionSecret.hex)&relay=wss%3A%2F%2Fpairing.buzz.xyz&v=1"
        let invitation = try Pairing.parse(uri)

        let phoneShared = try Pairing.sharedSecret(
            privateKey: phone,
            peer: invitation.sourcePubkey
        )
        let desktopShared = try Pairing.sharedSecret(
            privateKey: desktop,
            peer: phone.publicKey
        )
        #expect(phoneShared == desktopShared)

        let phoneSAS = Pairing.shortAuthentication(
            sharedSecret: phoneShared,
            sessionSecret: invitation.sessionSecret
        )
        let desktopSAS = Pairing.shortAuthentication(
            sharedSecret: desktopShared,
            sessionSecret: sessionSecret
        )
        #expect(phoneSAS.code == desktopSAS.code, "the humans must see the same digits")

        let sessionID = Pairing.sessionID(sessionSecret: sessionSecret)
        let phoneTranscript = Pairing.transcriptHash(
            sessionID: sessionID,
            sourcePubkey: desktop.publicKey,
            targetPubkey: phone.publicKey,
            sasInput: phoneSAS.input,
            sessionSecret: sessionSecret
        )
        let desktopTranscript = Pairing.transcriptHash(
            sessionID: sessionID,
            sourcePubkey: desktop.publicKey,
            targetPubkey: phone.publicKey,
            sasInput: desktopSAS.input,
            sessionSecret: sessionSecret
        )
        #expect(Pairing.constantTimeEquals(phoneTranscript, desktopTranscript))
    }

    @Test("an interloper cannot produce matching digits")
    func interloperFails() throws {
        // A machine in the middle can complete ECDH with each side, but it never
        // saw the QR code. Both ends salt the SAS with that secret, so the
        // digits diverge and the humans notice.
        let desktop = try PrivateKey()
        let phone = try PrivateKey()
        let attacker = try PrivateKey()
        let realSecret = Data(repeating: 0x11, count: 32)

        let honest = Pairing.shortAuthentication(
            sharedSecret: try Pairing.sharedSecret(privateKey: phone, peer: desktop.publicKey),
            sessionSecret: realSecret
        )
        let intercepted = Pairing.shortAuthentication(
            sharedSecret: try Pairing.sharedSecret(privateKey: phone, peer: attacker.publicKey),
            sessionSecret: realSecret
        )

        #expect(honest.code != intercepted.code)
    }
}
