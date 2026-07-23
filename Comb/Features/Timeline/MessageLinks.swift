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

        shortenBareLinks(in: &attributed)
        return attributed
    }

    /// How many characters of a bare URL survive.
    ///
    /// Sized from the narrowest layout the app has to work in, not the
    /// widest. A message body on a 375pt device sits in roughly 315pt once the
    /// avatar and padding are taken out, and 16pt body text averages a shade
    /// under 9pt per character on the dense mixed-case runs URLs are made of,
    /// so a line holds about 35. One and a half lines is therefore about 52,
    /// and 49 keeps a comfortable margin on the tightest case while still
    /// filling well over a line on a Pro Max.
    private static let linkHead = 40
    private static let linkTail = 8
    private static var maxLinkCharacters: Int { linkHead + linkTail + 1 }

    /// Elides the middle of any link whose visible text is just its URL.
    ///
    /// A signed invite token is 300 characters of base64 and rendered in full
    /// it buried the sentence around it under eight lines of noise. The middle
    /// goes rather than the tail, because the host is the part a reader needs
    /// to decide whether to tap and the tail is what distinguishes two links
    /// to the same host.
    ///
    /// Only bare URLs are touched. An inline link's label is what the author
    /// chose to write, and shortening someone's prose is not this function's
    /// business.
    private static func shortenBareLinks(in attributed: inout AttributedString) {
        // Reversed, so replacing one run cannot invalidate the ranges of the
        // runs still to be visited.
        for run in Array(attributed.runs).reversed() {
            guard let url = run.link else { continue }
            let text = String(attributed[run.range].characters)
            guard text == url.absoluteString, text.count > maxLinkCharacters else { continue }

            var replacement = AttributedString(
                "\(text.prefix(linkHead))…\(text.suffix(linkTail))"
            )
            // The whole run's attributes carry over, so the shortened text is
            // still tinted, still underlined, and still opens the full URL.
            replacement.setAttributes(run.attributes)
            attributed.replaceSubrange(run.range, with: replacement)
        }
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
