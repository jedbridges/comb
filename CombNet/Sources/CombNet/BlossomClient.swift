import CombCore
import CryptoKit
import Foundation

/// Uploads and downloads media on a Buzz relay's Blossom store.
///
/// Both directions are authorized: uploads with a `t=upload` event bound to the
/// content hash, downloads with a `t=get` event. That download requirement is
/// what rules out `AsyncImage` for relay-hosted media and is why the app has an
/// image loader of its own.
public struct BlossomClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public enum Failure: Error, Equatable {
        /// The relay does not accept this kind of file. Checked locally, before
        /// anything is sent.
        case unsupportedType(String)
        /// Larger than the relay's ceiling for its type.
        case tooLarge(bytes: Int, limit: Int)
        /// The relay refused the upload or the fetch.
        case rejected(status: Int)
        /// The relay's own URL could not be turned into an HTTP origin.
        case badRelayURL
        /// The blob is on a host that is not this community's, or is not on
        /// TLS. Nothing was signed and nothing was requested.
        case foreignHost
        case malformedResponse
        /// The bytes that came back are not the bytes that were asked for.
        case hashMismatch
    }

    // MARK: - Upload

    /// Uploads a blob and returns what the relay says about it.
    ///
    /// Tries BUD-02 `/upload` first and falls back to the legacy
    /// `/media/upload` only on 404 or 405, which is how Buzz's own client
    /// distinguishes "this relay is older" from "this upload failed". Any other
    /// status is a real failure and is not retried against a second endpoint,
    /// because sending a rejected file somewhere else does not make it welcome.
    public func upload(
        _ data: Data,
        mimeType: String,
        to relayURL: URL,
        signer: some EventSigner
    ) async throws -> Blossom.Descriptor {
        guard Blossom.allowedMIMETypes.contains(mimeType) else {
            throw Failure.unsupportedType(mimeType)
        }

        let limit = mimeType.hasPrefix("video/")
            ? Blossom.maxVideoBytes
            : Blossom.maxImageBytes
        guard data.count <= limit else {
            throw Failure.tooLarge(bytes: data.count, limit: limit)
        }

        guard let origin = Self.httpOrigin(of: relayURL) else { throw Failure.badRelayURL }
        // The same rule the download path applies. An upload's authorization is
        // signed with the account key too, and an invite link may name a `ws://`
        // host, so without this a hostile invite produced a community whose
        // uploads shipped that signature in clear while its downloads were
        // refused. One asymmetry is one too many.
        guard origin.scheme == "https" || Self.isLoopback(origin) else {
            throw Failure.foreignHost
        }
        let hash = Data(SHA256.hash(data: data)).hex

        do {
            return try await put(
                data,
                hash: hash,
                mimeType: mimeType,
                to: origin.appending(path: "upload"),
                origin: origin,
                signer: signer
            )
        } catch Failure.rejected(let status) where status == 404 || status == 405 {
            return try await put(
                data,
                hash: hash,
                mimeType: mimeType,
                to: origin.appending(path: "media/upload"),
                origin: origin,
                signer: signer
            )
        }
    }

    private func put(
        _ data: Data,
        hash: String,
        mimeType: String,
        to url: URL,
        origin: URL,
        signer: some EventSigner
    ) async throws -> Blossom.Descriptor {
        let authorization = try await Blossom.uploadHeader(
            sha256: hash,
            mimeType: mimeType,
            server: origin,
            signer: signer
        )

        // Generous, and longer for video: an upload killed at 90% wastes the
        // whole transfer and the user's patience with it.
        let timeout: TimeInterval = mimeType.hasPrefix("video/") ? 600 : 120
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "PUT"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(hash, forHTTPHeaderField: "X-SHA-256")

        let (body, response) = try await session.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode)
        }
        guard let descriptor = try? JSONDecoder().decode(Blossom.Descriptor.self, from: body)
        else { throw Failure.malformedResponse }

        return descriptor
    }

    // MARK: - Download

    /// Fetches a blob, verifying it is the one that was asked for.
    ///
    /// The hash check is the point of a content-addressed store: without it a
    /// relay could serve any bytes it liked under someone else's attachment.
    ///
    /// `servedBy` is required rather than inferred, and that is the whole point.
    /// An attachment's URL comes from an `imeta` tag written by whoever sent the
    /// message, so it names a host of their choosing. This function signs a
    /// Blossom authorization with the reader's own key and puts it in a header,
    /// so fetching an attacker-named host handed a stranger the reader's IP
    /// address together with a signature proving their pubkey: a way to tie a
    /// Nostr identity to a network address for every member of a channel who
    /// scrolled past one message.
    ///
    /// Taking the expected host as a parameter is what stops that being a thing
    /// a caller can forget. There was a correct host check in the app, on the
    /// avatar path, and the attachment path simply never got one.
    public func data(
        for attachment: Blossom.Attachment,
        servedBy host: URL,
        signer: some EventSigner
    ) async throws -> Data {
        guard let url = URL(string: attachment.url),
              let origin = Self.httpOrigin(of: url)
        else { throw Failure.badRelayURL }

        // Nothing is signed, and no request is made, until the host matches.
        guard Self.isSameHost(url, as: host) else { throw Failure.foreignHost }
        // And only over TLS. `httpOrigin` accepts `http` so a local development
        // relay works, which would otherwise put the URL and the signed header
        // on the wire in clear.
        guard origin.scheme == "https" || Self.isLoopback(origin) else {
            throw Failure.foreignHost
        }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "GET"
        request.setValue(
            try await Blossom.getHeader(server: origin, signer: signer),
            forHTTPHeaderField: "Authorization"
        )

        // Pinning the first request's host is not enough on its own. URLSession
        // follows redirects and carries a manually-set Authorization header
        // across them, so a hostile relay, or an honest one with an open
        // redirect, could bounce the signed event anywhere. The header stays
        // replayable for its ten minute lifetime, so this is worth stopping
        // rather than tolerating.
        let redirects = SameHostRedirectGuard(expected: host)
        let (data, response) = try await session.data(for: request, delegate: redirects)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(status: http.statusCode)
        }
        guard Data(SHA256.hash(data: data)).hex == attachment.sha256 else {
            throw Failure.hashMismatch
        }

        return data
    }

    // MARK: - URLs

    /// Whether a blob URL belongs to the community being asked to serve it.
    /// Compared case-insensitively on host and port, because a relay on a
    /// non-default port is a different origin from the same name on 443.
    static func isSameHost(_ url: URL, as community: URL) -> Bool {
        guard let left = url.host?.lowercased(),
              let right = community.host?.lowercased(),
              left == right
        else { return false }
        return effectivePort(of: url) == effectivePort(of: community)
    }

    /// A local relay, where plain HTTP is the only option and the traffic never
    /// leaves the machine.
    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func effectivePort(of url: URL) -> Int {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https", "wss": return 443
        case "http", "ws": return 80
        default: return -1
        }
    }

    /// The HTTP origin matching a relay's websocket URL: `wss` becomes `https`,
    /// and `ws` becomes `http` so local development still works.
    static func httpOrigin(of url: URL) -> URL? {
        var components = URLComponents()
        switch url.scheme?.lowercased() {
        case "wss", "https": components.scheme = "https"
        case "ws", "http": components.scheme = "http"
        default: return nil
        }
        guard let host = url.host, !host.isEmpty else { return nil }
        components.host = host
        components.port = url.port
        return components.url
    }
}

/// Refuses a redirect that leaves the host the request was pinned to.
///
/// URLSession keeps a manually-set `Authorization` header across a cross-host
/// redirect, so without this the host check on the original URL could be undone
/// by the response to it.
private final class SameHostRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let expected: URL

    init(expected: URL) { self.expected = expected }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, BlossomClient.isSameHost(url, as: expected) else {
            // Nil cancels the redirect and hands the 3xx back, which fails the
            // status check. Stripping the header and following would still tell
            // the new host that this reader is here, for nothing.
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
