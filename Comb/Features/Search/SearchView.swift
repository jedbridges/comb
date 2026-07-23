import CombStore
import SwiftUI

/// Finding something that was said.
///
/// Searches the local store, which answers instantly, works offline, and covers
/// everything this device has seen. That is the right default for a chat client:
/// people search for what they remember reading. Relay-side NIP-50 can widen
/// the net later without changing this screen.
struct SearchView: View {
    let session: CommunitySession

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    emptyState
                } else {
                    resultList
                }
            }
            // The one surface that lacked the gradient: the empty state has no
            // Form behind it, so without this it sat on raw system black and
            // read as a different app.
            .background(Palette.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search messages"
        )
        .onChange(of: query) { _, new in
            results = (try? session.store.search(new)) ?? []
            hasSearched = new.count >= 2
        }
    }

    private var resultList: some View {
        Form {
            Section {
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        HStack(spacing: Space.xs) {
                            Text(result.channelName)
                                .font(Typography.eyebrow)
                                .kerning(Kerning.eyebrow)
                                .foregroundStyle(Palette.chartreuse)
                            Spacer()
                            Text(result.date, format: .dateTime.month().day())
                                .font(Typography.caption)
                                .foregroundStyle(Palette.subtext)
                        }
                        Text(result.content)
                            .font(Typography.secondary)
                            .foregroundStyle(Palette.text)
                            .lineLimit(3)
                        Text(result.author)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.subtext)
                    }
                    .padding(.vertical, Space.xxs)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("\(results.count) \(results.count == 1 ? "result" : "results")")
            }
            .combRows()
        }
        .combForm()
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasSearched {
            ContentUnavailableView.search(text: query)
        } else {
            // Teaches what the search covers rather than sitting blank.
            ContentUnavailableView(
                "Find a message",
                systemImage: "magnifyingglass",
                description: Text("Searches every channel you have open, on this iPhone.")
            )
        }
    }
}
