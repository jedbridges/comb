import CryptoKit
import Foundation

/// NIP-44 v2 encrypted payloads.
///
/// The encryption pairing and Nostr Wallet Connect both speak. The scheme is
/// ECDH (raw x-coordinate) → HKDF conversation key → per-message keys →
/// ChaCha20 with a separate HMAC-SHA256, padded so message lengths leak less.
/// Everything here is verified against the official NIP-44 vector suite.
public enum NIP44 {
    public enum Failure: Error, Equatable {
        case emptyPlaintext
        case plaintextTooLong
        case malformedPayload
        case unsupportedVersion(UInt8)
        case authenticationFailed
        case invalidPadding
    }

    static let version: UInt8 = 2
    static let minPlaintext = 1
    static let maxPlaintext = 65535

    // MARK: - Keys

    /// The long-lived key both directions of a conversation share.
    ///
    /// Symmetric by construction: conversationKey(a, B) == conversationKey(b, A),
    /// because the ECDH x-coordinate is the same shared point either way.
    public static func conversationKey(
        privateKey: PrivateKey,
        peer: PublicKey
    ) throws -> Data {
        let shared = try Pairing.sharedSecret(privateKey: privateKey, peer: peer)
        let prk = CryptoKit.HKDF<CryptoKit.SHA256>.extract(
            inputKeyMaterial: CryptoKit.SymmetricKey(data: shared),
            salt: Data("nip44-v2".utf8)
        )
        return prk.withUnsafeBytes { Data($0) }
    }

    /// Per-message keys, derived from the conversation key and a fresh nonce.
    static func messageKeys(
        conversationKey: Data,
        nonce: Data
    ) -> (chachaKey: Data, chachaNonce: Data, hmacKey: Data) {
        let expanded = CryptoKit.HKDF<CryptoKit.SHA256>.expand(
            pseudoRandomKey: CryptoKit.SymmetricKey(data: conversationKey),
            info: nonce,
            outputByteCount: 76
        )
        let bytes = expanded.withUnsafeBytes { Data($0) }
        return (
            chachaKey: bytes[bytes.startIndex..<bytes.startIndex + 32],
            chachaNonce: bytes[bytes.startIndex + 32..<bytes.startIndex + 44],
            hmacKey: bytes[bytes.startIndex + 44..<bytes.startIndex + 76]
        )
    }

    // MARK: - Padding

    /// The padded length for a plaintext, per the spec's power-of-two scheme.
    /// Coarser buckets as messages grow, so length leaks less than it would
    /// byte-for-byte.
    static func paddedLength(_ unpadded: Int) -> Int {
        guard unpadded > 32 else { return 32 }
        let nextPower = 1 << (Int.bitWidth - (unpadded - 1).leadingZeroBitCount)
        let chunk = nextPower <= 256 ? 32 : nextPower / 8
        return chunk * ((unpadded - 1) / chunk + 1)
    }

    static func pad(_ plaintext: Data) throws -> Data {
        guard plaintext.count >= minPlaintext else { throw Failure.emptyPlaintext }
        guard plaintext.count <= maxPlaintext else { throw Failure.plaintextTooLong }

        var out = Data(capacity: 2 + paddedLength(plaintext.count))
        out.append(UInt8(plaintext.count >> 8))
        out.append(UInt8(plaintext.count & 0xFF))
        out.append(plaintext)
        out.append(Data(count: paddedLength(plaintext.count) - plaintext.count))
        return out
    }

    static func unpad(_ padded: Data) throws -> Data {
        guard padded.count >= 2 else { throw Failure.invalidPadding }
        let bytes = [UInt8](padded)
        let length = Int(bytes[0]) << 8 | Int(bytes[1])

        guard length >= minPlaintext, length <= maxPlaintext,
              padded.count == 2 + paddedLength(length)
        else { throw Failure.invalidPadding }

        return Data(bytes[2..<2 + length])
    }

    // MARK: - Encrypt / decrypt

    public static func encrypt(
        _ plaintext: String,
        conversationKey: Data,
        nonce: Data? = nil
    ) throws -> String {
        let nonce = nonce ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let keys = messageKeys(conversationKey: conversationKey, nonce: nonce)

        let padded = try pad(Data(plaintext.utf8))
        let ciphertext = ChaCha20.process(key: keys.chachaKey, nonce: keys.chachaNonce, padded)

        // The MAC covers nonce plus ciphertext, so neither can be swapped
        // against the other.
        var authenticated = nonce
        authenticated.append(ciphertext)
        let mac = CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(
            for: authenticated,
            using: CryptoKit.SymmetricKey(data: keys.hmacKey)
        )

        var payload = Data([version])
        payload.append(nonce)
        payload.append(ciphertext)
        payload.append(Data(mac))
        return payload.base64EncodedString()
    }

    public static func decrypt(_ payload: String, conversationKey: Data) throws -> String {
        // A leading '#' marks a version this client cannot read, distinct from
        // garbage: the spec wants "upgrade" surfaced differently than "broken".
        guard !payload.hasPrefix("#") else { throw Failure.unsupportedVersion(0) }
        guard payload.count >= 132, payload.count <= 87472,
              let data = Data(base64Encoded: payload)
        else { throw Failure.malformedPayload }

        // version(1) + nonce(32) + ciphertext(>=34) + mac(32)
        guard data.count >= 99 else { throw Failure.malformedPayload }
        guard data[data.startIndex] == version else {
            throw Failure.unsupportedVersion(data[data.startIndex])
        }

        let nonce = data[data.startIndex + 1..<data.startIndex + 33]
        let ciphertext = data[data.startIndex + 33..<data.endIndex - 32]
        let mac = data[data.endIndex - 32..<data.endIndex]

        let keys = messageKeys(conversationKey: conversationKey, nonce: Data(nonce))

        var authenticated = Data(nonce)
        authenticated.append(ciphertext)
        // Constant-time comparison; a byte-by-byte early exit would leak the
        // expected MAC under repeated attempts.
        guard CryptoKit.HMAC<CryptoKit.SHA256>.isValidAuthenticationCode(
            mac,
            authenticating: authenticated,
            using: CryptoKit.SymmetricKey(data: keys.hmacKey)
        ) else { throw Failure.authenticationFailed }

        let padded = ChaCha20.process(
            key: keys.chachaKey,
            nonce: keys.chachaNonce,
            Data(ciphertext)
        )
        let plaintext = try unpad(padded)

        guard let string = String(data: plaintext, encoding: .utf8) else {
            throw Failure.invalidPadding
        }
        return string
    }
}
