import Foundation

/// Turning a stored message body into the text a person should see.
public enum MessageText {
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
