import Foundation

/// Turns a direct message channel into something a person can recognise.
///
/// Buzz names DM channels on the server with a placeholder (`dm`,
/// `Direct Message`, or `Group DM (3)`) and expects every client to relabel
/// them from the roster. Without this a DM shows up in the channel list as a
/// row literally called "dm", which is how Comb rendered them before.
///
/// The rule is deliberately the same as the official client's, so the two apps
/// name the same conversation the same way.
public enum DirectMessageName {
    /// How many participants are named before the rest become a count.
    ///
    /// Two, not three. This label has to survive a channel-list row that also
    /// carries a glyph and a date, and an inline navigation title flanked by a
    /// back button. Three full names truncate mid-word and take the tail with
    /// them, which loses the only token saying the conversation is a group.
    static let previewLimit = 2

    /// Whether a name carries no information and should be replaced.
    ///
    /// An operator who renamed a DM to something real keeps that name: only the
    /// known placeholders are treated as replaceable.
    public static func isPlaceholder(_ name: String?) -> Bool {
        let normalized = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty
            || normalized == "dm"
            || normalized == "direct message"
            || normalized == "direct messages" {
            return true
        }
        return normalized.wholeMatch(of: /group dm\s*(\(\d+\))?/) != nil
    }

    /// What a direct message is called before anyone in it is known.
    ///
    /// Group metadata and the member roster are separate events, so there is a
    /// real window on a cold launch where the channel exists and its people do
    /// not. The relay's own name for it in that window is "dm", which is the
    /// string this whole type exists to stop showing.
    public static let unknownParticipants = "Direct message"

    /// The people in the conversation, as a label.
    ///
    /// The viewer is dropped: a DM titled with your own name among the others
    /// reads as a list of strangers plus you, which is not how anyone thinks
    /// about a conversation they are in.
    ///
    /// The overflow reads "Alice & 3 others" rather than "Alice, +3 more".
    /// A `+N` chip is a web token-list idiom, and appending it to a
    /// comma-separated list ends the sentence on something that is not a name,
    /// which parses badly both on screen and read aloud.
    public static func label(participants: [String]) -> String? {
        guard !participants.isEmpty else { return nil }

        let visible = Array(participants.prefix(previewLimit))
        let hidden = participants.count - visible.count
        guard hidden > 0 else { return visible.formattedAsNames() }

        // Commas for the named people and a single ampersand before the tail:
        // "Alice, Bob & 3 others". Running the names through the ampersand
        // form as well would give "Alice & Bob & 3 others", which reads as
        // three items joined by the wrong conjunction twice.
        let others = hidden == 1 ? "1 other" : "\(hidden) others"
        return "\(visible.joined(separator: ", ")) & \(others)"
    }

    /// The name to show, given what the relay called it and who is in it.
    ///
    /// A placeholder is never passed through. If the roster has not arrived,
    /// or the only member is the viewer, the answer is a generic phrase in the
    /// app's own voice rather than the relay's "dm" or "Group DM (3)". Both
    /// retitle themselves once the members land, but only one of them looks
    /// like a mistake in the meantime.
    public static func resolve(
        name: String?,
        isDirectMessage: Bool,
        participants: [String],
        fallback: String
    ) -> String {
        guard isDirectMessage, isPlaceholder(name) else {
            return name.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        return label(participants: participants) ?? unknownParticipants
    }
}

private extension [String] {
    /// "Alice", "Alice & Bob". An ampersand for a pair, because two names
    /// joined by a comma read as a truncated list rather than a complete one.
    func formattedAsNames() -> String {
        guard count > 1, let last else { return joined(separator: ", ") }
        return dropLast().joined(separator: ", ") + " & " + last
    }
}
