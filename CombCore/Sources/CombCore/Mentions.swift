import Foundation

/// Mention semantics, matching Buzz's client-side resolver
/// (`desktop/src/features/messages/lib/threading.ts`,
/// `normalizeMentionPubkeys`).
///
/// A mention is text (`@Name`) plus a `p` tag naming the pubkey; the tag is
/// what makes notification delivery possible, the text is what people read.
public enum Mentions {
    /// The relay's cap on `p` tags per message. Matched client-side so an
    /// over-tagged message is trimmed before it is signed rather than
    /// rejected after.
    public static let maxPerMessage = 50

    /// Lowercases, deduplicates, and drops the sender, in first-seen order.
    ///
    /// The same normalization the relay applies authoritatively; doing it
    /// here keeps optimistic sends byte-identical to what the relay would
    /// have kept.
    public static func normalize(_ pubkeys: [String], sender: String) -> [String] {
        let senderLowered = sender.lowercased()
        var seen: Set<String> = [senderLowered]
        var result: [String] = []

        for pubkey in pubkeys {
            let lowered = pubkey.lowercased()
            guard !seen.contains(lowered) else { continue }
            seen.insert(lowered)
            result.append(lowered)
            if result.count == maxPerMessage { break }
        }
        return result
    }
}
