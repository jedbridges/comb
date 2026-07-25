import Foundation

/// Builds the kind 0 document a profile edit should publish.
///
/// Kind 0 is replaceable: the relay keeps the newest one per pubkey and throws
/// the previous away whole. There is no merge, no patch, and no partial
/// update. So a client that publishes only the field it changed deletes every
/// field it did not, and the person finds out when their avatar disappears.
///
/// Comb did exactly that. Renaming yourself in Settings published `name` and
/// `display_name` alone, which silently destroyed the picture, the bio, the
/// NIP-05 handle, and the Lightning address of anyone who used it.
///
/// This lives here rather than in the session so it can be tested without a
/// relay, which is the only reason the bug was ever provable.
public enum ProfileDocument {
    /// A rename that keeps everything else the account already had.
    ///
    /// Only the fields Comb models are carried: it parses a profile into typed
    /// properties, so a key written by some other client is not round-tripped
    /// and will still be lost. Preserving the five that are modelled is the
    /// difference between losing an avatar on every rename and losing nothing
    /// anyone can see. Empty values are dropped rather than published as empty
    /// strings, which some clients render as a present-but-blank field.
    public static func rename(
        to displayName: String,
        preserving existing: ProfileSummary?
    ) -> [String: String] {
        // Both spellings, because clients disagree about which one they read.
        var document = ["name": displayName, "display_name": displayName]
        guard let existing else { return document }

        let carried = [
            "picture": existing.picture,
            "about": existing.about,
            "nip05": existing.nip05,
            "lud16": existing.lightningAddress,
        ]
        for (key, value) in carried {
            guard let value, !value.isEmpty else { continue }
            document[key] = value
        }
        return document
    }
}
