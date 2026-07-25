import CombStore
import SwiftUI

/// Reporting a message, and optionally blocking its author.
///
/// Two different things, offered together because they are what a person
/// actually wants at the same moment, and honest about the difference:
/// blocking takes effect immediately and only on this device, while a report
/// is a message to the people who run the community, which they may or may not
/// act on.
///
/// Comb has no moderation server of its own and will not invent one. A report
/// is published to the community's own relay as a NIP-56 report event, which
/// is the standard every Nostr moderation tool already reads.
struct ReportSheet: View {
    let session: CommunitySession
    let message: TimelineRow
    let channelID: String
    /// What to tell the user once the sheet is gone. The sheet dismisses either
    /// way, so this is the only place the outcome can still be said.
    var onOutcome: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var reason: Report.Reason = .spam
    @State private var alsoBlock = true
    @State private var isSending = false
    /// Set when the report did not send, so the sheet can stay and offer the
    /// retry rather than dismissing behind a notice that fades.
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(Report.Reason.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    // Deliberately untinted. Chartreuse marks the one most
                    // important thing on a screen, and here that is Send
                    // report. A checkmark on the chosen reason is already
                    // unambiguous without spending the loudest colour on it.
                    .pickerStyle(.inline)
                } header: {
                    Text("What is wrong with it")
                }
                .combRows()

                Section {
                    Toggle("Also block \(message.displayName)", isOn: $alsoBlock)
                        .tint(Palette.chartreuse)
                } footer: {
                    // The split stated plainly: one is instant and personal,
                    // the other is a request to someone else.
                    Text("Blocking hides everything from them on this iPhone, straight away. The report goes to the people who run this community.")
                }
                .combRows()

                Section {
                    Button {
                        send()
                    } label: {
                        RowLabel(
                            title: failure == nil ? "Send report" : "Try again",
                            systemImage: "flag"
                        )
                    }
                    .disabled(isSending)
                } footer: {
                    // The sheet stays open on failure rather than dismissing
                    // behind a toast. There is an obvious next action, the
                    // button offering it is right here, and a notice beside the
                    // control it belongs to cannot be missed the way something
                    // that fades in three seconds can.
                    if let failure {
                        InlineNotice(kind: .warning, text: failure)
                    }
                }
                .combRows()
            }
            .combForm()
            .navigationTitle("Report message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        isSending = true
        failure = nil
        Task {
            if alsoBlock {
                // Blocked first: it is the part that is guaranteed to work,
                // and it should hold even if the relay rejects the report.
                try? await session.store.block(pubkey: message.pubkey)
            }
            let sent = await session.report(
                message.id, author: message.pubkey, reason: reason, in: channelID
            )
            isSending = false

            guard sent else {
                // Naming the half that worked, rather than a bare failure:
                // blocking is the part the reporter can rely on, and it has
                // already taken effect whatever the relay did.
                failure = alsoBlock
                    ? FailureText.reportFailedButBlocked
                    : FailureText.reportFailed
                return
            }

            dismiss()
            // "Report sent" and nothing more: what the relay accepted is an
            // event, which is not evidence a person has read it. The sheet's
            // own footer already says where it goes and what it does not
            // promise.
            onOutcome(FailureText.reportSent)
        }
    }
}

/// NIP-56 report kinds, in the words a person would use.
enum Report {
    enum Reason: String, CaseIterable, Identifiable {
        case spam
        case harassment
        case illegal
        case nudity
        case other

        var id: String { rawValue }

        var label: String {
            switch self {
            case .spam: "Spam"
            case .harassment: "Harassment or hate"
            case .illegal: "Illegal content"
            case .nudity: "Nudity or sexual content"
            case .other: "Something else"
            }
        }

        /// The report type NIP-56 defines. `other` has no tag of its own, so
        /// it is sent with the reason in the content instead.
        var nip56Type: String? {
            switch self {
            case .spam: "spam"
            case .harassment: "profanity"
            case .illegal: "illegal"
            case .nudity: "nudity"
            case .other: nil
            }
        }
    }
}
