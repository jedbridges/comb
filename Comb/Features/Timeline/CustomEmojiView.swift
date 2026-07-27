import CombCore
import CombStore
import SwiftUI
import UIKit

/// One NIP-30 image, at the size of the text around it.
///
/// Loaded through the community's media loader rather than `AsyncImage`, for
/// the same reason avatars are: a community's own emoji live on its
/// membership-gated Blossom server, and an unauthenticated GET there returns
/// 401. The loader knows when to sign and when not to, and reuses the cache the
/// rest of the screen is already filling.
struct CustomEmojiImage: View {
    let url: String
    /// Sized against the body text, so an emoji grows with Dynamic Type instead
    /// of shrinking into a line of large print.
    @ScaledMetric(relativeTo: .callout) private var size: CGFloat = 18

    @Environment(\.mediaLoader) private var mediaLoader
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                // Space held, nothing drawn. A placeholder glyph would be a
                // second thing to look at for an image that usually arrives in
                // a few hundred milliseconds and is already cached after that.
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.fast, value: image == nil)
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        guard let parsed = URL(string: url), let mediaLoader else { return }
        // `avatar` is the loader's small-image path: 256px, memory cached, and
        // signed only for this community's own host. An emoji wants all three.
        image = try? await mediaLoader.avatar(at: parsed)
    }
}

/// Message text with its `:shortcode:` runs drawn as images.
///
/// Built by concatenating `Text` rather than laid out as a stack, so a message
/// wraps as one paragraph. An `HStack` of runs would break the line at every
/// emoji and turn a sentence into a staircase.
///
/// Until an image has loaded the shortcode stays visible as the text somebody
/// typed, which is also what a reader sees forever if the image is unreachable.
/// That is the honest fallback: `:party:` is what the author actually wrote.
struct EmojiText: View {
    let content: String
    let entries: [CustomEmoji.Entry]
    let mentionNames: [String]
    /// Appended to the last run, so "(edited)" stays on the same line as the
    /// text it qualifies instead of starting a new one.
    var trailing: Text = Text("")

    @Environment(\.mediaLoader) private var mediaLoader
    @ScaledMetric(relativeTo: .callout) private var size: CGFloat = 18
    @State private var images: [String: UIImage] = [:]

    var body: some View {
        composed
            .font(Typography.body)
            .foregroundStyle(Palette.text)
            .lineSpacing(2)
            .textSelection(.enabled)
            .task(id: entries) { await load() }
    }

    private var composed: Text {
        // Interpolated rather than joined with `+`, which iOS 26 deprecates.
        let body = CustomEmoji.tokenize(content, with: entries)
            .reduce(Text("")) { result, token in
                switch token {
                case .text(let run):
                    let piece = Text(
                        MessageLinks.attributed(run, mentionNames: mentionNames)
                    )
                    return Text("\(result)\(piece)")
                case .emoji(let entry):
                    guard let image = images[entry.shortcode] else {
                        let literal = Text(verbatim: ":\(entry.shortcode):")
                        return Text("\(result)\(literal)")
                    }
                    let picture = Text(sized(image)).baselineOffset(-2)
                    return Text("\(result)\(picture)")
                }
            }
        return Text("\(body)\(trailing)")
    }

    /// An image interpolated into `Text` draws at its intrinsic point size, and
    /// the loader hands back 256 pixels, so a bare `Image(uiImage:)` would put
    /// a 256pt emoji in the middle of a sentence.
    ///
    /// Restated rather than redrawn: giving the same pixels a scale factor
    /// changes the point size they claim without touching the bitmap. Read at
    /// compose time so it follows Dynamic Type.
    private func sized(_ image: UIImage) -> Image {
        guard let cgImage = image.cgImage, size > 0 else { return Image(uiImage: image) }
        return Image(uiImage: UIImage(
            cgImage: cgImage,
            scale: CGFloat(cgImage.width) / size,
            orientation: image.imageOrientation
        ))
    }

    private func load() async {
        guard let mediaLoader, !entries.isEmpty else { return }

        // Sequential rather than a task group: a message carries a handful of
        // these at most, they are usually already cached, and the loader is an
        // actor, so racing them buys queueing rather than parallelism.
        // The scheme was already vetted by `CustomEmoji.entries`, which drops
        // anything that is not https or an inlined `data:` image.
        for entry in entries where images[entry.shortcode] == nil {
            guard let url = URL(string: entry.url),
                  let image = try? await mediaLoader.avatar(at: url)
            else { continue }
            images[entry.shortcode] = image
        }
    }
}
