import Foundation
import P256K

/// NIP-98 HTTP authentication.
///
/// Buzz's HTTP surface (invite claiming, media upload, the `/query` bridge)
/// authenticates with a signed kind 27235 event carried in an `Authorization`
/// header rather than with the relay's WebSocket NIP-42 flow.
///
/// The tag set and header encoding here match Buzz's own client
/// (`mobile/lib/shared/relay/relay_session.dart`, `buildNip98AuthHeader`):
/// `u`, `method`, `payload`, and `nonce`, base64 of the compact event JSON
/// behind a `Nostr ` scheme. The `payload` tag is always present, including for
/// bodyless requests, where it is the hash of zero bytes.
public enum NIP98 {
    /// Builds the value for an `Authorization` header.
    public static func authorizationHeader(
        url: URL,
        method: String,
        body: Data = Data(),
        signer: some EventSigner
    ) async throws -> String {
        let event = try await authorizationEvent(
            url: url,
            method: method,
            body: body,
            signer: signer
        )
        let json = try JSONEncoder().encode(event)
        return "Nostr " + json.base64EncodedString()
    }

    /// The signed kind 27235 event behind the header.
    ///
    /// Exposed separately so tests can inspect the tags without decoding base64.
    public static func authorizationEvent(
        url: URL,
        method: String,
        body: Data = Data(),
        signer: some EventSigner
    ) async throws -> NostrEvent {
        let payloadHash = Data(SHA256.hash(data: body)).hex

        return try await signer.sign(
            kind: .httpAuth,
            content: "",
            tags: [
                ["u", url.absoluteString],
                ["method", method.uppercased()],
                ["payload", payloadHash],
                // A fresh nonce per request, so two identical requests never
                // produce the same event id and cannot be replayed as one.
                ["nonce", UUID().uuidString],
            ]
        )
    }

    /// Validates a received header, for tests and for diagnostics.
    ///
    /// Servers apply their own clock skew allowance; the default here matches the
    /// 60 second window NIP-98 recommends.
    public static func validate(
        header: String,
        url: URL,
        method: String,
        body: Data = Data(),
        now: Date = Date(),
        tolerance: TimeInterval = 60
    ) -> Bool {
        guard header.hasPrefix("Nostr ") else { return false }
        let encoded = String(header.dropFirst("Nostr ".count))
        guard let json = Data(base64Encoded: encoded),
              let event = try? JSONDecoder().decode(NostrEvent.self, from: json),
              event.kind == .httpAuth,
              event.isValid
        else { return false }

        guard event.firstValue(for: "u") == url.absoluteString,
              event.firstValue(for: "method")?.uppercased() == method.uppercased(),
              event.firstValue(for: "payload") == Data(SHA256.hash(data: body)).hex
        else { return false }

        return abs(event.date.timeIntervalSince(now)) <= tolerance
    }
}
