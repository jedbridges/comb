import Foundation

/// NIP-30 custom emoji: a community's own images, addressed by shortcode.
///
/// An event carries `["emoji", "shortcode", "https://…"]` for every image it
/// uses, and writes `:shortcode:` in its content or its reaction. The tags are
/// the whole vocabulary: a shortcode with no tag on the same event resolves to
/// nothing and stays as the literal text somebody typed, which is right. There
/// is no global registry to consult and no shortcode Comb should know on its
/// own, or a community could change what another community's `:party:` looks
/// like by publishing first.
public enum CustomEmoji {
    public struct Entry: Sendable, Equatable, Hashable {
        /// Without the surrounding colons.
        public let shortcode: String
        public let url: String

        public init(shortcode: String, url: String) {
            self.shortcode = shortcode
            self.url = url
        }
    }

    /// Reads every usable emoji definition out of an event's tags.
    ///
    /// https, or an inlined `data:` image. Never http: a message can name any
    /// URL it likes, and an http emoji would be a cleartext request made on the
    /// reader's behalf for a picture the size of a word. `data:` fetches
    /// nothing, so it carries none of that risk. The same rule avatars follow,
    /// for the same reasons.
    ///
    /// A malformed or non-conforming entry is dropped, which leaves its
    /// shortcode rendering as the plain text somebody typed.
    public static func entries(in tags: [[String]]) -> [Entry] {
        var seen: Set<String> = []
        var result: [Entry] = []

        for tag in tags {
            guard tag.count >= 3, tag[0] == "emoji" else { continue }

            let shortcode = tag[1]
            guard isValidShortcode(shortcode), !seen.contains(shortcode) else { continue }

            let url = tag[2]
            guard let parsed = URL(string: url),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "https" || scheme == "data"
            else { continue }

            seen.insert(shortcode)
            result.append(Entry(shortcode: shortcode, url: url))
        }

        return result
    }

    /// NIP-30 restricts a shortcode to alphanumerics and underscore.
    ///
    /// Enforced rather than trusted, because the shortcode is what gets matched
    /// against message text: one containing a colon or a space would match
    /// across the boundaries of its own delimiters and swallow the words on
    /// either side.
    public static func isValidShortcode(_ code: String) -> Bool {
        !code.isEmpty && code.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// A run of message text: either literal characters, or an emoji to draw.
    public enum Token: Sendable, Equatable {
        case text(String)
        case emoji(Entry)
    }

    /// Splits content into text and emoji runs, resolving `:shortcode:` against
    /// the event's own definitions.
    ///
    /// An unmatched `:word:` stays text. Ordinary prose is full of colons, and
    /// a client that ate every one of them would mangle "the ratio is 3:2:1"
    /// on the strength of markup nobody wrote.
    public static func tokenize(_ content: String, with entries: [Entry]) -> [Token] {
        guard !entries.isEmpty, content.contains(":") else {
            return content.isEmpty ? [] : [.text(content)]
        }

        let byShortcode = Dictionary(
            entries.map { ($0.shortcode, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var tokens: [Token] = []
        var literal = ""
        var index = content.startIndex

        while index < content.endIndex {
            guard content[index] == ":",
                  let close = content[content.index(after: index)...].firstIndex(of: ":")
            else {
                literal.append(content[index])
                index = content.index(after: index)
                continue
            }

            let code = String(content[content.index(after: index)..<close])
            guard let entry = byShortcode[code] else {
                // Not a shortcode we know. The opening colon is literal, and
                // the scan resumes at the next character rather than after the
                // closing one, so `:a::known:` still finds `:known:`.
                literal.append(content[index])
                index = content.index(after: index)
                continue
            }

            if !literal.isEmpty {
                tokens.append(.text(literal))
                literal = ""
            }
            tokens.append(.emoji(entry))
            index = content.index(after: close)
        }

        if !literal.isEmpty { tokens.append(.text(literal)) }
        return tokens
    }
}
