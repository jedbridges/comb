import CombCore
import CombNet
import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// Fetches and caches relay-hosted media.
///
/// This exists because Buzz media cannot be loaded by `AsyncImage`: every blob
/// is behind a signed Blossom `t=get` header, so the bytes have to be fetched
/// by something holding the account key.
///
/// Two caches, for two different reasons. Memory keeps scrolling smooth; disk
/// keeps a reopened channel from refetching everything, and makes already-seen
/// images work offline, which is the same promise the message history makes.
actor MediaLoader {
    private let session: CommunitySession
    private let client = BlossomClient()

    /// In-flight fetches, keyed by hash, so ten rows showing the same image
    /// cause one download rather than ten.
    private var inFlight: [String: Task<Data, Error>] = [:]

    /// Decoded images, bounded by cost so a channel full of photographs cannot
    /// grow without limit.
    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private let directory: URL

    /// The disk cache's ceiling. Trimmed lazily on first use per session, so
    /// a channel full of photographs cannot grow the cache without bound.
    private static let maxDiskBytes: Int64 = 256 * 1024 * 1024

    init(session: CommunitySession) {
        self.session = session
        self.directory = URL.cachesDirectory.appending(path: "Media", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Task { await trimDiskCache() }
    }

    /// Evicts oldest-accessed files until the cache fits under the ceiling.
    ///
    /// Access order rather than write order: the image someone opens daily
    /// should outlive fifty scrolled past once. The OS may also purge Caches
    /// entirely under pressure, which is fine; everything here is refetchable.
    private func trimDiskCache() {
        let keys: [URLResourceKey] = [.contentAccessDateKey, .totalFileAllocatedSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }

        var entries: [(url: URL, accessed: Date, size: Int64)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (
                url,
                values.contentAccessDate ?? .distantPast,
                Int64(values.totalFileAllocatedSize ?? 0)
            )
        }

        var total = entries.reduce(0) { $0 + $1.size }
        guard total > Self.maxDiskBytes else { return }

        entries.sort { $0.accessed < $1.accessed }
        for entry in entries where total > Self.maxDiskBytes {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// The image behind a profile picture URL.
    ///
    /// `AsyncImage` cannot do this job. An avatar set from inside Buzz lives on
    /// the community's own Blossom server, which is membership-gated: an
    /// unauthenticated GET returns 401, so the picture silently never appears
    /// and the initial stands in forever. Those blobs need the same signed
    /// `t=get` header a message attachment uses.
    ///
    /// An avatar hosted anywhere else is an ordinary public image and is
    /// fetched plainly. That split is deliberate rather than incidental:
    /// signing a Blossom header for a third-party host would hand a stranger
    /// an authorization signed with this account's key.
    func avatar(at url: URL) async throws -> UIImage {
        let key = Self.avatarKey(for: url)
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let data: Data
        if url.scheme?.lowercased() == "data" {
            // Some clients inline the whole picture in the kind 0 rather than
            // uploading it. Nothing to fetch, and nothing to cache on disk.
            data = try Self.decodeDataURI(url)
        } else if let attachment = blossomAttachment(for: url) {
            data = try await self.data(for: attachment)
        } else {
            data = try await publicData(at: url, key: key)
        }

        // 256px covers the largest avatar the app draws on a 3x display. The
        // attachment path decodes at 2048 because those are looked at; nobody
        // pinch-zooms a 36pt circle.
        guard let image = Self.decodeDownsampled(data, maxPixel: 256) else {
            throw BlossomClient.Failure.malformedResponse
        }
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        memory.setObject(image, forKey: key as NSString, cost: max(cost, data.count))
        return image
    }

    /// Recognises a picture URL as a blob on this community's own Blossom
    /// server, which is the only case where signing is both required and safe.
    ///
    /// The filename is the blob's sha256 by BUD-01, so the hash the client
    /// verifies the bytes against comes from the URL itself.
    private func blossomAttachment(for url: URL) -> Blossom.Attachment? {
        guard url.host?.lowercased() == session.relayURL.host?.lowercased() else { return nil }

        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.count == 64,
              stem.allSatisfy({ $0.isHexDigit })
        else { return nil }

        return Blossom.Attachment(
            url: url.absoluteString,
            mimeType: "application/octet-stream",
            sha256: stem.lowercased()
        )
    }

    /// A public avatar, disk-cached like everything else so a member list does
    /// not refetch thirty faces every time it opens.
    private func publicData(at url: URL, key: String) async throws -> Data {
        let file = directory.appending(path: key)
        if let onDisk = try? Data(contentsOf: file) { return onDisk }

        if let existing = inFlight[key] { return try await existing.value }

        let task = Task<Data, Error> {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw BlossomClient.Failure.malformedResponse
            }
            // A profile can name any URL it likes, so the size ceiling is not
            // optional: without it one hostile kind 0 costs whatever the host
            // decides to send.
            guard data.count <= Self.maxAvatarBytes else {
                throw BlossomClient.Failure.malformedResponse
            }
            return data
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let data = try await task.value
        try? data.write(to: file, options: .atomic)
        return data
    }

    /// The bytes of a `data:` URI, base64 only.
    ///
    /// Same ceiling as a fetched avatar, applied to the encoded form so a
    /// hostile kind 0 cannot make this allocate before the limit is checked.
    private static func decodeDataURI(_ url: URL) throws -> Data {
        let text = url.absoluteString
        guard text.count <= maxAvatarBytes,
              let comma = text.firstIndex(of: ","),
              text[text.startIndex..<comma].lowercased().hasSuffix(";base64"),
              let data = Data(
                  base64Encoded: String(text[text.index(after: comma)...]),
                  options: .ignoreUnknownCharacters
              )
        else { throw BlossomClient.Failure.malformedResponse }
        return data
    }

    private static let maxAvatarBytes = 8 * 1024 * 1024

    /// A filename-safe cache key. Blossom blobs are already keyed by their own
    /// hash; everything else is keyed by a hash of the URL so two hosts cannot
    /// collide and no path separator ends up in a filename.
    private static func avatarKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "avatar-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The image for an attachment, from memory, then disk, then the relay.
    func image(for attachment: Blossom.Attachment) async throws -> UIImage {
        let key = attachment.sha256 as NSString
        if let cached = memory.object(forKey: key) { return cached }

        let data = try await data(for: attachment)
        guard let image = Self.decodeDownsampled(data) else {
            throw BlossomClient.Failure.malformedResponse
        }

        // Cost is the decoded bitmap, not the file: a 1.5 MB JPEG decodes to
        // ~25 MB of pixels, and costing by file size let the "64 MB" cache
        // quietly hold half a gigabyte of bitmaps.
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        memory.setObject(image, forKey: key, cost: max(cost, data.count))
        return image
    }

    /// Decodes at most 2048px on the long edge, straight from ImageIO.
    ///
    /// `UIImage(data:)` decodes the full bitmap: a 12-megapixel photograph
    /// becomes ~48 MB of memory to fill a 260pt slot. Thumbnailing at decode
    /// time caps the cost per image regardless of what arrives, and 2048px
    /// still over-fills the full-screen viewer on a 3x display.
    private static func decodeDownsampled(_ data: Data, maxPixel: Int = 2048) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Applies EXIF orientation while decoding, so the bitmap is
            // upright and no transform survives into rendering.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as [CFString: Any] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func data(for attachment: Blossom.Attachment) async throws -> Data {
        let file = directory.appending(path: attachment.sha256)
        if let onDisk = try? Data(contentsOf: file) { return onDisk }

        if let existing = inFlight[attachment.sha256] {
            return try await existing.value
        }

        let task = Task<Data, Error> {
            try await session.mediaData(for: attachment)
        }
        inFlight[attachment.sha256] = task
        defer { inFlight[attachment.sha256] = nil }

        let data = try await task.value
        // Written only after the client has verified the hash, so the cache can
        // never be poisoned with bytes that were not what was asked for.
        try? data.write(to: file, options: .atomic)
        return data
    }
}

extension EnvironmentValues {
    /// The community's media loader, for views too far from the session to be
    /// handed one.
    ///
    /// `AvatarView` is drawn in the timeline, the member list, the reactors
    /// sheet, a profile, and a channel row. Threading a loader through every
    /// one of those call sites to make a face appear would be five signature
    /// changes for one feature, so it arrives by environment instead.
    @Entry var mediaLoader: MediaLoader?
}

/// One attachment in the timeline.
///
/// Space is reserved from the reported dimensions before anything loads, so
/// images do not shove the conversation around as they arrive.
struct AttachmentView: View {
    let attachment: Blossom.Attachment
    let loader: MediaLoader

    @State private var image: UIImage?
    @State private var failed = false
    @State private var isPresented = false

    /// Wide enough to be worth looking at, short enough that one image cannot
    /// take the whole screen and push the conversation out of view.
    private static let maxHeight: CGFloat = 260

    var body: some View {
        Group {
            if attachment.isVideo {
                unsupportedVideo
            } else if let image {
                loaded(image)
            } else if failed {
                unavailable
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: attachment.sha256) { await load() }
        .sheet(isPresented: $isPresented) {
            if let image { ImageDetailView(image: image) }
        }
    }

    private func load() async {
        guard image == nil, !attachment.isVideo else { return }
        do {
            image = try await loader.image(for: attachment)
            failed = false
        } catch {
            failed = true
        }
    }

    private func loaded(_ image: UIImage) -> some View {
        Button { isPresented = true } label: {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: Self.maxHeight)
                .clipShape(.rect(cornerRadius: Radii.bubble))
                .overlay(
                    RoundedRectangle(cornerRadius: Radii.bubble)
                        .strokeBorder(Palette.border.opacity(0.6), lineWidth: Stroke.fine)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Image")
        .accessibilityHint("Opens the image full screen")
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Radii.bubble)
            .fill(Palette.surface.opacity(0.4))
            .frame(width: placeholderSize.width, height: placeholderSize.height)
            .overlay(ProgressView().controlSize(.small))
            .accessibilityLabel("Image loading")
    }

    private var unavailable: some View {
        Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
            .font(Typography.caption)
            .foregroundStyle(Palette.subtext)
            .padding(.vertical, Space.xs)
    }

    /// Comb does not play video yet. Saying so is better than a broken frame or
    /// a tap that does nothing.
    private var unsupportedVideo: some View {
        Label("Video, not playable in Comb yet", systemImage: "film")
            .font(Typography.caption)
            .foregroundStyle(Palette.subtext)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .background(Palette.surface.opacity(0.4), in: .rect(cornerRadius: Radii.bubble))
    }

    /// The reported aspect ratio, scaled to fit the cap. Falls back to a modest
    /// rectangle when the relay reported no dimensions.
    private var placeholderSize: CGSize {
        guard let ratio = attachment.aspectRatio else {
            return CGSize(width: 200, height: 140)
        }
        let height = min(Self.maxHeight, 200 / ratio)
        return CGSize(width: height * ratio, height: height)
    }
}

/// An image on its own, zoomable, dismissed by a tap.
private struct ImageDetailView: View {
    let image: UIImage

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    ShareLink(item: Image(uiImage: image), preview: .init("Image", image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
