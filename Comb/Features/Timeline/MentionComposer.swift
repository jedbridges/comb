import CombCore
import CombStore
import SwiftUI

/// Resolving `@names` while typing, and back again when sending.
///
/// Names are not identities: two people can be called Mat, and a display
/// name can change after the message is sent. So the text keeps the name a
/// reader recognises, while the `p` tag carries the pubkey that makes
/// notification possible. That is the same split Buzz uses.
@MainActor
@Observable
final class MentionComposer {
    /// Who is available to mention, newest-talking first, from the channel
    /// roster already in the store.
    private(set) var candidates: [ProfileSummary] = []
    /// Currently offered for the token under the cursor.
    private(set) var suggestions: [ProfileSummary] = []

    private let store: EventStore
    private let channelID: String

    init(store: EventStore, channelID: String) {
        self.store = store
        self.channelID = channelID
    }

    func loadCandidates() {
        candidates = (try? store.members(of: channelID)) ?? []
    }

    /// Offers matches for a trailing `@token`, and nothing otherwise.
    ///
    /// Only the token being typed at the end of the draft counts: scanning
    /// the whole draft would re-open suggestions for a mention completed
    /// three words ago.
    func update(for draft: String) {
        guard let token = Self.trailingMentionToken(in: draft) else {
            suggestions = []
            return
        }

        let needle = token.dropFirst()   // past the "@"
        suggestions = candidates
            .filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) }
            .prefix(4)
            .map { $0 }
    }

    /// Replaces the trailing token with the chosen name, ready to keep typing.
    func complete(_ draft: String, with profile: ProfileSummary) -> String {
        guard let token = Self.trailingMentionToken(in: draft) else { return draft }
        return String(draft.dropLast(token.count)) + "@\(profile.name) "
    }

    /// The pubkeys to tag, resolved by matching `@name` runs in the final
    /// text against the roster.
    ///
    /// Longest names first so "@Greg Christian" is not consumed by a member
    /// called "Greg". Unmatched `@words` are left as plain text rather than
    /// guessed at: tagging the wrong person is worse than tagging nobody.
    func mentionedPubkeys(in text: String) -> [String] {
        candidates
            .sorted { $0.name.count > $1.name.count }
            .filter { text.localizedCaseInsensitiveContains("@\($0.name)") }
            .map(\.pubkey)
    }

    /// The `@token` being typed at the very end of the draft, if any.
    static func trailingMentionToken(in draft: String) -> String? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }

        // Must start a word: an email address is not a mention.
        if atIndex > draft.startIndex {
            let before = draft[draft.index(before: atIndex)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }

        let token = draft[atIndex...]
        // A newline ends a mention; a single space does not, so full names
        // with spaces can still be completed.
        guard !token.contains(where: \.isNewline) else { return nil }
        // Two or more spaces means the author moved on.
        guard token.split(separator: " ", omittingEmptySubsequences: false).count <= 2 else {
            return nil
        }
        return String(token)
    }
}

/// The suggestion strip above the compose bar.
struct MentionSuggestions: View {
    let suggestions: [ProfileSummary]
    let onPick: (ProfileSummary) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.xs) {
                ForEach(suggestions) { profile in
                    Button {
                        onPick(profile)
                    } label: {
                        HStack(spacing: Space.xxs) {
                            AvatarView(name: profile.name, picture: profile.picture)
                                .scaleEffect(0.7)
                                .frame(width: Sizing.avatar * 0.7, height: Sizing.avatar * 0.7)
                            Text(profile.name)
                                .font(Typography.label)
                                .foregroundStyle(Palette.text)
                                .lineLimit(1)
                        }
                        .padding(.trailing, Space.xs)
                        .frame(minHeight: Sizing.hitTarget)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Space.sm)
        }
        .scrollIndicators(.hidden)
        .frame(height: Sizing.hitTarget)
        .transition(.opacity)
    }
}
