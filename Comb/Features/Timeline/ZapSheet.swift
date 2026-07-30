import CombCore
import SwiftUI

/// Picks a zap amount and gets the resulting invoice paid.
///
/// Comb holds no balance and mints no invoices either way, but there are now two
/// endings and they differ in what can honestly be claimed.
///
/// With a wallet connected over NIP-47, Comb asks it to pay and the wallet
/// returns a preimage. That is settlement, so this is the one screen in the
/// feature allowed a plain "Paid", and the preimage goes straight out as an
/// attestation the channel can verify.
///
/// Without one, the invoice goes to the OS as a `lightning:` link and the story
/// ends at the handoff, because that is genuinely all Comb knows. If no wallet
/// claims the link, the invoice is offered for copying instead.
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
    /// The pre-flight could not reach the host, so the amounts on offer are
    /// guesses again. Held apart from `phase` because it is not an attempt: the
    /// invoice request may still succeed, so the chooser stays live, and the
    /// button must go on saying what it will do rather than offering to repeat
    /// something that never happened.
    @State private var preflightFailure: String?

    private enum Phase: Equatable {
        case choosing
        case preparing
        case ready(CommunitySession.PreparedZap)
        /// A wallet took the invoice. Deliberately not `paid`: Comb has no way
        /// to know that, and a case named for what the reader hopes happened is
        /// how the hope ends up in the copy.
        case handedOff(CommunitySession.PreparedZap)
        /// A connected wallet has the request and has not answered yet.
        case paying
        /// Settled, with a preimage to prove it. The only state in this feature
        /// that asserts a payment happened, and the only one entitled to: every
        /// other path ends at a handoff, where Comb genuinely cannot know.
        case paid(CommunitySession.PreparedZap)
        /// An attempt was made and did not work. Distinct from
        /// `preflightFailure`, which is something that happened before the
        /// reader did anything, and the distinction is what stops a button
        /// saying "Try again" to somebody who has not tried.
        case failed(String)
        /// The recipient cannot be paid at all, so there is nothing to choose.
        /// Terminal: no amounts, no retry, one way out.
        case refused(String)
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

    /// What a zap is, and what a sat is worth.
    ///
    /// The middle sentence is the one that was missing. "A small Bitcoin tip"
    /// names the category and says nothing about the size, and these readers are
    /// design-literate and deliberately not crypto-literate, so being asked to
    /// price a gift in sats was asking them to be. A hundred million to the
    /// bitcoin is a fixed fact that needs no network and never goes stale.
    ///
    /// There is no live conversion here and there will not be one. A rate means
    /// asking a price service, and a price service is a host the reader never
    /// chose, which ETHOS.md calls a bug by definition. So the absence is stated
    /// rather than left for the reader to notice: a screen that quietly declines
    /// to say what you are spending is worse than one that says why it cannot.
    static let explanation = """
        A zap is a Bitcoin tip, counted in sats. There are 100 million sats in \
        one bitcoin, so these are small amounts on purpose.

        Comb cannot show you what that is in your own currency, because looking \
        up a rate would mean asking a price service you never chose. It hands \
        an invoice to a Lightning wallet on this iPhone, so you need one \
        installed to pay it, and Comb never touches the money.
        """

    /// The customary sat amounts. 21 is the Nostr default and the sensible
    /// starting selection.
    ///
    /// Five, not six. With "Other" the grid is exactly two rows of three, and a
    /// third row holding one amount and one escape hatch made the picker the
    /// tallest thing on a sheet whose job is one tap. 21,000 is the one that
    /// went: it is two orders of magnitude past 5,000, so it sat next to
    /// visually identical chips worth a thousandth as much, and anyone sending
    /// that much has a reason and will use "Other" to name it.
    private static let customary: [Int64] = [21, 100, 500, 1000, 5000]

    /// The customary amounts this recipient can actually be sent. An endpoint
    /// with a floor above every preset used to leave every chip unpayable with
    /// no way to reach a working number.
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

    /// Whether the task is over, so the sheet can settle back down.
    ///
    /// Someone who dragged to large to write a comment should not get their
    /// ending as a full-height sheet with a glyph floating in it. Every terminal
    /// state qualifies, not just the handoff.
    private var isFinished: Bool {
        switch phase {
        case .handedOff, .paid, .refused: true
        default: false
        }
    }

    /// Whether the wallet has the request and has not answered.
    private var isPaying: Bool {
        if case .paying = phase { return true }
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
            } else if case .paid(let zap) = phase {
                paid(zap)
            } else if case .refused(let reason) = phase {
                refused(reason)
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
        .presentationDetents(isFinished ? [.medium] : [.medium, .large])
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
                .font(Typography.actionSecondary)
                .foregroundStyle(Palette.text)

            // Leads with the fact Comb owns. It is certain the reader chose to
            // send and that a wallet took the invoice; only settlement is
            // unknowable. The old wording made Comb the subject of a negation
            // ("it cannot tell"), so a 44pt bolt said yes while the paragraph
            // under it said maybe, and the paragraph won.
            Text("Your wallet has the invoice for \(zap.amountMillisats / 1000) sats. Pay it there. The zap appears on the message when \(recipientName)'s wallet publishes a receipt, which is the only way Comb learns a zap was paid.")
                .font(Typography.labelRegular)
                .foregroundStyle(Palette.subtext)
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

    /// A payment that actually happened.
    ///
    /// The one place in this feature entitled to a plain past tense. Every other
    /// ending is careful not to claim settlement, because a `lightning:` handoff
    /// genuinely cannot know; here the wallet returned a preimage, which is proof
    /// and is already on its way to the group as an attestation.
    ///
    /// This is the peak of the interaction and it gets the accent for it, which
    /// is the one screen in the flow where a bolt in chartreuse is the most
    /// important thing on it rather than competing with a button.
    private func paid(_ zap: CommunitySession.PreparedZap) -> some View {
        VStack(spacing: Space.md) {
            Spacer()

            Image(systemName: "bolt.fill")
                .font(.system(size: Sizing.stateGlyph))
                .foregroundStyle(Palette.chartreuse)
                .accessibilityHidden(true)

            Text("Paid \(zap.amountMillisats / 1000) sats to \(recipientName)")
                .font(Typography.actionSecondary)
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.lg)

            // Says what the group will see, without promising when. The
            // attestation is published on a best-effort basis and a relay that
            // refuses it costs the tally and not the payment.
            Text("Your wallet paid the invoice. Comb is telling the channel, so the zap will appear on the message.")
                .font(Typography.labelRegular)
                .foregroundStyle(Palette.subtext)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.lg)

            Spacer()

            PrimaryButton(title: "Done") { dismiss() }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xs)
        }
        .navigationTitle("Zap")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The recipient cannot be paid, so the screen stops being a form.
    ///
    /// Deliberately the same shape as `ZapPresenter`'s own dead end: one glyph,
    /// one sentence, one way out. A live amount grid above an explanation that
    /// no amount will work is a screen arguing with itself, and the grid wins
    /// that argument because it is larger and brighter than the sentence.
    private func refused(_ reason: String) -> some View {
        VStack(spacing: Space.md) {
            Spacer()
            Image(systemName: "bolt.slash")
                .font(.system(size: Sizing.stateGlyph))
                .foregroundStyle(Palette.subtext)
                .accessibilityHidden(true)
            Text(reason)
                .font(Typography.labelRegular)
                .foregroundStyle(Palette.subtext)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Space.lg)
            Spacer()
            PrimaryButton(title: "Close") { dismiss() }
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
                    // Names the recipient, which the nav title cannot: "Zap"
                    // there and "Zap Ray" here said the verb twice and the
                    // person once. This says the person, and the button below
                    // says the verb with the amount attached.
                    Text("To \(recipientName)")
                } footer: {
                    // The amount is on the selected chip and on the button.
                    // Printing it a third time here was the accent's second
                    // wrong use on this screen, and it moved when the chip did,
                    // so it repeated rather than added. What is left is the
                    // range, which is the only thing here the chips cannot say.
                    if let rangeNote {
                        Text(rangeNote)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.subtext)
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
                                .font(Typography.caption)
                                .foregroundStyle(Palette.subtext)
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
                        Text(Self.explanation)
                            .font(Typography.labelRegular)
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
                    // InlineNotice rather than a third hand-rolled copy of it,
                    // and because .meta is 11pt: a failure should not be the
                    // smallest type on the screen it happened on.
                    //
                    // A pre-flight failure is shown in the same place but says
                    // something different, so the two cannot both be on screen:
                    // an attempt supersedes the guess that preceded it.
                    if let notice {
                        InlineNotice(kind: .failure, text: notice)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }

                    PrimaryButton(
                        title: primaryTitle,
                        isBusy: phase == .preparing || isPaying,
                        isDisabled: phase == .preparing || isPaying || !canSend
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
            .font(Typography.actionSecondary)
            .foregroundStyle(isSelected ? Palette.ink : Palette.text)
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

    /// The one failure worth showing, and which one wins.
    ///
    /// An attempt's failure supersedes the pre-flight's: once the reader has
    /// pressed the button, what happened then is the news, and the guess that
    /// preceded it is history.
    private var notice: String? {
        if case .failed(let message) = phase { return message }
        return preflightFailure
    }

    private var primaryTitle: String {
        switch phase {
        // Amount-aware whenever nothing has been attempted, and a failed
        // pre-flight does not change that. This used to read "Try again" the
        // moment the host was unreachable, which was false twice over: the
        // reader had tried nothing, and the button attempts the invoice, a
        // different request from the one that failed.
        case .choosing: amount > 0 ? "Zap \(amount.formatted()) sats" : "Choose an amount"
        case .preparing: "Preparing…"
        case .paying: "Paying…"
        case .paid: "Done"
        case .ready, .handedOff: "Open in wallet"
        case .failed: "Try again"
        case .refused: "Close"
        }
    }

    private func loadLimits() async {
        switch await session.zapLimits(toLightningAddress: lightningAddress) {
        case .limits(let low, let high, let commentLength):
            // An endpoint can advertise a range that admits nothing. Alby
            // returns `maxSendable: 0` for an account that is not currently
            // taking payments, and rendering that faithfully produced "accepts
            // 1 to 0 sats" over a grid with every amount filtered out and a
            // dead button, which reads as Comb being broken rather than as the
            // wallet being shut.
            //
            // Not folded into `unsupported`: they did set up a wallet that
            // speaks Nostr zaps, and saying they did not would be false and
            // would send the reader to ask them about the wrong thing.
            //
            // Refused rather than failed. There is no amount that works, so
            // showing a picker would be offering a choice that cannot be made,
            // and a retry would repeat an answer that is not going to change on
            // this screen.
            guard high >= low, high > 0 else {
                limits = .unknown
                phase = .refused("\(recipientName)'s wallet is not accepting zaps right now.")
                return
            }
            limits = .known(low: low, high: high, commentLength: commentLength)
            reconcileAmount(low: low, high: high)

        case .unsupported:
            // Also terminal, and normally unreachable: `ZapPresenter` answers
            // this before the sheet is built. Kept because a profile can change
            // between the two checks.
            limits = .unknown
            phase = .refused("\(recipientName) has not set up a Lightning wallet that accepts zaps.")

        case .failed(let message):
            // Soft. The host was unreachable or unreadable, so the amounts are
            // guesses again, but the invoice request may still succeed and
            // refusing up front on a failed guess would be worse than the
            // guessing it replaced. The chooser stays live and says why.
            limits = .unknown
            preflightFailure = message
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
        case .paid, .refused:
            dismiss()
        case .ready(let zap), .handedOff(let zap):
            open(zap)
        default:
            await prepare()
        }
    }

    /// Asks the connected wallet to pay, and reports what it said.
    ///
    /// The one screen in this feature that can end on a certainty. Everything
    /// else about zaps is careful not to claim a payment happened, because a
    /// `lightning:` handoff cannot know. Here a preimage came back, so saying
    /// "paid" is a fact rather than a hope.
    private func payInPlace(_ zap: CommunitySession.PreparedZap) async {
        phase = .paying
        switch await session.payZap(zap) {
        case .paid:
            phase = .paid(zap)
        case .refused(let message):
            // The wallet answered and declined, so the reader can act on this
            // and the amount is still theirs to change. Back to the chooser.
            phase = .choosing
            preflightFailure = message
        case .unknown(let message):
            // Not a refusal and not a success. The money may be gone, so the
            // pending marker stands and the copy says exactly this much.
            phase = .failed(message)
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
            // A connected wallet pays here, without leaving the app, and hands
            // back the preimage. Everything else hands the invoice to the OS.
            if await session.hasWallet {
                await payInPlace(zap)
            } else {
                // Straight to the wallet: the extra tap would only be friction.
                open(zap)
            }
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
