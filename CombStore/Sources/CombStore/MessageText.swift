import Foundation

/// Turning a stored message body into the text a person should see.
public enum MessageText {
    /// The full path from stored body to displayable text.
    ///
    /// Call this rather than the individual steps: every surface that shows a
    /// message body should be doing the same work, and a caller that reaches
    /// for one step and forgets the other is how a channel preview and its
    /// timeline end up disagreeing about what a message says.
    public static func display(_ content: String) -> String {
        let linked = expandingInlineLinks(unwrappingAutolinks(withoutMediaMarkdown(content))).text
        return extractingInlineStyles(linked).text
    }

    /// A `[label](url)` in a message body, once the markup is gone.
    public struct InlineLink: Sendable, Equatable {
        /// Where the label ended up in the rewritten text.
        public let range: NSRange
        public let url: URL

        public init(range: NSRange, url: URL) {
            self.range = range
            self.url = url
        }
    }

    /// Rewrites `[label](url)` to just `label`, and reports where each label
    /// landed so a renderer can make it tappable.
    ///
    /// Buzz's composer writes these when someone pastes a link over selected
    /// text, and its own client renders them, so in Comb they arrived as raw
    /// brackets and parentheses with a URL repeated twice.
    ///
    /// Showing the label and attaching the URL, rather than picking one, is
    /// the only choice that loses nothing: dropping the URL leaves an
    /// often-truncated label that goes nowhere, and dropping the label shows a
    /// wall of URL the author had already chosen to hide.
    ///
    /// Callers that only need text take `.text` and ignore the rest, which is
    /// what `display` does for channel previews and search results.
    public static func expandingInlineLinks(
        _ content: String
    ) -> (text: String, links: [InlineLink]) {
        guard content.contains("](") else { return (content, []) }

        let source = content as NSString
        let matches = inlineLink.matches(
            in: content,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return (content, []) }

        var output = ""
        var links: [InlineLink] = []
        var cursor = 0

        for match in matches {
            let target = source.substring(with: match.range(at: 2))
            guard let url = URL(string: target),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http"
            else {
                // Left exactly as written. The cursor does not advance, so the
                // untouched markup is carried over by the next append.
                continue
            }

            output += source.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            let label = source.substring(with: match.range(at: 1))
            let start = (output as NSString).length
            output += label
            links.append(
                InlineLink(
                    range: NSRange(location: start, length: (label as NSString).length),
                    url: url
                )
            )
            cursor = match.range.location + match.range.length
        }

        output += source.substring(from: cursor)
        return (output, links)
    }

    /// The label is capped and may not span lines: an unbounded one would let
    /// a single message hide an arbitrary destination behind arbitrary text,
    /// which is the shape of every link-spoofing trick there is. A short label
    /// on one line is a link; a paragraph is something else.
    private static let inlineLink = try! NSRegularExpression(
        pattern: #"\[([^\]\n]{1,120})\]\((https?://[^)\s]+)\)"#
    )

    /// An emphasis run in a message body, once its markers are gone.
    public struct InlineStyle: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case bold, italic, strikethrough, code
        }

        /// Where the styled text ended up in the rewritten text.
        public let range: NSRange
        public let kind: Kind
    }

    /// Rewrites `**bold**`, `*italic*`, `~~strike~~` and `` `code` `` to their
    /// contents, and reports where each run landed so a renderer can style it.
    ///
    /// Buzz composes in a rich editor and serializes to Markdown before
    /// signing, so its formatting arrives here as literal asterisks. Rendering
    /// them is what makes a Buzz message read the way its author wrote it.
    ///
    /// Only these four inline runs are honoured, and each maps to a fixed text
    /// attribute. Nothing here lets a message choose a size, a colour, or a
    /// block layout, which is the line between reading someone's emphasis and
    /// handing a stranger control of the timeline's appearance.
    ///
    /// The third return value is the marker ranges that were removed, which a
    /// caller needs to shift any ranges it computed before this ran.
    public static func extractingInlineStyles(
        _ content: String
    ) -> (text: String, styles: [InlineStyle], deletions: [NSRange]) {
        guard content.rangeOfCharacter(from: markerCharacters) != nil else {
            return (content, [], [])
        }

        let source = content as NSString
        let matches = inlineStyle.matches(
            in: content,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return (content, [], []) }

        var output = ""
        var styles: [InlineStyle] = []
        var deletions: [NSRange] = []
        var cursor = 0

        for match in matches {
            guard let (kind, inner) = style(of: match) else { continue }

            output += source.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            let start = (output as NSString).length
            output += source.substring(with: inner)
            styles.append(
                InlineStyle(
                    range: NSRange(location: start, length: inner.length),
                    kind: kind
                )
            )

            let openLength = inner.location - match.range.location
            deletions.append(NSRange(location: match.range.location, length: openLength))
            let innerEnd = inner.location + inner.length
            let matchEnd = match.range.location + match.range.length
            deletions.append(NSRange(location: innerEnd, length: matchEnd - innerEnd))

            cursor = matchEnd
        }

        output += source.substring(from: cursor)
        return (output, styles, deletions)
    }

    /// Shifts a range computed before `extractingInlineStyles` ran onto the
    /// text it produced. Nil when the markers swallowed the range entirely.
    public static func remap(_ range: NSRange, removing deletions: [NSRange]) -> NSRange? {
        var location = range.location
        var length = range.length

        for deletion in deletions {
            let deletionEnd = deletion.location + deletion.length
            if deletionEnd <= range.location {
                location -= deletion.length
            } else if deletion.location < range.location + range.length {
                length -= deletion.length
            }
        }

        guard length > 0, location >= 0 else { return nil }
        return NSRange(location: location, length: length)
    }

    /// Which alternative of `inlineStyle` fired, and the text it wrapped.
    private static func style(
        of match: NSTextCheckingResult
    ) -> (InlineStyle.Kind, NSRange)? {
        // Positional, matching the capture groups in `inlineStyle` in order.
        let kinds: [InlineStyle.Kind] = [.code, .bold, .strikethrough, .italic, .italic]

        for (index, kind) in kinds.enumerated() {
            let range = match.range(at: index + 1)
            if range.location != NSNotFound { return (kind, range) }
        }
        return nil
    }

    /// Ordered by precedence, because the alternation is tried left to right at
    /// each position: code first so its contents are never re-read as markup,
    /// then the two-character markers before the one-character ones, or `**a**`
    /// would match as an italic wrapping `*a*`.
    ///
    /// Every run is bounded and may not span lines. Emphasis also follows
    /// CommonMark's flanking rule, so the marker must hug its text: `2 * 3 * 4`
    /// is arithmetic, not an italic `3`. Underscore additionally may not sit
    /// inside a word, or `some_var_name` loses its middle to emphasis, which in
    /// a room full of code is the common case rather than the edge one.
    ///
    /// Backticks are exempt from both, matching CommonMark: a code span is
    /// delimited by the backticks alone and its contents are literal.
    private static let inlineStyle = try! NSRegularExpression(
        pattern: #"""
        `([^`\n]+)`\#
        |\*\*(\S(?:[^*\n]*\S)?)\*\*\#
        |~~(\S(?:[^~\n]*\S)?)~~\#
        |\*(\S(?:[^*\n]*\S)?)\*\#
        |(?<!\w)_(\S(?:[^_\n]*\S)?)_(?!\w)
        """#
    )

    private static let markerCharacters = CharacterSet(charactersIn: "*~`_")

    /// Removes the angle brackets from a Markdown autolink, `<https://…>`.
    ///
    /// Buzz's composer writes them, and they are markup, not punctuation the
    /// author typed: a Markdown renderer shows the URL without them. Comb
    /// renders only the inline runs in `extractingInlineStyles` and no block
    /// markup at all, so an autolink has no renderer of its own here and would
    /// otherwise arrive wearing brackets.
    ///
    /// Narrow on purpose. Only `<` immediately followed by an http(s) URL and
    /// closed by `>` with no whitespace between is touched, so `a < b` and a
    /// stray `<3` are left exactly as written.
    public static func unwrappingAutolinks(_ content: String) -> String {
        guard content.contains("<") else { return content }

        return autolink.stringByReplacingMatches(
            in: content,
            range: NSRange(content.startIndex..., in: content),
            withTemplate: "$1"
        )
    }

    private static let autolink = try! NSRegularExpression(
        pattern: #"<(https?://[^>\s]+)>"#
    )

    /// Removes the machine-written media markdown Buzz appends to a message.
    ///
    /// Buzz puts `![image](url)` in the body as well as an `imeta` tag, so a
    /// client that reads no tags still shows a link. Comb reads the tags and
    /// renders the picture, so the markdown is pure noise here: left in, a
    /// shared screenshot arrives as sixty characters of relay URL.
    ///
    /// Only the exact `image` and `video` labels are matched, because those are
    /// the two Buzz generates. Someone's hand-written `![diagram](...)` is
    /// their own text and is left alone.
    public static func withoutMediaMarkdown(_ content: String) -> String {
        guard content.contains("![") else { return content }

        let stripped = mediaMarkdown.stringByReplacingMatches(
            in: content,
            range: NSRange(content.startIndex..., in: content),
            withTemplate: ""
        )
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)

        // A message that was nothing but its attachment leaves an empty body,
        // which is correct: the picture is the message.
        return trimmed
    }

    private static let mediaMarkdown = try! NSRegularExpression(
        pattern: #"!\[(?:image|video)\]\([^)\s]*\)"#
    )
}
