import CombStore
import SwiftUI

/// Every allowance given, what is left of each, and what agents actually did.
///
/// The design weight of this feature is here rather than in the grant sheet, and
/// deliberately. Trust in a standing permission does not come from the dials you
/// set once; it comes from being able to see afterwards what was spent, by
/// whom, and what was stopped. So this is a ledger with a meter on top, not a
/// meter with a ledger hidden behind it.
///
/// Refusals are shown alongside payments. A refusal that happened silently
/// teaches nobody anything and reads as a bug the next time an agent seems idle.
struct SpendingView: View {
    let session: CommunitySession

    @State private var grants: [SpendGrant] = []
    @State private var ledger: [SpendRecord] = []
    /// Spent-in-window per grant, recomputed with the ledger so the meter and
    /// the lines below it can never disagree.
    @State private var spent: [String: Int64] = [:]
    @State private var names: [String: String] = [:]

    var body: some View {
        Group {
            if grants.isEmpty, ledger.isEmpty {
                ContentUnavailableView(
                    "No allowances",
                    systemImage: "bolt.badge.clock",
                    description: Text(
                        "Give an agent an allowance from the member list of a channel, and it can zap on your behalf without asking each time."
                    )
                )
            } else {
                list
            }
        }
        .background(Palette.backgroundGradient.ignoresSafeArea())
        .navigationTitle("Spending")
        .navigationBarTitleDisplayMode(.inline)
        .task { await observe() }
    }

    private var list: some View {
        Form {
            ForEach(grants) { grant in
                Section {
                    meter(for: grant)
                    Button(role: .destructive) {
                        stop(grant)
                    } label: {
                        Label("Stop this allowance", systemImage: "bolt.slash")
                    }
                } header: {
                    Text(name(grant.agentPubkey))
                } footer: {
                    Text(
                        "Up to \(grant.perZapSats.formatted()) sats at a time, "
                            + "\(grant.allowanceSats.formatted()) sats over 24 hours."
                    )
                }
                .combRows()
            }

            if !ledger.isEmpty {
                Section {
                    ForEach(ledger) { record in
                        row(record)
                    }
                } header: {
                    Text("Recent")
                } footer: {
                    // Says plainly that the agent is not told, because that is a
                    // real limitation of the design and the reader should not
                    // discover it by watching an agent retry.
                    Text("Refusals are shown here and nowhere else. An agent is never told its limits, so a refused one only learns its zap did not appear.")
                }
                .combRows()
            }
        }
        .combForm()
    }

    /// How much of an allowance is left, as a bar and a number.
    private func meter(for grant: SpendGrant) -> some View {
        let used = spent[grant.id] ?? 0
        let fraction = grant.allowanceMillisats > 0
            ? Double(used) / Double(grant.allowanceMillisats)
            : 0

        return VStack(alignment: .leading, spacing: Space.xs) {
            Text("\((used / 1000).formatted()) of \(grant.allowanceSats.formatted()) sats today")
                .font(Typography.captionEmphasis)
                .foregroundStyle(Palette.text)

            // Chartreuse only as it fills, which is the one thing on this screen
            // worth the accent: it is the number the reader came to check.
            ProgressView(value: min(1, fraction))
                .tint(Palette.chartreuse)
                .accessibilityLabel(
                    "\(used / 1000) of \(grant.allowanceSats) sats spent in the last 24 hours"
                )
        }
    }

    private func row(_ record: SpendRecord) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: glyph(record.state))
                .font(Typography.icon)
                .foregroundStyle(tone(record.state))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.hairline) {
                Text("\(name(record.agentPubkey)) · \(record.amountSats.formatted()) sats")
                    .font(Typography.label)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                // The reason, for both refusals and failures. This is the whole
                // value of the row: "refused" on its own is useless, and an
                // empty balance and an uninvited agent want different reactions.
                if let reason = record.reason, !reason.isEmpty {
                    Text(reason)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            Text(record.date, format: .relative(presentation: .numeric))
                .font(Typography.caption)
                .foregroundStyle(Palette.subtext)
        }
        .accessibilityElement(children: .combine)
    }

    private func glyph(_ state: SpendState) -> String {
        switch state {
        case .paid: "bolt.fill"
        case .paying: "clock"
        case .refused: "hand.raised"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func tone(_ state: SpendState) -> Color {
        switch state {
        case .paid: Palette.chartreuse
        case .paying, .refused: Palette.subtext
        case .failed: Palette.danger
        }
    }

    private func name(_ pubkey: String) -> String {
        names[pubkey] ?? String(pubkey.prefix(8))
    }

    private func observe() async {
        // A failure here means the store could not be read at all. There is
        // nothing useful to show and nothing to retry from this screen, so the
        // meter stays as it was rather than blanking.
        try? await observeChanges()
    }

    private func observeChanges() async throws {
        for try await records in session.store.observeSpending() {
            ledger = records
            grants = (try? session.store.spendGrants()) ?? []

            var totals: [String: Int64] = [:]
            for grant in grants {
                totals[grant.id] = (try? session.store.spent(
                    agent: grant.agentPubkey,
                    channel: grant.channelID,
                    window: grant.windowSeconds
                )) ?? 0
            }
            spent = totals

            // Resolved once per change rather than per row, and only for keys
            // actually on screen.
            var resolved = names
            for pubkey in Set(grants.map(\.agentPubkey) + records.map(\.agentPubkey)) {
                guard resolved[pubkey] == nil else { continue }
                resolved[pubkey] = (try? session.store.profile(pubkey: pubkey))?.name
                    ?? String(pubkey.prefix(8))
            }
            names = resolved
        }
    }

    private func stop(_ grant: SpendGrant) {
        Task {
            try? await session.store.revokeGrant(
                agent: grant.agentPubkey, channel: grant.channelID
            )
            grants = (try? session.store.spendGrants()) ?? []
        }
    }
}
