import Foundation

/// A `buzz://message` link, pointing at one message in one channel.
///
/// The format is Buzz's, byte for byte
/// (`desktop/src/features/messages/lib/messageLink.ts`), and deliberately so:
/// a link copied in Comb has to open in Buzz on someone's laptop, and a link
/// pasted from Buzz has to mean something here. Inventing a Comb-flavoured
/// scheme would give two clients in the same community two incompatible ways
/// to point at the same message.
///
///     buzz://message?channel=<uuid>&id=<eventId>[&thread=<rootId>]
enum MessageLink {
    struct Target: Equatable {
        let channelID: String
        let messageID: String
        /// The thread this message lives in, when it is a reply. Buzz emits it
        /// and does not yet consume it; carried here for the same reason, so
        /// the two clients keep producing identical strings.
        let threadRootID: String?
    }

    static func build(channelID: String, messageID: String, threadRootID: String?) -> String {
        var components = URLComponents()
        components.scheme = "buzz"
        components.host = "message"

        var items = [
            URLQueryItem(name: "channel", value: channelID),
            URLQueryItem(name: "id", value: messageID),
        ]
        // Empty is treated as absent, matching Buzz, so a caller can pass a
        // thread reference straight through without a null check.
        if let threadRootID, !threadRootID.isEmpty {
            items.append(URLQueryItem(name: "thread", value: threadRootID))
        }
        components.queryItems = items

        return components.string ?? ""
    }

    /// Reads a link back. Returns nil for anything that is not one, including
    /// the invite links that share the scheme.
    static func parse(_ text: String) -> Target? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "buzz",
              components.host?.lowercased() == "message",
              let items = components.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        guard let channel = value("channel"), let id = value("id") else { return nil }
        return Target(channelID: channel, messageID: id, threadRootID: value("thread"))
    }
}
