import Foundation

/// The payload a Buzz relay tucks into an OK message when it answers a command.
///
/// NIP-01 says the fourth element of an OK is a human-readable reason, and for
/// an ordinary publish it is. Buzz's command kinds reuse it as a return
/// channel: the relay does the work, then answers `response:{"channel_id":…}`.
/// That id is the only way a client learns what was created on its behalf, and
/// there is nowhere else to look for it.
///
/// A Buzz extension, so it is read defensively. Anything unrecognised is
/// nothing rather than an error: a relay that does not do this answers with the
/// plain reason string every other relay does, and that is not a failure.
public enum CommandResponse {
    private static let prefix = "response:"

    /// The channel a `buzzOpenDirectMessage` created, if the relay named one.
    public static func channelID(in okMessage: String) -> String? {
        guard let payload = json(in: okMessage) else { return nil }
        guard let id = payload["channel_id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// The JSON object after the `response:` marker.
    ///
    /// Scanned for rather than required at the start: the marker is a
    /// convention rather than a spec, and a relay that prefixes it with
    /// anything else is still telling the truth about what it made.
    static func json(in okMessage: String) -> [String: Any]? {
        guard let markerRange = okMessage.range(of: prefix) else { return nil }
        let body = okMessage[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
