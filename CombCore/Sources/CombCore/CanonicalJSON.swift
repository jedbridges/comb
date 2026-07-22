import Foundation

/// NIP-01 canonical serialization, used solely to compute event ids.
///
/// The id is `sha256` over the UTF-8 bytes of:
///
///     [0, <pubkey>, <created_at>, <kind>, <tags>, <content>]
///
/// with no whitespace anywhere. `JSONEncoder` cannot be used for this: it offers
/// no ordering guarantee for the array elements' nested objects, and more
/// importantly it escapes forward slashes and non-ASCII characters, which would
/// produce a different hash than every other Nostr implementation. So the string
/// is assembled by hand.
enum CanonicalJSON {
    static func serialize(
        pubkey: String,
        createdAt: Int64,
        kind: EventKind,
        tags: [[String]],
        content: String
    ) -> Data {
        var out = "[0,\""
        out += pubkey
        out += "\","
        out += String(createdAt)
        out += ","
        out += String(kind.rawValue)
        out += ","
        out += serializeTags(tags)
        out += ","
        out += quote(content)
        out += "]"
        return Data(out.utf8)
    }

    private static func serializeTags(_ tags: [[String]]) -> String {
        var out = "["
        for (tagIndex, tag) in tags.enumerated() {
            if tagIndex > 0 { out += "," }
            out += "["
            for (valueIndex, value) in tag.enumerated() {
                if valueIndex > 0 { out += "," }
                out += quote(value)
            }
            out += "]"
        }
        out += "]"
        return out
    }

    /// Escapes exactly the characters NIP-01 requires and nothing else.
    ///
    /// Non-ASCII characters are emitted literally as UTF-8. Escaping them as
    /// `\uXXXX` would still be valid JSON but would change the hash.
    private static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case let other where other.value < 0x20:
                out += String(format: "\\u%04x", other.value)
            case let other:
                out.unicodeScalars.append(other)
            }
        }
        out += "\""
        return out
    }
}
