import CryptoKit
import Foundation
import P256K

/// Device pairing: moving an identity from a desktop client to this phone
/// without either device ever displaying a key.
///
/// The handshake is ECDH plus HKDF-SHA256, with a six-digit short authentication
/// string the two humans compare out of band. That comparison is the whole
/// security argument: ECDH alone would be perfectly happy to agree a key with a
/// machine in the middle, and the SAS is what makes such an attacker visible.
///
/// Every derivation here must match Buzz's own client byte for byte
/// (`mobile/lib/features/pairing/pairing_crypto.dart`), or the two ends compute
/// different session ids and never find each other.
public enum Pairing {
    /// The payload behind a `nostrpair://` QR code.
    public struct Invitation: Equatable, Sendable {
        /// The offering device's identity, x-only.
        public let sourcePubkey: PublicKey
        /// 32 bytes of shared randomness from the QR code, which is what binds
        /// this exchange to the code that was actually scanned.
        public let sessionSecret: Data
        /// Where to meet. Buzz uses a dedicated ephemeral pairing relay.
        public let relays: [URL]
        public let version: Int
    }

    /// The verification numbers, and the material that binds the transcript.
    public struct ShortAuthentication: Equatable, Sendable {
        /// Six digits, zero-padded, for a human to read aloud.
        public let code: String
        /// The full derived block, which the transcript hash commits to.
        public let input: Data
    }

    public static let uriScheme = "nostrpair://"
    /// Guards against a QR code carrying an unbounded payload.
    static let maximumURILength = 2048

    // MARK: - QR payload

    /// Parses `nostrpair://<pubkey>?secret=…&relay=…&v=1`.
    ///
    /// Validation is deliberately strict. This input arrives from a camera
    /// pointed at an arbitrary screen, so anything malformed is rejected rather
    /// than interpreted generously.
    public static func parse(_ uri: String) throws -> Invitation {
        guard uri.count <= maximumURILength else { throw PairingError.uriTooLong }
        guard uri.hasPrefix(uriScheme) else { throw PairingError.notAPairingURI }

        let rest = String(uri.dropFirst(uriScheme.count))
        guard let separator = rest.firstIndex(of: "?") else {
            throw PairingError.missingQuery
        }

        let pubkeyHex = String(rest[rest.startIndex..<separator])
        guard pubkeyHex.count == 64, isLowercaseHex(pubkeyHex),
              let sourcePubkey = PublicKey(hex: pubkeyHex)
        else { throw PairingError.invalidPubkey }

        var secretHex: String?
        var relays: [URL] = []
        var version = 1

        for pair in rest[rest.index(after: separator)...].split(separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[pair.startIndex..<equals])
            let value = String(pair[pair.index(after: equals)...])

            switch key {
            case "secret":
                secretHex = value
            case "relay":
                guard let decoded = value.removingPercentEncoding,
                      let url = URL(string: decoded),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "wss" || scheme == "ws"
                else { throw PairingError.invalidRelay(value) }
                relays.append(url)
            case "v":
                guard let parsed = Int(value) else { throw PairingError.unsupportedVersion(0) }
                version = parsed
            default:
                continue
            }
        }

        guard version == 1 else { throw PairingError.unsupportedVersion(version) }

        guard let secretHex, secretHex.count == 64, isLowercaseHex(secretHex),
              let sessionSecret = Data(hex: secretHex)
        else { throw PairingError.invalidSessionSecret }

        // An all-zero secret would mean the offering device generated no
        // randomness at all, which makes the session id and SAS predictable.
        guard sessionSecret.contains(where: { $0 != 0 }) else {
            throw PairingError.invalidSessionSecret
        }

        guard !relays.isEmpty else { throw PairingError.noRelays }

        return Invitation(
            sourcePubkey: sourcePubkey,
            sessionSecret: sessionSecret,
            relays: relays,
            version: version
        )
    }

    // MARK: - Key agreement

    /// The ECDH shared secret: the raw x-coordinate of the shared point.
    ///
    /// Unhashed on purpose. The usual secp256k1 ECDH hashes the point with
    /// SHA-256, but this protocol feeds the bare coordinate into HKDF, so the
    /// default would silently produce a different secret than the other device.
    ///
    /// The peer's key is x-only, so it is lifted assuming even Y, matching the
    /// BIP-340 convention both ends use.
    public static func sharedSecret(
        privateKey: PrivateKey,
        peer: PublicKey
    ) throws -> Data {
        var compressed = Data([0x02])
        compressed.append(peer.data)

        guard let peerKey = try? P256K.KeyAgreement.PublicKey(
            dataRepresentation: compressed,
            format: .compressed
        ) else { throw PairingError.invalidPeerKey }

        let key = try P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey.data)
        let shared = key.sharedSecretFromKeyAgreement(with: peerKey, format: .compressed)

        // The compressed form is a parity prefix followed by X; the protocol
        // wants only X.
        let bytes = shared.withUnsafeBytes { Data($0) }
        guard bytes.count == 33 else { throw PairingError.invalidPeerKey }
        return bytes.dropFirst()
    }

    // MARK: - Derivations

    /// The session identifier both devices subscribe to.
    ///
    /// Derived from the QR secret alone, so the two ends can find each other
    /// before they have agreed on anything.
    public static func sessionID(sessionSecret: Data) -> Data {
        HKDF256.derive(
            ikm: sessionSecret,
            salt: Data(),
            info: "nostr-pair-session-id",
            length: 32
        )
    }

    /// The six digits the two humans compare.
    ///
    /// Salted with the QR secret so a machine in the middle, which never saw the
    /// code, cannot produce matching digits.
    public static func shortAuthentication(
        sharedSecret: Data,
        sessionSecret: Data
    ) -> ShortAuthentication {
        let input = HKDF256.derive(
            ikm: sharedSecret,
            salt: sessionSecret,
            info: "nostr-pair-sas-v1",
            length: 32
        )

        let bytes = [UInt8](input)
        let value =
            UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        let code = String(format: "%06u", value % 1_000_000)

        return ShortAuthentication(code: code, input: input)
    }

    /// A hash committing to every parameter of the session.
    ///
    /// Checked before any payload is accepted. The SAS proves the humans agree;
    /// this proves both devices agree on the same session id, the same two
    /// identities, and the same SAS material, so an attacker cannot swap one of
    /// them after the digits have been read aloud.
    public static func transcriptHash(
        sessionID: Data,
        sourcePubkey: PublicKey,
        targetPubkey: PublicKey,
        sasInput: Data,
        sessionSecret: Data
    ) -> Data {
        var transcript = Data(capacity: 128)
        transcript.append(sessionID)
        transcript.append(sourcePubkey.data)
        transcript.append(targetPubkey.data)
        transcript.append(sasInput)

        return HKDF256.derive(
            ikm: transcript,
            salt: sessionSecret,
            info: "nostr-pair-transcript-v1",
            length: 32
        )
    }

    // MARK: - Helpers

    /// Compares two values without leaking where they first differ.
    ///
    /// A byte-by-byte early exit on a transcript hash would let an attacker
    /// recover it one byte at a time by timing repeated attempts.
    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    private static func isLowercaseHex(_ string: String) -> Bool {
        string.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}

/// HKDF-SHA256 (RFC 5869).
///
/// An empty salt is equivalent to 32 zero bytes here, because HMAC pads any key
/// shorter than its block size with zeros. Buzz's client passes 32 explicit
/// zeros; both produce the same PRK.
enum HKDF256 {
    static func derive(ikm: Data, salt: Data, info: String, length: Int) -> Data {
        // Fully qualified: P256K vendors its own Crypto module, and leaving
        // these bare makes SHA256 ambiguous between the two.
        let prk = CryptoKit.HKDF<CryptoKit.SHA256>.extract(
            inputKeyMaterial: CryptoKit.SymmetricKey(data: ikm),
            salt: salt
        )
        let okm = CryptoKit.HKDF<CryptoKit.SHA256>.expand(
            pseudoRandomKey: prk,
            info: Data(info.utf8),
            outputByteCount: length
        )
        return okm.withUnsafeBytes { Data($0) }
    }
}

public enum PairingError: Error, Equatable {
    case uriTooLong
    case notAPairingURI
    case missingQuery
    case invalidPubkey
    case invalidSessionSecret
    case invalidRelay(String)
    case noRelays
    case unsupportedVersion(Int)
    case invalidPeerKey
    /// The transcript did not match, meaning the two devices disagree about the
    /// session. Treated as an attack, not as a retryable error.
    case transcriptMismatch
}
