import SwiftUI
import UniformTypeIdentifiers

/// A readable tail of the local log, with copy and clear.
///
/// This is the whole of Comb's "telemetry": on-device, user-readable, shared
/// only when the person taps Copy and pastes it somewhere themselves.
struct DiagnosticsView: View {
    @State private var buffer = DiagnosticsBuffer.shared
    @State private var didCopy = false

    var body: some View {
        Form {
            Section {
                Text("Comb keeps this log on your iPhone and sends it nowhere. If you hit a bug, copy it into a GitHub issue so it can be fixed.")
                    .textRole(.support)
            }
            .combRows()

            if buffer.entries.isEmpty {
                Section {
                    Text("Nothing logged yet.")
                        .textRole(.support)
                }
                .combRows()
            } else {
                Section("Recent activity") {
                    ForEach(buffer.entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: Space.hairline) {
                            HStack {
                                Text(entry.category)
                                    .textRole(.eyebrow)
                                Spacer()
                                Text(entry.at, format: .dateTime.hour().minute().second())
                                    .textRole(.meta)
                            }
                            Text(entry.message)
                                .textRole(.monoSupport, .primary)
                        }
                        .padding(.vertical, Space.hairline)
                    }
                }
                .combRows()
            }
        }
        .combForm()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(didCopy ? "Copied" : "Copy log", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = buffer.exportText()
                        withAnimation(Motion.instant) { didCopy = true }
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            didCopy = false
                        }
                    }
                    Button("Clear", systemImage: "trash", role: .destructive) {
                        buffer.clear()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Log actions")
            }
        }
    }
}
