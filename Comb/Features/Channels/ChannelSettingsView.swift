import CombNet
import CombStore
import SwiftUI

/// What a channel's owners and admins can change about it.
///
/// Every action here is gated by the relay on a role, and none of it is
/// enforced in Comb. `mayModerate` and `mayDeleteChannel` decide what to
/// *offer*, from a roster that arrives on a historical query and may be minutes
/// old, and they say yes when the relay publishes no roles at all rather than
/// costing a reader an action they may be entitled to. What actually happens is
/// the relay's decision, reported in the relay's own words.
struct ChannelSettingsView: View {
    let session: CommunitySession
    let channel: ChannelSummary
    /// Called instead of dismissing this screen, because after a delete there
    /// is no channel to go back to.
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var about: String
    @State private var isSaving = false
    @State private var saveFailure: String?
    @State private var isDeleting = false
    @State private var deleteConfirmation = ""
    @State private var deleteFailure: String?
    @State private var isDeletingNow = false
    /// What the channel is about to take with it.
    @State private var messageCount = 0

    init(
        session: CommunitySession,
        channel: ChannelSummary,
        onDeleted: @escaping () -> Void
    ) {
        self.session = session
        self.channel = channel
        self.onDeleted = onDeleted
        _name = State(initialValue: channel.name)
        _about = State(initialValue: channel.about ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedName != channel.name
            || about.trimmingCharacters(in: .whitespacesAndNewlines) != (channel.about ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("What it is for", text: $about, axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text("Channel")
            } footer: {
                if let saveFailure {
                    InlineNotice(kind: .failure, text: saveFailure)
                }
            }
            .combRows()

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        Label { Text("Saving…") } icon: { ProgressView().controlSize(.small) }
                    } else {
                        Label("Save changes", systemImage: "checkmark")
                    }
                }
                .disabled(isSaving || trimmedName.isEmpty || !hasChanges)
            }
            .combRows()

            if channel.mayDeleteChannel {
                Section {
                    Button(role: .destructive) {
                        isDeleting = true
                    } label: {
                        if isDeletingNow {
                            Label { Text("Deleting…") } icon: { ProgressView().controlSize(.small) }
                        } else {
                            Label("Delete channel", systemImage: "trash")
                        }
                    }
                    .disabled(isDeletingNow)
                } footer: {
                    // Said before the dialog, not only inside it, so the
                    // decision not to tap is available. And said in terms of
                    // what is lost and whose it is: a typed confirmation
                    // protects the person tapping from a mis-tap, and nothing
                    // in it is about the people whose conversation ends.
                    Text(destructionSummary)
                }
                .combRows()
            }
        }
        .combForm()
        .task { messageCount = (try? session.store.messageCount(in: channel.id)) ?? 0 }
        .navigationTitle("Channel settings")
        .navigationBarTitleDisplayMode(.inline)
        .animation(Motion.fast, value: saveFailure)
        // A typed confirmation, which nothing else in the app asks for. The
        // other destructive actions here are recoverable or affect one message;
        // this one ends a room and everything said in it, for everybody.
        .alert("Delete \(channel.name)?", isPresented: $isDeleting) {
            TextField("Type the channel name", text: $deleteConfirmation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { deleteConfirmation = "" }
            Button("Delete channel", role: .destructive) {
                Task { await deleteChannel() }
            }
            // Verified on iOS 26.5 with a standalone probe: `.disabled` inside
            // an alert is honoured and re-evaluated while the alert is up. It
            // is undocumented, so if this ever regresses the failure is an
            // always-live delete button. Worth re-checking on a new OS.
            .disabled(deleteConfirmation != channel.name)
        } message: {
            // The footer already said it cannot be undone; repeating it here
            // spends the reader's attention on a fact they just accepted.
            Text("Type \(channel.name) to confirm.")
        }
        .alert(
            "That channel is still here",
            isPresented: Binding(
                get: { deleteFailure != nil },
                set: { if !$0 { deleteFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deleteFailure = nil }
        } message: {
            Text(deleteFailure ?? "")
        }
    }

    private func save() async {
        isSaving = true
        saveFailure = nil
        do {
            try await session.editChannel(channel.id, name: name, about: about)
            dismiss()
        } catch let error as RelayError {
            if case .publishRejected(let reason) = error, !reason.isEmpty {
                saveFailure = reason
            } else {
                saveFailure = "The community did not accept those changes. The channel still says what it said."
            }
        } catch {
            saveFailure = "The community did not accept those changes. The channel still says what it said."
        }
        isSaving = false
    }

    /// What is about to be destroyed, in people and messages.
    private var destructionSummary: String {
        let people = channel.memberCount == 1 ? "1 person" : "\(channel.memberCount) people"
        let messages = messageCount == 1 ? "1 message" : "\(messageCount.formatted()) messages"
        return "Deleting this channel removes \(messages) for \(people), including everyone else's. It cannot be brought back."
    }

    private func deleteChannel() async {
        deleteConfirmation = ""
        isDeletingNow = true
        do {
            try await session.deleteChannel(channel.id)
            onDeleted()
        } catch let error as RelayError {
            if case .publishRejected(let reason) = error, !reason.isEmpty {
                deleteFailure = reason
            } else {
                deleteFailure = "The community did not delete it."
            }
        } catch {
            deleteFailure = "The community did not delete it."
        }
        isDeletingNow = false
    }
}
