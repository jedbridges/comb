import Foundation

/// Makes URLs in a message tappable, and nothing else.
///
/// Deliberately not a markdown renderer: message content is written by
/// strangers, and interpreting arbitrary markup from them is a styling
/// injection surface. Links are detected by `NSDataDetector`, the same
/// machinery Mail and Messages use, and only http(s) destinations get the
/// attribute; anything else stays inert text.
enum MessageLinks {
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    static func attributed(_ content: String) -> AttributedString {
        var attributed = AttributedString(content)
        guard let detector else { return attributed }

        let matches = detector.matches(
            in: content,
            range: NSRange(content.startIndex..., in: content)
        )

        for match in matches {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let swiftRange = Range(match.range, in: content),
                  let range = Range(swiftRange, in: attributed)
            else { continue }

            attributed[range].link = url
            // Underlined as well as tinted: colour alone is invisible to
            // colour-blind readers, and the tint may sit close to body text.
            attributed[range].underlineStyle = .single
        }

        return attributed
    }
}
