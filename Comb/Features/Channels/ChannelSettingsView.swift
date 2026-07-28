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

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var about: String
    @State private var isSaving = false
    @State private var saveFailure: String?
    @State private var isDeleting = false
    @State private var deleteConfirmation = ""
    @State private var deleteFailure: String?

    init(session: CommunitySession, channel: ChannelSummary) {
        self.session = session
        self.channel = channel
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
                        Label("Delete channel", systemImage: "trash")
                    }
                } header: {
                    Text("Danger")
                } footer: {
                    // Said before the dialog, not only inside it. Someone should
                    // be able to decide not to tap the button in the first place.
                    Text("The channel and its messages go for everyone. There is no undoing it.")
                }
                .combRows()
            }
        }
        .combForm()
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
            .disabled(deleteConfirmation != channel.name)
        } message: {
            Text("This cannot be undone. Type \(channel.name) to confirm.")
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
                saveFailure = "Those changes did not save."
            }
        } catch {
            saveFailure = "Those changes did not save."
        }
        isSaving = false
    }

    private func deleteChannel() async {
        deleteConfirmation = ""
        do {
            try await session.deleteChannel(channel.id)
            dismiss()
        } catch let error as RelayError {
            if case .publishRejected(let reason) = error, !reason.isEmpty {
                deleteFailure = reason
            } else {
                deleteFailure = "That channel could not be deleted."
            }
        } catch {
            deleteFailure = "That channel could not be deleted."
        }
    }
}
