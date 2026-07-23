import Foundation
import P256K

/// Blossom media authorization (BUD-01/BUD-02) and NIP-92 `imeta` metadata.
///
/// Buzz stores media on the relay itself and gates both upload and download
/// behind a signed kind 24242 event. That gate is the reason a plain
/// `AsyncImage` cannot render a Buzz attachment: fetching the bytes needs an
/// `Authorization` header, so the app has to load images itself.
///
/// The tag sets, content strings, expiry windows and header encoding here match
/// Buzz's own client (`crates/buzz-cli/src/client.rs`, `sign_blossom_upload`
/// and `sign_blossom_get`). Note the encoding is base64**url** without padding,
/// unlike NIP-98's standard base64: a header built the NIP-98 way is rejected.
public enum Blossom {
    /// What the relay accepts. Anything else is refused before a byte is sent,
    /// so the user hears "that kind of file is not supported" instead of an
    /// opaque server error after a long upload.
    public static let allowedMIMETypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp", "video/mp4",
    ]

    public static let maxImageBytes = 50 * 1024 * 1024
    public static let maxVideoBytes = 500 * 1024 * 1024

    /// What the relay returns after a successful upload.
    public struct Descriptor: Sendable, Equatable, Codable {
        public let url: String
        public let sha256: String
        public let size: Int64
        public let mimeType: String
        public let dim: String?
        public let blurhash: String?

        enum CodingKeys: String, CodingKey {
            case url, sha256, size, dim, blurhash
            case mimeType = "type"
        }

        public init(
            url: String,
            sha256: String,
            size: Int64,
            mimeType: String,
            dim: String? = nil,
            blurhash: String? = nil
        ) {
            self.url = url
            self.sha256 = sha256
            self.size = size
            self.mimeType = mimeType
            self.dim = dim
            self.blurhash = blurhash
        }
    }

    /// A piece of media hanging off a message, read back from its `imeta` tag.
    public struct Attachment: Sendable, Equatable, Identifiable, Hashable {
        public let url: String
        public let mimeType: String
        public let sha256: String
        public let size: Int64?
        /// Pixel dimensions when the relay reported them. Worth having: it lets
        /// the timeline reserve the right space before the bytes arrive, so
        /// images do not shove the conversation around as they load.
        public let width: Int?
        public let height: Int?
        public let blurhash: String?

        public init(
            url: String,
            mimeType: String,
            sha256: String,
            size: Int64? = nil,
            width: Int? = nil,
            height: Int? = nil,
            blurhash: String? = nil
        ) {
            self.url = url
            self.mimeType = mimeType
            self.sha256 = sha256
            self.size = size
            self.width = width
            self.height = height
            self.blurhash = blurhash
        }

        public var id: String { sha256 }
        public var isVideo: Bool { mimeType.hasPrefix("video/") }

        public var aspectRatio: Double? {
            guard let width, let height, width > 0, height > 0 else { return nil }
            // Clamped: the dimensions arrive in a tag anyone can write, and a
            // declared "100000x1" would otherwise become a reserved layout
            // thousands of points wide. Real photographs live well inside
            // 1:5 to 5:1; anything outside is treated as unknown.
            let ratio = Double(width) / Double(height)
            guard (0.2...5.0).contains(ratio) else { return nil }
            return ratio
        }
    }

    // MARK: - Authorization

    /// The `Authorization` value for uploading a blob.
    public static func uploadHeader(
        sha256: String,
        mimeType: String,
        server: URL,
        signer: some EventSigner
    ) async throws -> String {
        // Video uploads take longer than images, so their authorization has to
        // outlive the transfer or a slow connection fails at the finish line.
        let lifetime: TimeInterval = mimeType.hasPrefix("video/") ? 3600 : 600
        var tags = [
            ["t", "upload"],
            ["x", sha256],
            ["expiration", expiration(after: lifetime)],
        ]
        if let authority = serverTag(server) { tags.append(["server", authority]) }

        return try await header(
            signing: .blossomAuth,
            content: "Upload file",
            tags: tags,
            with: signer
        )
    }

    /// The `Authorization` value for fetching a blob.
    public static func getHeader(
        server: URL,
        signer: some EventSigner
    ) async throws -> String {
        var tags = [
            ["t", "get"],
            ["expiration", expiration(after: 600)],
        ]
        if let authority = serverTag(server) { tags.append(["server", authority]) }

        return try await header(
            signing: .blossomAuth,
            content: "Get media",
            tags: tags,
            with: signer
        )
    }

    private static func header(
        signing kind: EventKind,
        content: String,
        tags: [[String]],
        with signer: some EventSigner
    ) async throws -> String {
        let event = try await signer.sign(kind: kind, content: content, tags: tags)
        let json = try JSONEncoder().encode(event)
        return "Nostr " + base64URLNoPad(json)
    }

    private static func expiration(after seconds: TimeInterval) -> String {
        String(Int64(Date().addingTimeInterval(seconds).timeIntervalSince1970))
    }

    /// The `server` tag value: host, plus port when it is not the default.
    static func serverTag(_ url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }

    /// base64url without padding, per BUD-01. Standard base64 is rejected.
    static func base64URLNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - NIP-92 imeta

    /// Builds the `imeta` tag describing an uploaded blob.
    ///
    /// Entries are single strings of `key value`, which is NIP-92's shape and
    /// not the more obvious pair-per-element you might expect.
    public static func imetaTag(for descriptor: Descriptor) -> [String] {
        var tag = [
            "imeta",
            "url \(descriptor.url)",
            "m \(descriptor.mimeType)",
            "x \(descriptor.sha256)",
            "size \(descriptor.size)",
        ]
        if let dim = descriptor.dim { tag.append("dim \(dim)") }
        if let blurhash = descriptor.blurhash { tag.append("blurhash \(blurhash)") }
        return tag
    }

    /// Reads every attachment out of an event's tags.
    ///
    /// An entry missing a url, type or hash is skipped rather than rendered
    /// half-formed: the hash is what the cache keys on, so an attachment
    /// without one has nowhere to live.
    public static func attachments(in tags: [[String]]) -> [Attachment] {
        tags.compactMap { tag in
            guard tag.first == "imeta" else { return nil }

            var fields: [String: String] = [:]
            for entry in tag.dropFirst() {
                guard let separator = entry.firstIndex(of: " ") else { continue }
                let key = String(entry[entry.startIndex..<separator])
                let value = String(entry[entry.index(after: separator)...])
                // First writer wins, so a duplicated key cannot overwrite the
                // value the sender meant.
                if fields[key] == nil { fields[key] = value }
            }

            guard let url = fields["url"], let mime = fields["m"], let hash = fields["x"]
            else { return nil }

            let dimensions = fields["dim"].flatMap(parseDimensions)
            return Attachment(
                url: url,
                mimeType: mime,
                sha256: hash,
                size: fields["size"].flatMap(Int64.init),
                width: dimensions?.width,
                height: dimensions?.height,
                blurhash: fields["blurhash"]
            )
        }
    }

    /// `"1280x720"` into its parts.
    static func parseDimensions(_ value: String) -> (width: Int, height: Int)? {
        let parts = value.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              width > 0, height > 0
        else { return nil }
        return (width, height)
    }

    // MARK: - Message body

    /// The markdown Buzz appends to a message body for each attachment.
    ///
    /// Duplicated in the text as well as the `imeta` tag on purpose: a client
    /// that knows nothing about NIP-92 still shows a working link rather than a
    /// message that appears empty.
    public static func markdown(for descriptor: Descriptor) -> String {
        let label = descriptor.mimeType.hasPrefix("video/") ? "video" : "image"
        return "\n![\(label)](\(descriptor.url))"
    }
}
