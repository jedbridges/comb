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
    public func data(
        for attachment: Blossom.Attachment,
        signer: some EventSigner
    ) async throws -> Data {
        guard let url = URL(string: attachment.url),
              let origin = Self.httpOrigin(of: url)
        else { throw Failure.badRelayURL }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "GET"
        request.setValue(
            try await Blossom.getHeader(server: origin, signer: signer),
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await session.data(for: request)
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
