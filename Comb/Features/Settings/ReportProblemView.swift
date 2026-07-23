import SwiftUI

/// The path from "this is broken" to somewhere it can be read.
///
/// Comb ships no crash reporting and phones nothing home, which means a
/// tester's only route to the author was to find the Diagnostics screen,
/// realise it was relevant, copy it, and paste it somewhere. Most people would
/// simply not report the bug.
///
/// So the report is assembled here: what happened, in their words, with the
/// device, the version, and the recent log attached. Nothing is sent by the
/// app. The person picks the destination from the system share sheet, and
/// sees the whole payload before they do, because attaching a log to a
/// message somebody sends under their own name should never be a surprise.
struct ReportProblemView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var what = ""
    @State private var includesLog = true
    @State private var isShowingPayload = false

    /// Captured once, on appear, so the log does not shift under the preview
    /// while the person is reading it.
    @State private var log = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "What went wrong, and what were you doing?",
                        text: $what,
                        axis: .vertical
                    )
                    .lineLimit(4...10)
                } header: {
                    Text("What happened")
                } footer: {
                    // The one thing that actually determines whether a report
                    // is useful, said plainly rather than assumed.
                    Text("What you expected, and what happened instead, is worth more than anything the log can say.")
                }
                .combRows()

                Section {
                    Toggle("Attach the diagnostics log", isOn: $includesLog)
                        // The system green is nobody's brand colour and reads
                        // as a stray control from another app.
                        .tint(Palette.chartreuse)

                    Button("See exactly what will be sent") {
                        isShowingPayload = true
                    }
                    .disabled(!includesLog)
                } footer: {
                    Text("The log records connection events and errors. It never contains your key, your messages, or anyone's name.")
                }
                .combRows()

                Section {
                    ShareLink(item: report) {
                        RowLabel(title: "Send report", systemImage: "square.and.arrow.up")
                    }
                    .disabled(what.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    // For anyone who would rather file it where the work
                    // happens. Deliberately second: a TestFlight tester should
                    // not need a GitHub account to tell you something is
                    // broken.
                    Link(destination: Self.issuesURL) {
                        RowLabel(title: "Open an issue on GitHub", systemImage: "ladybug")
                    }
                } footer: {
                    Text("Comb sends nothing on its own. You choose where this goes.")
                }
                .combRows()
            }
            .combForm()
            .navigationTitle("Report a problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $isShowingPayload) {
                PayloadPreview(text: report)
            }
        }
        .task { log = DiagnosticsBuffer.shared.exportText() }
    }

    /// What gets shared. Assembled here rather than in the share sheet so the
    /// preview and the payload cannot drift apart.
    private var report: String {
        var parts = [
            "Comb problem report",
            "",
            what.trimmingCharacters(in: .whitespacesAndNewlines),
            "",
            Self.deviceLine,
        ]
        if includesLog {
            parts.append(contentsOf: ["", log])
        }
        return parts.joined(separator: "\n")
    }

    private static var deviceLine: String {
        let device = UIDevice.current
        return "\(device.systemName) \(device.systemVersion)"
    }

    private static let issuesURL = URL(string: "https://github.com/jedbridges/comb/issues/new")!
}

/// The whole payload, scrollable and selectable, before anything is sent.
private struct PayloadPreview: View {
    let text: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(Typography.monoSmall)
                    .foregroundStyle(Palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.md)
            }
            .softScrollEdges()
            .background(Palette.backgroundGradient.ignoresSafeArea())
            .navigationTitle("What will be sent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
