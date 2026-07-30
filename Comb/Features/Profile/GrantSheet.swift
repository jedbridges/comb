import CombStore
import SwiftUI

/// Gives an agent an allowance to spend in one channel.
///
/// Two dials and a sentence. The sentence is the point: an allowance is a
/// standing permission to move somebody's money, so the screen that creates one
/// should read back exactly what it is about to allow, in the words a person
/// would use, before they tap.
///
/// Reached from a member row, so the agent is already chosen and the channel is
/// already the one being read. Neither is a field here, because neither is a
/// decision the reader is making at this moment.
struct GrantSheet: View {
    let session: CommunitySession
    let agentPubkey: String
    let agentName: String
    let channelID: String
    let channelName: String

    @Environment(\.dismiss) private var dismiss

    /// The existing grant's dials when there is one, so opening this on an agent
    /// that already has an allowance edits it rather than silently replacing it
    /// with defaults.
    @State private var allowance: Int64 = 500
    @State private var perZap: Int64 = 100
    @State private var existing: SpendGrant?
    @State private var failure: String?

    /// A day, which is the only window anyone asks for in practice. Kept as a
    /// stored value rather than a field because offering a choice of window
    /// would be a third dial for a decision nobody has said they want.
    private let window: Int64 = 86_400

    private var isValid: Bool {
        allowance > 0 && perZap > 0 && perZap <= allowance
    }

    /// What this grant permits, as one sentence.
    ///
    /// Assembled rather than templated over the raw numbers so it stays readable
    /// at every value, and stated in sats because that is the unit the rest of
    /// the feature uses.
    private var sentence: String {
        guard isValid else {
            return perZap > allowance
                ? "A single zap cannot be larger than the whole allowance."
                : "Set an allowance and a limit for one zap."
        }
        return "\(agentName) can zap up to \(perZap.formatted()) sats at a time, "
            + "up to \(allowance.formatted()) sats a day, in \(channelName). "
            + "You can stop this any time."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(
                        "\(allowance.formatted()) sats a day",
                        value: $allowance,
                        in: 1...1_000_000,
                        step: allowance < 1000 ? 100 : 500
                    )
                } header: {
                    Text("Allowance")
                } footer: {
                    // Says which day. A calendar reset would let an agent spend
                    // a full allowance twice inside two minutes by straddling
                    // midnight, so the window rolls, and the copy has to match
                    // the code or one of them is lying.
                    Text("Counted over the last 24 hours, not reset at midnight.")
                }
                .combRows()

                Section {
                    Stepper(
                        "\(perZap.formatted()) sats at a time",
                        value: $perZap,
                        in: 1...1_000_000,
                        step: perZap < 1000 ? 50 : 500
                    )
                } header: {
                    Text("One zap")
                } footer: {
                    // Explains why there is no approve-each-spend option, since
                    // its absence is a decision rather than an omission.
                    Text("Anything larger is refused rather than asking you. A stream of approvals is one you stop reading.")
                }
                .combRows()

                Section {
                    Text(sentence)
                        .font(Typography.labelRegular)
                        .foregroundStyle(isValid ? Palette.text : Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .combRows()

                if let failure {
                    Section {
                        InlineNotice(kind: .failure, text: failure)
                    }
                    .combRows()
                }
            }
            .combForm()
            .navigationTitle(existing == nil ? "Allowance" : "Edit allowance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Space.xs) {
                    if existing != nil {
                        SecondaryButton(title: "Stop this allowance") { revoke() }
                    }
                    PrimaryButton(
                        title: existing == nil ? "Allow" : "Save",
                        isDisabled: !isValid
                    ) {
                        save()
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xs)
            }
            .task { load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        guard let grant = try? session.store.spendGrant(
            agent: agentPubkey, channel: channelID
        ) else { return }
        existing = grant
        allowance = grant.allowanceSats
        perZap = grant.perZapSats
    }

    private func save() {
        let grant = SpendGrant(
            agentPubkey: agentPubkey,
            channelID: channelID,
            allowanceMillisats: allowance * 1000,
            windowSeconds: window,
            perZapMillisats: perZap * 1000
        )
        Task {
            do {
                try await session.store.grant(grant)
                dismiss()
            } catch {
                failure = "Comb could not save this allowance."
            }
        }
    }

    private func revoke() {
        Task {
            do {
                try await session.store.revokeGrant(agent: agentPubkey, channel: channelID)
                dismiss()
            } catch {
                failure = "Comb could not stop this allowance."
            }
        }
    }
}
