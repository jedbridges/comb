import Foundation

/// Lowercase hex encoding, the only form Nostr uses on the wire.
///
/// NIP-01 requires event ids and pubkeys to be lowercase hex. Uppercase input
/// is accepted when decoding (some relays and QR payloads are sloppy) but never
/// produced when encoding.
public enum Hex {
    public static func encode(_ bytes: some Sequence<UInt8>) -> String {
        var out = ""
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return out
    }

    public static func decode(_ string: String) -> Data? {
        let chars = Array(string.utf8)
        guard chars.count % 2 == 0 else { return nil }

        var out = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else {
                return nil
            }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private static let hexDigits = Array("0123456789abcdef")

    private static func nibble(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x30...0x39: ascii - 0x30          // 0-9
        case 0x61...0x66: ascii - 0x61 + 10     // a-f
        case 0x41...0x46: ascii - 0x41 + 10     // A-F
        default: nil
        }
    }
}

public extension Data {
    var hex: String { Hex.encode(self) }

    init?(hex: String) {
        guard let data = Hex.decode(hex) else { return nil }
        self = data
    }
}
