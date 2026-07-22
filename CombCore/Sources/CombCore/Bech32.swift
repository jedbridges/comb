import Foundation

/// Bech32 (BIP-173) as used by NIP-19 for `npub`, `nsec`, and `note` identifiers.
///
/// NIP-19 uses the original bech32 checksum constant, not bech32m. The richer
/// TLV forms (`nprofile`, `nevent`, `naddr`) are deliberately not implemented
/// here yet; Comb only needs the bare 32-byte forms for identity, and adding TLV
/// without a use case invites untested code paths.
public enum Bech32 {
    public enum Error: Swift.Error, Equatable {
        case mixedCase
        case missingSeparator
        case invalidCharacter
        case invalidChecksum
        case tooShort
        case unexpectedPrefix(found: String, expected: String)
        case invalidPayloadLength(Int)
    }

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let checksumLength = 6

    // MARK: - Generic encode / decode

    public static func encode(prefix: String, data: Data) -> String {
        let words = convertBits(Array(data), from: 8, to: 5, pad: true) ?? []
        let checksum = createChecksum(prefix: prefix, words: words)
        let payload = (words + checksum).map { charset[Int($0)] }
        return prefix + "1" + String(payload)
    }

    public static func decode(_ string: String) throws -> (prefix: String, data: Data) {
        let lower = string.lowercased()
        let upper = string.uppercased()
        guard string == lower || string == upper else { throw Error.mixedCase }

        guard let separator = lower.lastIndex(of: "1") else { throw Error.missingSeparator }

        let prefix = String(lower[lower.startIndex..<separator])
        let dataPart = lower[lower.index(after: separator)...]
        guard prefix.count >= 1, dataPart.count >= checksumLength else { throw Error.tooShort }

        var words: [UInt8] = []
        words.reserveCapacity(dataPart.count)
        for character in dataPart {
            guard let index = charset.firstIndex(of: character) else { throw Error.invalidCharacter }
            words.append(UInt8(index))
        }

        guard verifyChecksum(prefix: prefix, words: words) else { throw Error.invalidChecksum }

        let payloadWords = Array(words.dropLast(checksumLength))
        guard let bytes = convertBits(payloadWords, from: 5, to: 8, pad: false) else {
            throw Error.invalidChecksum
        }
        return (prefix, Data(bytes))
    }

    // MARK: - NIP-19 convenience

    /// Decodes a bech32 string, asserting both the prefix and a 32-byte payload.
    public static func decode32(_ string: String, expecting prefix: String) throws -> Data {
        let (found, data) = try decode(string)
        guard found == prefix else { throw Error.unexpectedPrefix(found: found, expected: prefix) }
        guard data.count == 32 else { throw Error.invalidPayloadLength(data.count) }
        return data
    }

    // MARK: - Checksum

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generator: [UInt32] = [0x3B6A_57B2, 0x2650_8E6D, 0x1EA1_19FA, 0x3D42_33DD, 0x2A14_62B3]
        var checksum: UInt32 = 1
        for value in values {
            let top = checksum >> 25
            checksum = (checksum & 0x1FF_FFFF) << 5 ^ UInt32(value)
            for bit in 0..<5 where (top >> UInt32(bit)) & 1 == 1 {
                checksum ^= generator[bit]
            }
        }
        return checksum
    }

    private static func expand(prefix: String) -> [UInt8] {
        let bytes = Array(prefix.utf8)
        return bytes.map { $0 >> 5 } + [0] + bytes.map { $0 & 0x1F }
    }

    private static func createChecksum(prefix: String, words: [UInt8]) -> [UInt8] {
        let values = expand(prefix: prefix) + words + [0, 0, 0, 0, 0, 0]
        let mod = polymod(values) ^ 1
        return (0..<6).map { UInt8((mod >> (5 * (5 - UInt32($0)))) & 0x1F) }
    }

    private static func verifyChecksum(prefix: String, words: [UInt8]) -> Bool {
        polymod(expand(prefix: prefix) + words) == 1
    }

    // MARK: - Bit packing

    /// Regroups a byte stream between bit widths, as bech32 requires for its
    /// 5-bit alphabet. Returns nil when the input has invalid padding.
    private static func convertBits(
        _ input: [UInt8],
        from: UInt32,
        to: UInt32,
        pad: Bool
    ) -> [UInt8]? {
        var accumulator: UInt32 = 0
        var bits: UInt32 = 0
        var out: [UInt8] = []
        let maxValue: UInt32 = (1 << to) - 1

        for value in input {
            accumulator = (accumulator << from) | UInt32(value)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((accumulator >> bits) & maxValue))
            }
        }

        if pad {
            if bits > 0 {
                out.append(UInt8((accumulator << (to - bits)) & maxValue))
            }
        } else if bits >= from || (accumulator << (to - bits)) & maxValue != 0 {
            return nil
        }

        return out
    }
}
