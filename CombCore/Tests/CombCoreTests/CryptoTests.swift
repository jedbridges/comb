import Foundation
import Testing
@testable import CombCore

@Suite("Hex")
struct HexTests {
    @Test("round trips arbitrary bytes")
    func roundTrip() {
        let data = Data([0x00, 0x01, 0x7F, 0x80, 0xFF, 0xAB])
        #expect(data.hex == "00017f80ffab")
        #expect(Data(hex: data.hex) == data)
    }

    @Test("always encodes lowercase")
    func lowercase() {
        #expect(Data([0xDE, 0xAD, 0xBE, 0xEF]).hex == "deadbeef")
    }

    @Test("accepts uppercase input when decoding")
    func decodesUppercase() {
        #expect(Data(hex: "DEADBEEF") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("rejects malformed input")
    func rejectsMalformed() {
        #expect(Data(hex: "abc") == nil)       // odd length
        #expect(Data(hex: "zz") == nil)        // non-hex
        #expect(Data(hex: "ab cd") == nil)     // embedded space
    }

    @Test("handles empty input")
    func empty() {
        #expect(Data().hex == "")
        #expect(Data(hex: "") == Data())
    }
}

@Suite("Bech32")
struct Bech32Tests {
    // Cross-checked against an independent Python implementation. The nsec is
    // the published NIP-19 specification vector.
    static let pubkeyHex = "6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93"
    static let npub = "npub1dergggklka99wwrs92yz8wdjs952h2ux2ha2ed598ngwu9w7a6fsh9xzpc"
    static let seckeyHex = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"
    static let nsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"

    @Test("encodes the NIP-19 npub vector")
    func encodesNpub() {
        let data = Data(hex: Self.pubkeyHex)!
        #expect(Bech32.encode(prefix: "npub", data: data) == Self.npub)
    }

    @Test("encodes the NIP-19 nsec vector")
    func encodesNsec() {
        let data = Data(hex: Self.seckeyHex)!
        #expect(Bech32.encode(prefix: "nsec", data: data) == Self.nsec)
    }

    @Test("decodes back to the original bytes")
    func decodes() throws {
        let (prefix, data) = try Bech32.decode(Self.npub)
        #expect(prefix == "npub")
        #expect(data.hex == Self.pubkeyHex)
    }

    @Test("rejects a corrupted checksum")
    func rejectsBadChecksum() {
        // Flip one character in the data part.
        var corrupted = Array(Self.npub)
        corrupted[10] = corrupted[10] == "q" ? "p" : "q"
        #expect(throws: Bech32.Error.invalidChecksum) {
            try Bech32.decode(String(corrupted))
        }
    }

    @Test("rejects mixed case")
    func rejectsMixedCase() {
        #expect(throws: Bech32.Error.mixedCase) {
            try Bech32.decode("NPUB1dergggklka99wwrs92yz8wdjs952h2ux2ha2ed598ngwu9w7a6fsh9xzpc")
        }
    }

    @Test("rejects a string with no separator")
    func rejectsNoSeparator() {
        #expect(throws: Bech32.Error.missingSeparator) {
            try Bech32.decode("npubdefinitelynotvalid")
        }
    }

    @Test("decode32 enforces the expected prefix")
    func enforcesPrefix() {
        // Handing an nsec to something expecting an npub must fail loudly
        // rather than silently treating a secret as a public key.
        #expect(throws: Bech32.Error.self) {
            try Bech32.decode32(Self.nsec, expecting: "npub")
        }
    }
}

@Suite("Keys")
struct KeyTests {
    @Test("parses a known nsec and re-encodes it")
    func parsesNsec() throws {
        let key = try PrivateKey(nsec: Bech32Tests.nsec)
        #expect(key.data.hex == Bech32Tests.seckeyHex)
        #expect(key.nsec == Bech32Tests.nsec)
    }

    @Test("derives a 32-byte x-only public key")
    func derivesPublicKey() throws {
        let key = try PrivateKey(nsec: Bech32Tests.nsec)
        #expect(key.publicKey.data.count == 32)
        // Derivation must be deterministic across calls.
        #expect(key.publicKey == key.publicKey)
    }

    @Test("generates distinct identities")
    func generatesDistinct() throws {
        let first = try PrivateKey()
        let second = try PrivateKey()
        #expect(first.data != second.data)
        #expect(first.publicKey != second.publicKey)
    }

    @Test("signs and verifies a 32-byte message")
    func signVerify() throws {
        let key = try PrivateKey()
        let message = Data(SHA256Digest.of("comb"))
        let signature = try key.signMessage(message)

        #expect(signature.count == 64)
        #expect(verifySignature(signature, message: message, publicKey: key.publicKey))
    }

    @Test("rejects a signature from a different key")
    func rejectsWrongKey() throws {
        let signer = try PrivateKey()
        let impostor = try PrivateKey()
        let message = Data(SHA256Digest.of("comb"))
        let signature = try signer.signMessage(message)

        #expect(!verifySignature(signature, message: message, publicKey: impostor.publicKey))
    }

    @Test("rejects a signature over a different message")
    func rejectsWrongMessage() throws {
        let key = try PrivateKey()
        let signature = try key.signMessage(Data(SHA256Digest.of("original")))

        #expect(!verifySignature(
            signature,
            message: Data(SHA256Digest.of("tampered")),
            publicKey: key.publicKey
        ))
    }

    @Test("produces distinct signatures for the same message")
    func nonDeterministicNonce() throws {
        // BIP-340 auxiliary randomness means two signatures over identical input
        // should differ. Identical output would mean the randomness is not being
        // applied, which weakens nonce derivation.
        let key = try PrivateKey()
        let message = Data(SHA256Digest.of("comb"))
        let first = try key.signMessage(message)
        let second = try key.signMessage(message)

        #expect(first != second)
        #expect(verifySignature(first, message: message, publicKey: key.publicKey))
        #expect(verifySignature(second, message: message, publicKey: key.publicKey))
    }

    @Test("rejects keys of the wrong length")
    func rejectsBadLength() {
        #expect(throws: CryptoError.invalidKeyLength(31)) {
            try PrivateKey(data: Data(repeating: 1, count: 31))
        }
    }

    @Test("refuses to sign a message that is not 32 bytes")
    func refusesNonDigest() throws {
        let key = try PrivateKey()
        #expect(throws: CryptoError.invalidMessageLength(5)) {
            try key.signMessage(Data([1, 2, 3, 4, 5]))
        }
    }

    @Test("never leaks the secret through string interpolation")
    func redactsDescription() throws {
        let key = try PrivateKey(nsec: Bech32Tests.nsec)
        #expect(!"\(key)".contains(Bech32Tests.seckeyHex))
        #expect(!String(describing: key).contains("vl029"))
    }
}

/// Small helper so tests can build 32-byte messages without importing CryptoKit
/// separately from the P256K re-export.
enum SHA256Digest {
    static func of(_ string: String) -> Data {
        NostrEvent.computeID(
            pubkey: String(repeating: "0", count: 64),
            createdAt: 0,
            kind: .textNote,
            tags: [],
            content: string
        )
    }
}
