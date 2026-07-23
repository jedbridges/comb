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
        expandingInlineLinks(unwrappingAutolinks(withoutMediaMarkdown(content))).text
    }

    /// A `[label](url)` in a message body, once the markup is gone.
    public struct InlineLink: Sendable, Equatable {
        /// Where the label ended up in the rewritten text.
        public let range: NSRange
        public let url: URL
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

    /// Removes the angle brackets from a Markdown autolink, `<https://…>`.
    ///
    /// Buzz's composer writes them, and they are markup, not punctuation the
    /// author typed: a Markdown renderer shows the URL without them. Comb is
    /// deliberately not a Markdown renderer (interpreting arbitrary markup
    /// from strangers is a styling injection surface), but it still has to
    /// avoid displaying the one piece of syntax its own sister client emits,
    /// or every shared link arrives wearing brackets.
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
