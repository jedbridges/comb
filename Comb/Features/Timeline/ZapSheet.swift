import CombCore
import SwiftUI

/// Picks a zap amount and hands the resulting invoice to a Lightning wallet.
///
/// Comb never moves the money. It produces a bolt11 invoice and opens it with
/// `lightning:`, which the OS routes to whatever wallet the user has. If no
/// wallet is installed, the invoice is offered for copying instead.
struct ZapSheet: View {
    let session: CommunitySession
    let recipient: PublicKey
    let lightningAddress: String
    let messageID: String?
    let recipientName: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var amount: Int64 = 21
    @State private var comment = ""
    @State private var phase: Phase = .choosing

    private enum Phase: Equatable {
        case choosing
        case preparing
        case ready(invoice: String)
        case failed(String)
    }

    /// The customary sat amounts. 21 is the Nostr default and the sensible
    /// starting selection.
    private static let presets: [Int64] = [21, 100, 500, 1000, 5000, 21000]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    presetGrid
                } header: {
                    Text("Zap \(recipientName)")
                } footer: {
                    Text("\(amount.formatted()) sats")
                        .font(Typography.captionEmphasis)
                        .foregroundStyle(Palette.chartreuse)
                }

                Section("Comment (optional)") {
                    TextField("Say something", text: $comment, axis: .vertical)
                        .lineLimit(1...3)
                }

                if case .failed(let message) = phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Zap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(
                    title: primaryTitle,
                    isBusy: phase == .preparing,
                    isDisabled: phase == .preparing
                ) {
                    Task { await act() }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xs)
            }
        }
        .presentationDetents([.medium])
    }

    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: Space.sm) {
            ForEach(Self.presets, id: \.self) { preset in
                Button {
                    amount = preset
                } label: {
                    Text("\(preset.formatted())")
                        .font(Typography.actionSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.sm)
                        .background(
                            amount == preset ? Palette.chartreuse.opacity(0.45) : Palette.surface.opacity(0.4),
                            in: .rect(cornerRadius: Radii.control)
                        )
                        .foregroundStyle(amount == preset ? Palette.oliveInk : Palette.text)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Space.xxs)
    }

    private var primaryTitle: String {
        switch phase {
        case .choosing: "Zap \(amount.formatted()) sats"
        case .preparing: "Preparing…"
        case .ready: "Open in wallet"
        case .failed: "Try again"
        }
    }

    private func act() async {
        switch phase {
        case .ready(let invoice):
            open(invoice)
        default:
            await prepare()
        }
    }

    private func prepare() async {
        phase = .preparing
        let result = await session.prepareZap(
            toLightningAddress: lightningAddress,
            recipient: recipient,
            amountSats: amount,
            comment: comment,
            messageID: messageID
        )

        switch result {
        case .invoice(let invoice):
            phase = .ready(invoice: invoice)
            // Straight to the wallet: the extra tap would only be friction.
            open(invoice)
        case .unsupported:
            phase = .failed("\(recipientName) has not set up a Lightning wallet that accepts zaps.")
        case .failed(let message):
            phase = .failed(message)
        }
    }

    private func open(_ invoice: String) {
        guard let url = URL(string: "lightning:\(invoice)") else { return }
        openURL(url) { accepted in
            // No wallet claimed the link: leave the invoice copyable rather
            // than dead-ending.
            if !accepted {
                UIPasteboard.general.string = invoice
                phase = .failed("No Lightning wallet is installed. The invoice was copied to your clipboard.")
            } else {
                dismiss()
            }
        }
    }
}
