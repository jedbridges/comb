import Foundation
import P256K

/// A 32-byte x-only secp256k1 public key: a Nostr identity.
public struct PublicKey: Hashable, Sendable, Codable {
    /// The raw 32-byte x-only key.
    public let data: Data

    public init?(data: Data) {
        guard data.count == 32 else { return nil }
        self.data = data
    }

    public init?(hex: String) {
        guard let data = Data(hex: hex), data.count == 32 else { return nil }
        self.data = data
    }

    /// Parses a NIP-19 `npub1...` identifier.
    public init(npub: String) throws {
        self.data = try Bech32.decode32(npub, expecting: "npub")
    }

    /// Lowercase hex, the form used in event fields and filters.
    public var hex: String { data.hex }

    /// NIP-19 `npub1...`, the form shown to humans.
    public var npub: String { Bech32.encode(prefix: "npub", data: data) }

    /// A short, recognisable prefix for display when no profile name is known.
    public var abbreviated: String {
        let npub = npub
        return String(npub.prefix(12)) + "…" + String(npub.suffix(6))
    }

    // Encoded as plain hex so events and cached state stay wire-shaped.
    public init(from decoder: any Decoder) throws {
        let hex = try decoder.singleValueContainer().decode(String.self)
        guard let key = PublicKey(hex: hex) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid pubkey: \(hex)")
            )
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// A secp256k1 secret key.
///
/// Deliberately not `Codable`, not `Equatable`, and redacted in its description.
/// The only way this leaves the process is through `data` or `nsec`, both of
/// which are call sites worth auditing. Persistence belongs in the Keychain.
public struct PrivateKey: Sendable {
    /// The raw 32-byte scalar.
    ///
    /// The libsecp256k1-backed key object is rebuilt per operation rather than
    /// stored. It wraps a C context that is not `Sendable`, and holding one
    /// would make this type unusable across actor boundaries. Reconstruction is
    /// cheap next to the signing itself.
    public let data: Data

    /// Generates a new identity from the system CSPRNG.
    public init() throws {
        self.data = try P256K.Schnorr.PrivateKey().dataRepresentation
    }

    public init(data: Data) throws {
        guard data.count == 32 else { throw CryptoError.invalidKeyLength(data.count) }
        // Validated eagerly so an out-of-range scalar fails here rather than at
        // the first attempt to sign.
        _ = try P256K.Schnorr.PrivateKey(dataRepresentation: data)
        self.data = data
    }

    /// Parses a NIP-19 `nsec1...` identifier.
    public init(nsec: String) throws {
        try self.init(data: try Bech32.decode32(nsec, expecting: "nsec"))
    }

    /// NIP-19 `nsec1...`. Treat every call site as a secret-disclosure boundary.
    public var nsec: String { Bech32.encode(prefix: "nsec", data: data) }

    public var publicKey: PublicKey {
        // Both operations are structurally guaranteed by the validated `data`,
        // so a failure here would mean a libsecp256k1 bug.
        let backing = try! P256K.Schnorr.PrivateKey(dataRepresentation: data)
        return PublicKey(data: Data(backing.xonly.bytes))!
    }

    /// Produces a BIP-340 signature over a 32-byte message.
    ///
    /// Nostr signs the event id, which is already a SHA-256 digest, so the bytes
    /// are signed as-is with no further hashing.
    public func signMessage(_ message: Data) throws -> Data {
        guard message.count == 32 else { throw CryptoError.invalidMessageLength(message.count) }
        let backing = try P256K.Schnorr.PrivateKey(dataRepresentation: data)
        var bytes = Array(message)
        var auxiliary = [UInt8](repeating: 0, count: 32)
        // Fresh auxiliary randomness per BIP-340, guarding nonce derivation
        // against fault attacks.
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &auxiliary) == errSecSuccess else {
            throw CryptoError.randomnessUnavailable
        }
        let signature = try auxiliary.withUnsafeMutableBytes { pointer in
            try backing.signature(
                message: &bytes,
                auxiliaryRand: pointer.baseAddress,
                strict: true
            )
        }
        return signature.dataRepresentation
    }
}

extension PrivateKey: CustomStringConvertible, CustomDebugStringConvertible {
    // Guards against a secret key reaching a log line via string interpolation.
    public var description: String { "PrivateKey(<redacted>)" }
    public var debugDescription: String { description }
}

/// Verifies a BIP-340 signature. Free function because verification needs no secret.
public func verifySignature(_ signature: Data, message: Data, publicKey: PublicKey) -> Bool {
    guard signature.count == 64, message.count == 32 else { return false }
    guard let parsed = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: signature) else {
        return false
    }
    let xonly = P256K.Schnorr.XonlyKey(dataRepresentation: publicKey.data)
    var bytes = Array(message)
    return xonly.isValid(parsed, for: &bytes)
}

public enum CryptoError: Error, Equatable {
    case invalidKeyLength(Int)
    case invalidMessageLength(Int)
    case randomnessUnavailable
}
