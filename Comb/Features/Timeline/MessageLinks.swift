import CombStore
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
        _ rawContent: String,
        mentionNames: [String] = []
    ) -> AttributedString {
        // `[label](url)` collapses to the label first, so everything below
        // works on the text a reader actually sees. Doing it here rather than
        // in `display` keeps the URLs, which a plain String cannot carry.
        let (content, inlineLinks) = MessageText.expandingInlineLinks(rawContent)

        var attributed = linkified(content)

        for link in inlineLinks {
            guard let swiftRange = Range(link.range, in: content),
                  let range = Range(swiftRange, in: attributed)
            else { continue }
            attributed[range].link = link.url
            attributed[range].underlineStyle = .single
        }

        // Ranges are found in the plain String and then mapped across, rather
        // than walking AttributedString slices. Slice-walking looked fine and
        // was not: it searched a re-sliced view each pass, which made loop
        // termination depend on index arithmetic across two index spaces and
        // could leave the timeline rendering nothing at all.
        //
        // Longest first, so "@Greg Christian" is not half-matched by a member
        // called "Greg", and already-claimed ranges are skipped so the shorter
        // name cannot then overwrite part of the longer one.
        var claimed: [Range<String.Index>] = []

        for name in mentionNames.sorted(by: { $0.count > $1.count }) {
            guard !name.isEmpty else { continue }
            let needle = "@" + name

            var searchStart = content.startIndex
            while searchStart < content.endIndex,
                  let found = content.range(
                      of: needle,
                      options: .caseInsensitive,
                      range: searchStart..<content.endIndex
                  ) {
                // Always advance past the match, so this terminates whatever
                // the haystack contains.
                searchStart = found.upperBound

                guard !claimed.contains(where: { $0.overlaps(found) }) else { continue }
                guard let range = Range(found, in: attributed) else { continue }

                // A mention inside a URL is part of the URL.
                if attributed[range].link == nil {
                    attributed[range].foregroundColor = Palette.chartreuse
                    attributed[range].font = Typography.bodyEmphasis
                    claimed.append(found)
                }
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
