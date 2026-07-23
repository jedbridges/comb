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
                    .font(Typography.secondary)
                    .foregroundStyle(Palette.subtext)
            }

            if buffer.entries.isEmpty {
                Section {
                    Text("Nothing logged yet.")
                        .font(Typography.secondary)
                        .foregroundStyle(Palette.subtext)
                }
            } else {
                Section("Recent activity") {
                    ForEach(buffer.entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: Space.hairline) {
                            HStack {
                                Text(entry.category)
                                    .font(Typography.eyebrow)
                                    .foregroundStyle(Palette.subtext)
                                Spacer()
                                Text(entry.at, format: .dateTime.hour().minute().second())
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.subtext)
                            }
                            Text(entry.message)
                                .font(Typography.monoSmall)
                                .foregroundStyle(Palette.text)
                        }
                        .padding(.vertical, Space.hairline)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.backgroundGradient.ignoresSafeArea())
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
            }
        }
    }
}
