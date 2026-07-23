import CombCore
import CombNet
import PhotosUI
import SwiftUI
import UIKit

/// Attachments chosen but not yet sent.
///
/// Uploading starts the moment a photo is picked rather than when Send is
/// tapped. By the time someone has typed a caption the bytes are usually
/// already on the relay, so sending feels instant instead of stalling on a
/// progress bar at the worst moment.
@MainActor
@Observable
final class AttachmentTray {
    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case uploading
            case ready(Blossom.Descriptor)
            case failed(String)

            static func == (lhs: State, rhs: State) -> Bool {
                switch (lhs, rhs) {
                case (.uploading, .uploading): true
                case (.ready(let a), .ready(let b)): a == b
                case (.failed(let a), .failed(let b)): a == b
                default: false
                }
            }
        }

        let id = UUID()
        let preview: UIImage
        var state: State

        var hasFailed: Bool {
            if case .failed = state { return true }
            return false
        }
    }

    private(set) var items: [Item] = []
    /// The most recent upload failure, for the caller to surface.
    private(set) var failure: String?

    private let session: CommunitySession

    init(session: CommunitySession) {
        self.session = session
    }

    var isEmpty: Bool { items.isEmpty }
    var isUploading: Bool { items.contains { $0.state == .uploading } }

    /// Everything that reached the relay. Items still uploading or failed are
    /// left out: send should never wait on them or silently drop the message.
    var readyDescriptors: [Blossom.Descriptor] {
        items.compactMap { item in
            if case .ready(let descriptor) = item.state { return descriptor }
            return nil
        }
    }

    func add(_ picked: [PhotosPickerItem]) async {
        for pick in picked {
            guard let data = try? await pick.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                failure = "That photo could not be read."
                continue
            }

            let item = Item(preview: image, state: .uploading)
            items.append(item)
            await upload(data, original: image, for: item.id)
        }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func clear() {
        items.removeAll()
        failure = nil
    }

    private func upload(_ data: Data, original: UIImage, for id: UUID) async {
        let (payload, mimeType) = Self.prepare(data, image: original)

        DiagnosticsBuffer.report(
            "media",
            "uploading \(payload.count) bytes as \(mimeType)"
        )

        do {
            let descriptor = try await session.upload(payload, mimeType: mimeType)
            update(id) { $0.state = .ready(descriptor) }
            DiagnosticsBuffer.report("media", "uploaded \(descriptor.sha256.prefix(12))")
        } catch {
            let message = Self.describe(error)
            update(id) { $0.state = .failed(message) }
            failure = message
            // The user-facing message is deliberately vague; the log is where
            // the actual cause has to be recoverable from.
            DiagnosticsBuffer.report("media", "upload failed: \(error)")
        }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    /// Gets the bytes into a form the relay accepts.
    ///
    /// Every image is re-encoded, never passed through, and that is a privacy
    /// decision rather than a formatting one. A photo out of the library
    /// carries EXIF, which on an iPhone routinely includes GPS coordinates, and
    /// forwarding the original would publish where the picture was taken to
    /// everyone in the channel.
    ///
    /// Buzz relays refuse metadata-bearing images outright
    /// (`crates/buzz-media/src/validation.rs` rejects JPEG APP1..APP15 and PNG
    /// `eXIf`/`tEXt`/`iCCP` chunks), so passing an original through fails the
    /// upload anyway. Redrawing satisfies both at once: the bitmap is built
    /// from pixels, so there is nothing left to leak.
    ///
    /// PNG survives as PNG. This is a client for design communities, and
    /// re-encoding a screenshot of a mockup as JPEG puts artefacts on exactly
    /// the crisp edges and small text people are sharing it to show.
    static func prepare(_ data: Data, image: UIImage) -> (Data, String) {
        let sourceType = detectMIMEType(data)
        let redrawn = redraw(image)

        if sourceType == "image/png", let png = redrawn.pngData() {
            // Sanitised even though it was just encoded: ImageIO writes an ICC
            // profile, which the relay refuses.
            return (MediaSanitizer.strippedPNG(png) ?? png, "image/png")
        }
        // 0.85 keeps a photograph honest without sending a 12-megapixel
        // original into a chat message.
        guard let jpeg = redrawn.jpegData(compressionQuality: 0.85) else {
            return (data, "image/jpeg")
        }
        return (MediaSanitizer.strippedJPEG(jpeg) ?? jpeg, "image/jpeg")
    }

    /// Redraws an image into a fresh bitmap, dropping every trace of the file
    /// it came from and normalising the orientation flag along the way.
    ///
    /// Also caps the long edge: a modern iPhone photo is far larger than a
    /// phone screen can show, and the extra pixels only cost upload time.
    static func redraw(_ image: UIImage, maxEdge: CGFloat = 2048) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1

        let target = CGSize(
            width: (size.width * scale).rounded(),
            height: (size.height * scale).rounded()
        )

        let format = UIGraphicsImageRendererFormat.default()
        // Points to pixels one to one, so the target size is the pixel size.
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// The type from the file's magic bytes, not from a filename or a
    /// system-supplied guess, because the relay sniffs the bytes too.
    static func detectMIMEType(_ data: Data) -> String? {
        let prefix = [UInt8](data.prefix(12))
        guard prefix.count >= 12 else { return nil }

        if prefix[0] == 0xFF, prefix[1] == 0xD8, prefix[2] == 0xFF { return "image/jpeg" }
        if prefix[0] == 0x89, prefix[1] == 0x50, prefix[2] == 0x4E, prefix[3] == 0x47 {
            return "image/png"
        }
        if prefix[0] == 0x47, prefix[1] == 0x49, prefix[2] == 0x46 { return "image/gif" }
        if prefix[0] == 0x52, prefix[1] == 0x49, prefix[2] == 0x46, prefix[3] == 0x46,
           prefix[8] == 0x57, prefix[9] == 0x45, prefix[10] == 0x42, prefix[11] == 0x50 {
            return "image/webp"
        }
        return nil
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case BlossomClient.Failure.tooLarge(_, let limit):
            "That file is too large. The limit is \(limit / 1024 / 1024) MB."
        case BlossomClient.Failure.unsupportedType:
            "That kind of file cannot be sent here."
        case BlossomClient.Failure.rejected(let status) where status == 401 || status == 403:
            "This community did not allow that upload."
        case BlossomClient.Failure.hashMismatch:
            "That upload arrived damaged. Try again."
        default:
            "Could not send that photo. Check the connection and try again."
        }
    }
}
