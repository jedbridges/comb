import Foundation
import Testing
@testable import CombCore

@Suite("Blossom authorization")
struct BlossomAuthTests {
    @Test("an upload header carries the tags Buzz signs")
    func uploadHeaderTags() async throws {
        let signer = InMemorySigner(try PrivateKey())
        let hash = String(repeating: "a", count: 64)

        let header = try await Blossom.uploadHeader(
            sha256: hash,
            mimeType: "image/png",
            server: URL(string: "https://designers.communities.buzz.xyz")!,
            signer: signer
        )

        let event = try #require(decode(header))
        #expect(event.kind == .blossomAuth)
        #expect(event.content == "Upload file")
        #expect(event.firstValue(for: "t") == "upload")
        #expect(event.firstValue(for: "x") == hash)
        #expect(event.firstValue(for: "server") == "designers.communities.buzz.xyz")
        #expect(event.isValid)
    }

    @Test("a get header is scoped to the server, with no hash")
    func getHeaderTags() async throws {
        let signer = InMemorySigner(try PrivateKey())
        let header = try await Blossom.getHeader(
            server: URL(string: "https://relay.example")!,
            signer: signer
        )

        let event = try #require(decode(header))
        #expect(event.content == "Get media")
        #expect(event.firstValue(for: "t") == "get")
        #expect(event.firstValue(for: "x") == nil)
        #expect(event.firstValue(for: "server") == "relay.example")
    }

    @Test("video uploads get a longer authorization window")
    func videoExpiry() async throws {
        // A 600 second window expires mid-transfer on a large video, and the
        // upload then fails at the very end, having spent the whole transfer.
        let signer = InMemorySigner(try PrivateKey())
        let server = URL(string: "https://relay.example")!
        let now = Date().timeIntervalSince1970

        let image = try #require(decode(try await Blossom.uploadHeader(
            sha256: "x", mimeType: "image/png", server: server, signer: signer
        )))
        let video = try #require(decode(try await Blossom.uploadHeader(
            sha256: "x", mimeType: "video/mp4", server: server, signer: signer
        )))

        let imageExpiry = Double(try #require(image.firstValue(for: "expiration")))!
        let videoExpiry = Double(try #require(video.firstValue(for: "expiration")))!
        #expect(imageExpiry - now <= 601)
        #expect(videoExpiry - now > 3000)
    }

    @Test("the header is base64url without padding")
    func headerEncoding() async throws {
        // BUD-01 requires base64url; a header encoded the NIP-98 way with
        // standard base64 is rejected by the relay.
        let signer = InMemorySigner(try PrivateKey())
        let header = try await Blossom.getHeader(
            server: URL(string: "https://relay.example")!,
            signer: signer
        )
        let encoded = String(header.dropFirst("Nostr ".count))

        #expect(header.hasPrefix("Nostr "))
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
    }

    @Test("a non-default port stays in the server tag")
    func serverTagKeepsPort() {
        #expect(Blossom.serverTag(URL(string: "http://localhost:8080")!) == "localhost:8080")
        #expect(Blossom.serverTag(URL(string: "https://relay.example")!) == "relay.example")
    }

    /// Pulls the event back out of an `Authorization` value.
    private func decode(_ header: String) -> NostrEvent? {
        var encoded = String(header.dropFirst("Nostr ".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }

        return Data(base64Encoded: encoded)
            .flatMap { try? JSONDecoder().decode(NostrEvent.self, from: $0) }
    }
}

@Suite("NIP-92 imeta")
struct IMetaTests {
    @Test("round trips a descriptor through a tag")
    func roundTrip() {
        let descriptor = Blossom.Descriptor(
            url: "https://relay.example/media/abc.png",
            sha256: String(repeating: "b", count: 64),
            size: 4096,
            mimeType: "image/png",
            dim: "1280x720"
        )

        let attachments = Blossom.attachments(in: [Blossom.imetaTag(for: descriptor)])
        let attachment = try! #require(attachments.first)

        #expect(attachment.url == descriptor.url)
        #expect(attachment.sha256 == descriptor.sha256)
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.size == 4096)
        #expect(attachment.width == 1280)
        #expect(attachment.height == 720)
    }

    @Test("skips an entry missing url, type, or hash")
    func skipsIncomplete() {
        // The hash is the cache key, so an attachment without one has nowhere
        // to live and must not render half-formed.
        let tags = [
            ["imeta", "url https://relay.example/a.png", "m image/png"],
            ["imeta", "m image/png", "x abc"],
            ["imeta", "url https://relay.example/b.png", "m image/png", "x def"],
        ]
        let attachments = Blossom.attachments(in: tags)
        #expect(attachments.map(\.sha256) == ["def"])
    }

    @Test("reads values containing spaces")
    func valuesWithSpaces() {
        // Entries split on the FIRST space only; a blurhash or URL with a space
        // must survive intact.
        let tags = [[
            "imeta",
            "url https://relay.example/a.png",
            "m image/png",
            "x abc",
            "blurhash L6Pj0^ jE.Aet",
        ]]
        let attachment = try! #require(Blossom.attachments(in: tags).first)
        #expect(attachment.blurhash == "L6Pj0^ jE.Aet")
    }

    @Test("ignores tags that are not imeta")
    func ignoresOtherTags() {
        let tags = [["h", "room-1"], ["e", "abc", "", "reply"], ["p", "someone"]]
        #expect(Blossom.attachments(in: tags).isEmpty)
    }

    @Test("a hostile aspect ratio is treated as unknown")
    func hostileAspectRatio() {
        // `dim` arrives in a tag anyone can write. Trusting 100000x1 would
        // reserve a layout thousands of points wide before a byte loads.
        let wide = Blossom.Attachment(
            url: "u", mimeType: "image/png", sha256: "a", width: 100_000, height: 1
        )
        let tall = Blossom.Attachment(
            url: "u", mimeType: "image/png", sha256: "b", width: 1, height: 100_000
        )
        let sane = Blossom.Attachment(
            url: "u", mimeType: "image/png", sha256: "c", width: 1280, height: 720
        )
        #expect(wide.aspectRatio == nil)
        #expect(tall.aspectRatio == nil)
        #expect(sane.aspectRatio != nil)
    }

    @Test("malformed dimensions do not sink the attachment")
    func badDimensions() {
        let tags = [[
            "imeta", "url https://relay.example/a.png", "m image/png", "x abc", "dim wide",
        ]]
        let attachment = try! #require(Blossom.attachments(in: tags).first)
        #expect(attachment.width == nil)
        #expect(attachment.aspectRatio == nil)
    }

    @Test("a video attachment is recognised as one")
    func videoFlag() {
        let tags = [["imeta", "url https://relay.example/a.mp4", "m video/mp4", "x abc"]]
        let attachment = try! #require(Blossom.attachments(in: tags).first)
        #expect(attachment.isVideo)
    }

    @Test("the body keeps a plain markdown link as a fallback")
    func markdownFallback() {
        // A client that reads no imeta tags still shows something usable rather
        // than a message that appears empty.
        let image = Blossom.Descriptor(
            url: "https://relay.example/a.png", sha256: "x", size: 1, mimeType: "image/png"
        )
        let video = Blossom.Descriptor(
            url: "https://relay.example/a.mp4", sha256: "y", size: 1, mimeType: "video/mp4"
        )
        #expect(Blossom.markdown(for: image) == "\n![image](https://relay.example/a.png)")
        #expect(Blossom.markdown(for: video) == "\n![video](https://relay.example/a.mp4)")
    }
}
