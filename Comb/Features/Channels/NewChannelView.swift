import CombNet
import SwiftUI

/// Makes a channel in the current community.
///
/// Anyone may do this: creating is the one NIP-29 admin action the relay puts
/// no owner or admin requirement on, and whoever creates a channel becomes its
/// owner. That is why this sits beside the channel list rather than behind a
/// permission the app has no way to check.
struct NewChannelView: View {
    let session: CommunitySession
    /// Handed the new channel's id so the caller can open it.
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var about = ""
    @State private var isPrivate = false
    @State private var isCreating = false
    @State private var failure: String?
    @FocusState private var isNaming: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($isNaming)
                        .submitLabel(.done)
                        .onSubmit { if !trimmedName.isEmpty { Task { await create() } } }
                } header: {
                    Text("Channel")
                } footer: {
                    Text("People in this community will see the name.")
                }
                .combRows()

                Section {
                    Toggle("Invite only", isOn: $isPrivate)
                } footer: {
                    // Said plainly because it is not reversible from here.
                    // Editing a channel's settings afterwards is owner and
                    // admin only, and Comb has no screen for it, so this choice
                    // is made once.
                    Text(isPrivate
                        ? "Only people an owner adds can join. Comb cannot change this later."
                        : "Anyone in this community can join. Comb cannot change this later.")
                }
                .combRows()

                Section {
                    TextField("What it is for", text: $about, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Description (optional)")
                }
                .combRows()
            }
            .combForm()
            .navigationTitle("New channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Space.xs) {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .textRole(.meta, .danger)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }

                    PrimaryButton(
                        title: isCreating ? "Creating…" : "Create channel",
                        isBusy: isCreating,
                        isDisabled: isCreating || trimmedName.isEmpty
                    ) {
                        Task { await create() }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xs)
                .animation(Motion.fast, value: failure)
            }
        }
        // Large only, unlike the zap sheet's medium. A zap is one tap on a
        // number; this is three fields and a decision that cannot be undone,
        // and at the medium detent the description field lays out underneath
        // the button in the bottom inset.
        .presentationDetents([.large])
        .task { isNaming = true }
    }

    private func create() async {
        isCreating = true
        failure = nil
        do {
            let id = try await session.createChannel(
                name: name,
                about: about,
                isPrivate: isPrivate
            )
            dismiss()
            onCreated(id)
        } catch let error as RelayError {
            // The relay's own words. It refuses a blank name and can refuse a
            // create outright on a community that restricts who may publish,
            // and both are more useful than anything this screen could invent.
            if case .publishRejected(let reason) = error, !reason.isEmpty {
                failure = reason
            } else {
                failure = "That channel could not be created."
            }
            isCreating = false
        } catch {
            failure = "That channel could not be created."
            isCreating = false
        }
    }
}
