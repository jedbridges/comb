import SwiftUI

/// A relay operator's policy document, rendered in the app.
///
/// In the app rather than handed to Safari on purpose. The relay will serve
/// these as web pages, and sending someone out to a browser mid-onboarding is
/// how apps get agreement without reading. It also costs the reader their place
/// in the flow, on the one screen where losing your place feels like failure.
///
/// `Text` renders inline Markdown but not block structure: headings, list
/// bullets, and paragraph breaks all collapse into one run. So blocks are split
/// here and styled per line, and only the inline syntax inside each line is
/// handed to `AttributedString`. Operator-authored text is treated as text
/// throughout, never as markup that can style the surrounding app.
struct PolicyDocumentView: View {
    let title: String
    let markdown: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.sm) {
                    ForEach(Array(Self.blocks(of: markdown).enumerated()), id: \.offset) { _, block in
                        block.view
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.md)
                .textSelection(.enabled)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.backgroundGradient.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Blocks

    enum Block {
        case heading(level: Int, text: String)
        case bullet(String)
        case paragraph(String)

        @ViewBuilder var view: some View {
            switch self {
            case .heading(let level, let text):
                Text(PolicyDocumentView.inline(text))
                    .font(level <= 1 ? Typography.screenTitle : Typography.bodyEmphasis)
                    .padding(.top, Space.sm)
            case .bullet(let text):
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text("•").foregroundStyle(.secondary)
                    Text(PolicyDocumentView.inline(text))
                }
                .font(Typography.body)
            case .paragraph(let text):
                Text(PolicyDocumentView.inline(text))
                    .font(Typography.body)
            }
        }
    }

    /// Splits the document into the block kinds worth distinguishing. Anything
    /// unrecognised stays a paragraph, so an operator using syntax this does not
    /// know still gets readable text rather than a blank screen.
    nonisolated static func blocks(of markdown: String) -> [Block] {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }

                if trimmed.hasPrefix("#") {
                    let hashes = trimmed.prefix { $0 == "#" }
                    let text = trimmed
                        .dropFirst(hashes.count)
                        .trimmingCharacters(in: .whitespaces)
                    return .heading(level: hashes.count, text: text)
                }
                for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
                    return .bullet(String(trimmed.dropFirst(marker.count)))
                }
                return .paragraph(trimmed)
            }
    }

    /// Bold, italics, and links within one line. Falls back to the raw string,
    /// which is the honest outcome for malformed markup: show what was written.
    nonisolated static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
