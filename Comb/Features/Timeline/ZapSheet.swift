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
    @State private var isExplaining = false

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
                .combRows()

                Section {
                    TextField("Say something", text: $comment, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Comment (optional)")
                }
                .combRows()

            }
            .combForm()
            .navigationTitle("Zap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Behind an icon rather than printed under the amounts.
                    // The explanation is for the first zap and roughly never
                    // again, and as standing body copy it took more of a small
                    // sheet than a sentence most readers already know deserves.
                    // Reachable, not recited.
                    Button {
                        isExplaining = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("What is a zap?")
                    .popover(isPresented: $isExplaining) {
                        Text("A zap is a small Bitcoin tip, counted in sats. Comb never handles the money: it hands an invoice to a Lightning wallet on this iPhone, so you need one installed to pay it.")
                            .font(Typography.secondary)
                            .foregroundStyle(Palette.text)
                            .multilineTextAlignment(.leading)
                            // Both are needed. Without a definite width the
                            // popover sizes itself to the toolbar item it hangs
                            // from and elides the sentence to one line; without
                            // `fixedSize` the text refuses to grow downwards
                            // into the room that width just bought it.
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 260, alignment: .leading)
                            .padding(Space.md)
                            // Without this an iPhone would present the popover
                            // as a second sheet stacked over the first, which
                            // is a lot of ceremony for two sentences.
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: Space.xs) {
                    // Above the button rather than at the end of the form. As
                    // the form's last section it was laid out under the inset
                    // the button sits in, so at the medium detent the failure
                    // rendered behind the button and ran off the bottom of the
                    // sheet: the one moment the reader needs it is the one
                    // moment it could not be read.
                    if case .failed(let message) = phase {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.danger)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }

                    PrimaryButton(
                        title: primaryTitle,
                        isBusy: phase == .preparing,
                        isDisabled: phase == .preparing
                    ) {
                        Task { await act() }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xs)
                .animation(Motion.fast, value: phase)
            }
        }
        // Medium is the right opening size: the amounts and the explanation fit,
        // and a zap is usually one tap. Large is offered because the comment
        // field otherwise sits against the button, and someone who actually
        // wants to write something should not have to compose it through a
        // letterbox.
        .presentationDetents([.medium, .large])
    }

    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: Space.sm) {
            ForEach(Self.presets, id: \.self) { preset in
                presetChip(preset)
            }
        }
        .padding(.vertical, Space.xxs)
    }

    /// Glass when unchosen, solid chartreuse when chosen.
    ///
    /// The unchosen state was a flat `Palette.surface` wash, which is the "dead
    /// grey slab dropped on the gradient" the reaction chips already diagnosed:
    /// a literal grey fights the backdrop's hue instead of belonging to it.
    /// Glass is the app's own answer everywhere else it needs a quiet control,
    /// and it picks up the wash behind it rather than covering it.
    ///
    /// The chosen state stays a solid fill with ink on it. Glass over chartreuse
    /// frosts the one thing on this sheet that has to read as decided.
    @ViewBuilder
    private func presetChip(_ preset: Int64) -> some View {
        let isSelected = amount == preset
        let label = Text("\(preset.formatted())")
            .font(Typography.actionSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.sm)
            .foregroundStyle(isSelected ? Palette.ink : Palette.text)

        Button {
            amount = preset
        } label: {
            if isSelected {
                label.background(Palette.chartreuse, in: .rect(cornerRadius: Radii.control))
            } else {
                label.glassEffect(in: .rect(cornerRadius: Radii.control))
            }
        }
        .buttonStyle(.plain)
        .animation(Motion.fast, value: isSelected)
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
                phase = .failed("No Lightning wallet is installed. Comb copied the invoice so you can paste it into one.")
            } else {
                dismiss()
            }
        }
    }
}
