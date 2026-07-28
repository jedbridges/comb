import CombCore
import SwiftUI

/// Picks a zap amount and hands the resulting invoice to a Lightning wallet.
///
/// Comb never moves the money. It produces a bolt11 invoice and opens it with
/// `lightning:`, which the OS routes to whatever wallet the user has. If no
/// wallet is installed, the invoice is offered for copying instead.
///
/// Opening this sheet asks the recipient's wallet host what it accepts, so the
/// amounts on offer are the ones that will actually work. That is a request to
/// a third party, made because the reader tapped Zap and not because they
/// scrolled past a message.
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
    @State private var limits: Limits = .loading
    @State private var isCustom = false
    @State private var customText = ""
    @FocusState private var isCustomFocused: Bool

    private enum Phase: Equatable {
        case choosing
        case preparing
        case ready(CommunitySession.PreparedZap)
        /// A wallet took the invoice. Deliberately not `paid`: Comb has no way
        /// to know that, and a case named for what the reader hopes happened is
        /// how the hope ends up in the copy.
        case handedOff(CommunitySession.PreparedZap)
        case failed(String)
    }

    /// What the recipient's endpoint accepts, once it has told us.
    ///
    /// `unknown` is not a failure state. If the pre-flight cannot reach the
    /// host, the sheet still lets the reader try: the invoice request may well
    /// succeed, and refusing up front on a failed guess would be worse than the
    /// guessing it replaced.
    private enum Limits: Equatable {
        case loading
        case known(low: Int64, high: Int64, commentLength: Int)
        case unknown
    }

    /// The customary sat amounts. 21 is the Nostr default and the sensible
    /// starting selection.
    private static let customary: [Int64] = [21, 100, 500, 1000, 5000, 21000]

    /// The customary amounts this recipient can actually be sent. An endpoint
    /// with a floor above 21000 sats used to leave every chip unpayable with no
    /// way to reach a working number.
    private var presets: [Int64] {
        guard case .known(let low, let high, _) = limits else { return Self.customary }
        return Self.customary.filter { $0 * 1000 >= low && $0 * 1000 <= high }
    }

    private var commentLimit: Int? {
        guard case .known(_, _, let length) = limits else { return nil }
        return length
    }

    /// Unknown limits mean the comment field stays, as it always did. A known
    /// zero means the endpoint takes no comment, and offering one anyway only
    /// buys a rejection later.
    private var allowsComment: Bool {
        commentLimit.map { $0 > 0 } ?? true
    }

    private var canSend: Bool {
        guard amount > 0 else { return false }
        guard case .known(let low, let high, _) = limits else { return true }
        return amount * 1000 >= low && amount * 1000 <= high
    }

    private var isHandedOff: Bool {
        if case .handedOff = phase { return true }
        return false
    }

    private var rangeNote: String? {
        guard case .known(let low, let high, _) = limits else { return nil }
        return "\(recipientName) accepts \((low / 1000).formatted()) to "
            + "\((high / 1000).formatted()) sats."
    }

    var body: some View {
        NavigationStack {
            if case .handedOff(let zap) = phase {
                handedOff(zap)
            } else {
                chooser
            }
        }
        // Medium is the right opening size: the amounts and the explanation fit,
        // and a zap is usually one tap. Large is offered because the comment
        // field otherwise sits against the button, and someone who actually
        // wants to write something should not have to compose it through a
        // letterbox.
        //
        // Once the invoice is gone the sheet settles back down. Someone who
        // dragged to large to write a comment would otherwise get their
        // confirmation as a full-height sheet with a bolt floating in it: the
        // task is over, and the sheet should stop taking the room the task
        // needed.
        .presentationDetents(isHandedOff ? [.medium] : [.medium, .large])
        .task { await loadLimits() }
    }

    /// What the reader sees once a wallet has the invoice.
    ///
    /// The sheet used to dismiss itself here, the instant iOS said a wallet had
    /// claimed the link, which is before any payment exists. That made a
    /// completed zap and an abandoned one look identical, and the silence read
    /// as confirmation.
    ///
    /// Returning from the wallet deliberately changes nothing on this screen.
    /// Coming back to Comb is not evidence of payment, and a checkmark here
    /// would be the app inventing a fact it does not have.
    private func handedOff(_ zap: CommunitySession.PreparedZap) -> some View {
        VStack(spacing: Space.md) {
            Spacer()

            Image(systemName: "bolt.fill")
                .font(.system(size: Sizing.stateGlyph))
                .foregroundStyle(Palette.chartreuse)

            Text("\(zap.amountMillisats / 1000) sats to \(recipientName)")
                .textRole(.control)

            // Leads with the fact Comb owns. It is certain the reader chose to
            // send and that a wallet took the invoice; only settlement is
            // unknowable. The old wording made Comb the subject of a negation
            // ("it cannot tell"), so a 44pt bolt said yes while the paragraph
            // under it said maybe, and the paragraph won.
            Text("Your wallet has the invoice for \(zap.amountMillisats / 1000) sats. Pay it there. The zap appears on the message when \(recipientName)'s wallet publishes a receipt, which is the only way Comb learns a zap was paid.")
                .textRole(.support)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.lg)

            Spacer()

            VStack(spacing: Space.xs) {
                SecondaryButton(title: "Copy invoice") {
                    UIPasteboard.general.string = zap.invoice
                }
                PrimaryButton(title: "Done") { dismiss() }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.xs)
        }
        .navigationTitle("Zap")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chooser: some View {
        Group {
            Form {
                Section {
                    presetGrid
                } header: {
                    Text("Zap \(recipientName)")
                } footer: {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text("\(amount.formatted()) sats")
                            .textRole(.metaStrong, canSend ? .brand : .muted)
                        if let rangeNote {
                            Text(rangeNote)
                                .textRole(.meta)
                        }
                    }
                }
                .combRows()

                if isCustom {
                    Section {
                        TextField("Amount in sats", text: $customText)
                            .keyboardType(.numberPad)
                            .focused($isCustomFocused)
                            .onChange(of: customText) { _, new in
                                // Digits only. The number pad still admits
                                // paste, and a stray character would otherwise
                                // silently zero the amount.
                                let digits = new.filter(\.isNumber)
                                if digits != new { customText = digits }
                                amount = Int64(digits) ?? 0
                            }
                    } header: {
                        Text("Custom amount")
                    }
                    .combRows()
                }

                if allowsComment {
                    Section {
                        TextField("Say something", text: $comment, axis: .vertical)
                            .lineLimit(1...3)
                            .onChange(of: comment) { _, new in
                                guard let limit = commentLimit, new.count > limit else { return }
                                comment = String(new.prefix(limit))
                            }
                    } header: {
                        Text("Comment (optional)")
                    } footer: {
                        if let limit = commentLimit {
                            Text("\(comment.count) of \(limit)")
                                .textRole(.meta)
                        }
                    }
                    .combRows()
                }
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
                            .textRole(.support, .primary)
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
                        // InlineNotice rather than a third hand-rolled copy of it, and
                            // because .meta is 11pt: a failure should not be the smallest
                            // type on the screen it happened on.
                            InlineNotice(kind: .failure, text: message)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.opacity)
                    }

                    PrimaryButton(
                        title: primaryTitle,
                        isBusy: phase == .preparing,
                        isDisabled: phase == .preparing || !canSend
                    ) {
                        Task { await act() }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xs)
                .animation(Motion.fast, value: phase)
            }
        }
    }

    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: Space.sm) {
            ForEach(presets, id: \.self) { preset in
                presetChip(preset)
            }
            otherChip
        }
        .padding(.vertical, Space.xxs)
        .animation(Motion.fast, value: presets)
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
        chip(String(preset.formatted()), isSelected: !isCustom && amount == preset) {
            isCustom = false
            amount = preset
        }
    }

    /// The escape hatch. Without it the six customary amounts are the only
    /// amounts, which is fine until a recipient's floor sits above all of them.
    @ViewBuilder
    private var otherChip: some View {
        chip("Other", isSelected: isCustom) {
            isCustom = true
            customText = ""
            amount = 0
            isCustomFocused = true
        }
    }

    @ViewBuilder
    private func chip(_ title: String, isSelected: Bool, act: @escaping () -> Void) -> some View {
        let label = Text(title)
            .textRole(.control, isSelected ? .onBrand : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.sm)

        Button(action: act) {
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
        case .choosing: amount > 0 ? "Zap \(amount.formatted()) sats" : "Choose an amount"
        case .preparing: "Preparing…"
        case .ready, .handedOff: "Open in wallet"
        case .failed: "Try again"
        }
    }

    private func loadLimits() async {
        switch await session.zapLimits(toLightningAddress: lightningAddress) {
        case .limits(let low, let high, let commentLength):
            limits = .known(low: low, high: high, commentLength: commentLength)
            reconcileAmount(low: low, high: high)
        case .unsupported:
            limits = .unknown
            phase = .failed("\(recipientName) has not set up a Lightning wallet that accepts zaps.")
        case .failed(let message):
            limits = .unknown
            phase = .failed(message)
        }
    }

    /// Moves the default onto something payable once the endpoint has spoken.
    /// The opening 21 is a guess, and leaving it selected when the floor is
    /// higher would put an unpayable number under a live button.
    private func reconcileAmount(low: Int64, high: Int64) {
        guard !isCustom else { return }
        let lowSats = Swift.max(1, low / 1000), highSats = high / 1000
        if amount < lowSats {
            amount = presets.first ?? lowSats
        } else if amount > highSats {
            amount = presets.last ?? highSats
        }
    }

    private func act() async {
        switch phase {
        case .ready(let zap), .handedOff(let zap):
            open(zap)
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
        case .prepared(let zap):
            phase = .ready(zap)
            // Straight to the wallet: the extra tap would only be friction.
            open(zap)
        case .unsupported:
            phase = .failed("\(recipientName) has not set up a Lightning wallet that accepts zaps.")
        case .failed(let message):
            phase = .failed(message)
        }
    }

    private func open(_ zap: CommunitySession.PreparedZap) {
        guard let url = URL(string: "lightning:\(zap.invoice)") else {
            // Previously a bare return, which left the button saying "Open in
            // wallet" and doing nothing at all.
            offerToCopy(zap.invoice, because: "Comb could not open that invoice.")
            return
        }
        openURL(url) { accepted in
            // No wallet claimed the link: leave the invoice copyable rather
            // than dead-ending.
            guard accepted else {
                offerToCopy(zap.invoice, because: "No Lightning wallet is installed.")
                return
            }
            phase = .handedOff(zap)
            Task { await session.recordZapHandoff(zap) }
        }
    }

    private func offerToCopy(_ invoice: String, because reason: String) {
        UIPasteboard.general.string = invoice
        phase = .failed("\(reason) Comb copied the invoice so you can paste it into one.")
    }
}
