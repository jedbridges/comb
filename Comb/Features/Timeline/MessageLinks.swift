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

    /// Links, plus `@name` runs highlighted for the given roster.
    ///
    /// Names come from the roster rather than a regex over `@\w+`: only a
    /// real member's name should light up, or every email address and price
    /// tag becomes a false mention.
    static func attributed(
        _ content: String,
        mentionNames: [String] = []
    ) -> AttributedString {
        var attributed = linkified(content)

        // Longest first: "@Greg Christian" must not be half-matched by a
        // member called "Greg".
        for name in mentionNames.sorted(by: { $0.count > $1.count }) {
            let needle = "@\(name)"
            var searchRange = attributed.startIndex..<attributed.endIndex
            while let found = attributed[searchRange].range(
                of: needle, options: .caseInsensitive
            ) {
                // Skip anything already carrying a link: a mention inside a
                // URL is part of the URL.
                if attributed[found].link == nil {
                    attributed[found].foregroundColor = Palette.chartreuse
                    attributed[found].font = Typography.bodyEmphasis
                }
                guard found.upperBound < attributed.endIndex else { break }
                searchRange = found.upperBound..<attributed.endIndex
            }
        }
        return attributed
    }

    /// Links only. Separate from the mention-aware entry point rather than an
    /// overload with a default argument: two same-named functions where one
    /// defaults its extra parameter is a resolution puzzle at every call site.
    static func linkified(_ content: String) -> AttributedString {
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
