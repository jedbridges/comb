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
        unwrappingAutolinks(withoutMediaMarkdown(content))
    }

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
