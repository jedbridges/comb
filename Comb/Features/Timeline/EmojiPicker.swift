import SwiftUI

/// The full emoji palette, in a sheet.
///
/// iOS ships no system emoji picker a view can present (the keyboard's is
/// the keyboard's), so this is hand-built: a categorised grid with search
/// and a recents row that learns what this person actually reaches for.
///
/// The set is deliberately curated rather than enumerated from Unicode. A
/// generated list carries every skin-tone and profession variant, thousands
/// of entries where a chat client needs the few hundred people use, and
/// wrongly assumes the running OS can draw glyphs added after it shipped.
struct EmojiPicker: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var recents = EmojiRecents.load()

    private var results: [Emoji.Category] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return Emoji.categories }

        return Emoji.categories.compactMap { category in
            let matches = category.emoji.filter { entry in
                entry.keywords.contains { $0.localizedCaseInsensitiveContains(needle) }
            }
            return matches.isEmpty
                ? nil
                : Emoji.Category(name: category.name, symbol: category.symbol, emoji: matches)
        }
    }

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Space.xs),
        count: 6
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.md, pinnedViews: [.sectionHeaders]) {
                    if query.isEmpty, !recents.isEmpty {
                        section(name: "Recent", emoji: recents.map { Emoji.Entry($0, []) })
                    }

                    ForEach(results) { category in
                        section(name: category.name, emoji: category.emoji)
                    }

                    if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, Space.xxl)
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.vertical, Space.sm)
            }
            .softScrollEdges()
            .background(Palette.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Add a reaction")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search emoji")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func section(name: String, emoji: [Emoji.Entry]) -> some View {
        Section {
            LazyVGrid(columns: columns, spacing: Space.xs) {
                ForEach(emoji) { entry in
                    Button {
                        EmojiRecents.record(entry.value)
                        onPick(entry.value)
                        dismiss()
                    } label: {
                        Text(entry.value)
                            .font(.system(size: 30))
                            .frame(maxWidth: .infinity, minHeight: Sizing.hitTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.keywords.first ?? entry.value)
                }
            }
        } header: {
            Text(name)
                .font(Typography.eyebrow)
                .kerning(Kerning.eyebrow)
                .foregroundStyle(Palette.subtext)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Space.xxs)
                .background(Palette.backgroundGradient.opacity(0.01))
        }
    }
}

/// What this person reaches for, most recent first.
///
/// Local only, and deliberately so: reaction habits are behaviour, and
/// publishing them would be telling the relay something it never asked for.
enum EmojiRecents {
    private static let key = "comb.emoji.recents"
    private static let limit = 12

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ emoji: String) {
        var recents = load().filter { $0 != emoji }
        recents.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(limit)), forKey: key)
    }
}
