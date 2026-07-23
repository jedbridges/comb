import CombCore
import CombNet
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

    init(session: CommunitySession) {
        self.session = session
        self.directory = URL.cachesDirectory.appending(path: "Media", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The image for an attachment, from memory, then disk, then the relay.
    func image(for attachment: Blossom.Attachment) async throws -> UIImage {
        let key = attachment.sha256 as NSString
        if let cached = memory.object(forKey: key) { return cached }

        let data = try await data(for: attachment)
        guard let image = UIImage(data: data) else {
            throw BlossomClient.Failure.malformedResponse
        }

        memory.setObject(image, forKey: key, cost: data.count)
        return image
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
                        .strokeBorder(Palette.border.opacity(0.6), lineWidth: 0.5)
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
