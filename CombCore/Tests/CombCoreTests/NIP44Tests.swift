import Foundation
import Testing
@testable import CombCore

/// Verified against the official NIP-44 vector suite (paulmillr/nip44), which
/// every interoperating implementation tests against. A payload this code
/// produces must decrypt in Buzz's desktop client and vice versa; these
/// vectors are what that promise rests on.
enum NIP44Vectors {
    struct File: Decodable {
        let v2: V2
    }

    struct V2: Decodable {
        let valid: Valid
        let invalid: Invalid
    }

    struct Valid: Decodable {
        let get_conversation_key: [ConversationKey]
        let get_message_keys: MessageKeys
        let calc_padded_len: [[Int]]
        let encrypt_decrypt: [EncryptDecrypt]
    }

    struct Invalid: Decodable {
        let get_conversation_key: [InvalidConversationKey]
        let decrypt: [InvalidDecrypt]
    }

    struct ConversationKey: Decodable {
        let sec1: String
        let pub2: String
        let conversation_key: String
    }

    struct MessageKeys: Decodable {
        let conversation_key: String
        let keys: [Keys]

        struct Keys: Decodable {
            let nonce: String
            let chacha_key: String
            let chacha_nonce: String
            let hmac_key: String
        }
    }

    struct EncryptDecrypt: Decodable {
        let sec1: String
        let sec2: String
        let conversation_key: String
        let nonce: String
        let plaintext: String
        let payload: String
    }

    struct InvalidConversationKey: Decodable {
        let sec1: String
        let pub2: String
    }

    struct InvalidDecrypt: Decodable {
        let conversation_key: String
        let payload: String
        let note: String?
    }

    static func load() throws -> V2 {
        let url = try #require(Bundle.module.url(
            forResource: "Fixtures-nip44-vectors",
            withExtension: "json"
        ))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).v2
    }
}

@Suite("ChaCha20")
struct ChaCha20Tests {
    @Test("matches the RFC 8439 test vector")
    func rfcVector() {
        // RFC 8439 section 2.4.2: the one vector everyone implements against.
        let key = Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")!
        let nonce = Data(hex: "000000000000004a00000000")!
        let plaintext = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)

        // The RFC's ciphertext uses counter 1; NIP-44 starts at 0, so the RFC
        // stream is our stream offset by one block.
        var padded = Data(count: 64)
        padded.append(plaintext)
        let shifted = ChaCha20.process(key: key, nonce: nonce, padded)

        #expect(
            shifted.dropFirst(64).prefix(16).hex
                == "6e2e359a2568f98041ba0728dd0d6981"
        )
    }

    @Test("round trips arbitrary lengths")
    func roundTrips() {
        let key = Data(repeating: 7, count: 32)
        let nonce = Data(repeating: 3, count: 12)

        for length in [1, 63, 64, 65, 200, 1000] {
            let plaintext = Data((0..<length).map { UInt8($0 % 251) })
            let ciphertext = ChaCha20.process(key: key, nonce: nonce, plaintext)
            #expect(ciphertext != plaintext)
            #expect(ChaCha20.process(key: key, nonce: nonce, ciphertext) == plaintext)
        }
    }
}

@Suite("NIP-44 vectors")
struct NIP44VectorTests {
    @Test("derives conversation keys")
    func conversationKeys() throws {
        for vector in try NIP44Vectors.load().valid.get_conversation_key {
            let key = try PrivateKey(data: Data(hex: vector.sec1)!)
            let peer = try #require(PublicKey(hex: vector.pub2))
            let derived = try NIP44.conversationKey(privateKey: key, peer: peer)
            #expect(derived.hex == vector.conversation_key)
        }
    }

    @Test("conversation keys are symmetric")
    func symmetry() throws {
        let vector = try #require(try NIP44Vectors.load().valid.encrypt_decrypt.first)
        let alice = try PrivateKey(data: Data(hex: vector.sec1)!)
        let bob = try PrivateKey(data: Data(hex: vector.sec2)!)

        let fromAlice = try NIP44.conversationKey(privateKey: alice, peer: bob.publicKey)
        let fromBob = try NIP44.conversationKey(privateKey: bob, peer: alice.publicKey)
        #expect(fromAlice == fromBob)
        #expect(fromAlice.hex == vector.conversation_key)
    }

    @Test("derives message keys")
    func messageKeys() throws {
        let vectors = try NIP44Vectors.load().valid.get_message_keys
        let conversationKey = Data(hex: vectors.conversation_key)!

        for vector in vectors.keys {
            let keys = NIP44.messageKeys(
                conversationKey: conversationKey,
                nonce: Data(hex: vector.nonce)!
            )
            #expect(keys.chachaKey.hex == vector.chacha_key)
            #expect(keys.chachaNonce.hex == vector.chacha_nonce)
            #expect(keys.hmacKey.hex == vector.hmac_key)
        }
    }

    @Test("computes padded lengths")
    func paddedLengths() throws {
        for pair in try NIP44Vectors.load().valid.calc_padded_len {
            #expect(NIP44.paddedLength(pair[0]) == pair[1], "padding for \(pair[0])")
        }
    }

    @Test("produces byte-identical payloads with the vector nonces")
    func encryptMatchesVectors() throws {
        // Byte-identical, not merely round-tripping: any divergence here means
        // payloads other clients cannot read, or worse, subtly weaker crypto.
        for vector in try NIP44Vectors.load().valid.encrypt_decrypt {
            let payload = try NIP44.encrypt(
                vector.plaintext,
                conversationKey: Data(hex: vector.conversation_key)!,
                nonce: Data(hex: vector.nonce)!
            )
            #expect(payload == vector.payload)
        }
    }

    @Test("decrypts the vector payloads")
    func decryptMatchesVectors() throws {
        for vector in try NIP44Vectors.load().valid.encrypt_decrypt {
            let plaintext = try NIP44.decrypt(
                vector.payload,
                conversationKey: Data(hex: vector.conversation_key)!
            )
            #expect(plaintext == vector.plaintext)
        }
    }

    @Test("rejects the invalid decrypt vectors")
    func rejectsInvalid() throws {
        for vector in try NIP44Vectors.load().invalid.decrypt {
            #expect(throws: NIP44.Failure.self, "\(vector.note ?? "invalid payload")") {
                _ = try NIP44.decrypt(
                    vector.payload,
                    conversationKey: Data(hex: vector.conversation_key)!
                )
            }
        }
    }

    @Test("rejects invalid conversation key inputs")
    func rejectsInvalidKeys() throws {
        for vector in try NIP44Vectors.load().invalid.get_conversation_key {
            #expect(throws: (any Error).self) {
                let key = try PrivateKey(data: Data(hex: vector.sec1)!)
                guard let peer = PublicKey(hex: vector.pub2) else {
                    throw NIP44.Failure.malformedPayload
                }
                _ = try NIP44.conversationKey(privateKey: key, peer: peer)
            }
        }
    }
}

@Suite("NIP-44 behaviour")
struct NIP44BehaviourTests {
    private func key() throws -> Data {
        let alice = try PrivateKey()
        let bob = try PrivateKey()
        return try NIP44.conversationKey(privateKey: alice, peer: bob.publicKey)
    }

    @Test("round trips with a random nonce")
    func roundTrips() throws {
        let conversationKey = try key()
        let message = "the gutters breathe at 20 🐝"

        let payload = try NIP44.encrypt(message, conversationKey: conversationKey)
        #expect(try NIP44.decrypt(payload, conversationKey: conversationKey) == message)
    }

    @Test("a tampered payload fails authentication")
    func tamperFails() throws {
        let conversationKey = try key()
        let payload = try NIP44.encrypt("original", conversationKey: conversationKey)

        var bytes = Data(base64Encoded: payload)!
        bytes[bytes.count / 2] ^= 0x01
        let tampered = bytes.base64EncodedString()

        #expect(throws: NIP44.Failure.authenticationFailed) {
            _ = try NIP44.decrypt(tampered, conversationKey: conversationKey)
        }
    }

    @Test("the wrong conversation key fails authentication, not garbage output")
    func wrongKeyFails() throws {
        let payload = try NIP44.encrypt("secret", conversationKey: try key())

        #expect(throws: NIP44.Failure.authenticationFailed) {
            _ = try NIP44.decrypt(payload, conversationKey: try key())
        }
    }

    @Test("refuses empty and oversized plaintexts")
    func sizeBounds() throws {
        let conversationKey = try key()

        #expect(throws: NIP44.Failure.emptyPlaintext) {
            _ = try NIP44.encrypt("", conversationKey: conversationKey)
        }
        #expect(throws: NIP44.Failure.plaintextTooLong) {
            _ = try NIP44.encrypt(
                String(repeating: "a", count: 65536),
                conversationKey: conversationKey
            )
        }
    }

    @Test("surfaces a future version as upgrade, not garbage")
    func futureVersion() throws {
        #expect(throws: NIP44.Failure.unsupportedVersion(0)) {
            _ = try NIP44.decrypt("#future-scheme", conversationKey: try key())
        }
    }
}
