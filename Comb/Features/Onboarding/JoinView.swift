import CombCore
import CombNet
import SwiftUI

/// The join flow: paste an invite, say what people should call you, tap once.
///
/// Built from a system Form so the inputs are iOS's own, not hand-drawn
/// imitations. The brand shows up in the backdrop and the one chartreuse
/// button; the rows belong to the OS, which is what keeps them feeling native
/// today and inheriting whatever iOS looks like next year.
struct JoinView: View {
    let prefilledInvite: String?
    /// The community this join was opened for, when it came from browse.
    /// Without it, tapping "designers" landed on a screen that never said
    /// designers, and the tap felt like it had not worked.
    var communityName: String? = nil
    /// The community's description, available only when the join came from
    /// browse. A pasted invite has no description to show, because a Buzz
    /// relay will not supply one, and that is an honest blank rather than a
    /// generic string standing in for every community.
    var communityDescription: String? = nil
    let onJoined: (CommunitySession) -> Void

    @State private var model = JoinModel()
    @State private var reading: PolicyDocument?
    /// Bumped once, when a community is actually joined. The first thing this
    /// app is for, and the only time most people will ever see this screen.
    @State private var joined = 0
    @FocusState private var focus: Field?

    private enum Field { case invite, name }

    /// A policy document being read. Identifiable by title, which is unique
    /// within a policy and stable across the sheet's lifetime.
    struct PolicyDocument: Identifiable {
        let title: String
        let markdown: String
        var id: String { title }

        /// Links in the footer copy carry the document instead of a real
        /// address: the text lives in the response Comb already holds, and a
        /// tap should open it here rather than send anyone to a browser.
        static let scheme = "comb-policy"
        static let terms = "terms"
        static let privacy = "privacy"
    }

    /// The grey line under the agreements: whose terms these are.
    ///
    /// The one sentence worth keeping. Comb did not write these and cannot
    /// change them, and a screen that asks you to agree to something owes you
    /// the name of who is asking.
    ///
    /// That name is the service, not the community. `designers` did not write
    /// these terms; it inherited them from the host it runs on, and on the
    /// hosted service that is Buzz. A community running its own relay gets the
    /// general form, because there the operator is someone this app cannot name.
    private static func policyFooter(host: String?) -> String {
        let isHostedByBuzz = host == Self.buzzDomain || host?.hasSuffix(".\(Self.buzzDomain)") == true
        return "Required by \(isHostedByBuzz ? "Buzz" : "this community's host"), not by Comb."
    }

    /// Matched as a whole label, never as a bare suffix: `notbuzz.xyz` ends with
    /// the same eight characters and is not Buzz.
    private static let buzzDomain = "buzz.xyz"

    /// The agreement itself, with each document named as a link.
    ///
    /// The names were already in this sentence; making them the links removes a
    /// second sentence that existed only to say them again.
    private static func agreementLabel(_ policy: JoinPolicy) -> AttributedString {
        var documents: [String] = []
        if policy.termsMarkdown?.isEmpty == false {
            documents.append(
                "[Terms of Service](\(PolicyDocument.scheme)://\(PolicyDocument.terms))"
            )
        }
        if policy.privacyMarkdown?.isEmpty == false {
            documents.append(
                "[Privacy Policy](\(PolicyDocument.scheme)://\(PolicyDocument.privacy))"
            )
        }

        let sentence = "I agree to the \(documents.joined(separator: " and "))"
        return (try? AttributedString(markdown: sentence)) ?? AttributedString(sentence)
    }

    /// The name to show: the index's real name when the join came from browse,
    /// otherwise the one derived from the host.
    private var displayCommunityName: String {
        communityName ?? model.derivedName
    }

    /// Show the card when there is a community to show: either an invite has
    /// parsed, or the join came from browse and carries a name. An invite-only
    /// entry is exactly where it helps most, since the screen is otherwise just
    /// a field asking for a link with no reminder of what it is for.
    private var showsCard: Bool {
        model.invite != nil || communityName != nil
    }

    var body: some View {
        Form {
            if showsCard {
                Section {
                    CommunityCard(
                        name: displayCommunityName,
                        summary: communityDescription,
                        icon: model.icon,
                        isVerifying: model.isVerifying,
                        isVerified: model.isVerified
                    )
                }
                .combRows()
            }

            Section {
                // Field and paste share one row. As its own row the button sat
                // alone in a full-width card, which read as an empty container
                // with something dropped into it.
                HStack(spacing: Space.sm) {
                    // Once it parses, the token stops being a field and becomes
                    // one settled line. Left as three lines of a scrolled text
                    // view, a perfectly good invite showed its own tail
                    // (`…UF-BIn0.9bU4Gscg…`), which reads as a link that arrived
                    // broken. Two people reported exactly that about links that
                    // were fine. Elided from the middle, the same way the
                    // timeline shortens a long URL, it reads as deliberate.
                    if model.invite != nil {
                        Text(model.inviteText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(Palette.subtext)
                            .accessibilityLabel("Invite link, entered")

                        Spacer(minLength: 0)

                        Button("Change") {
                            model.inviteText = ""
                            model.parseInvite()
                            focus = .invite
                        }
                        .font(Typography.actionSecondary)
                        .buttonStyle(.plain)
                        // Not chartreuse: once an invite is in, the accent
                        // belongs to Join, and wearing it here put the same
                        // emphasis on undoing the paste as on completing it.
                        // Not subtext either, which is the colour of the
                        // elided invite sitting next to it: matching that made
                        // the only control in the row read as another label.
                        .foregroundStyle(Palette.text)
                    } else {
                        TextField("Paste your invite", text: $model.inviteText, axis: .vertical)
                            .lineLimit(1...3)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .invite)
                            .onChange(of: model.inviteText) { _, _ in model.parseInvite() }
                    }

                    if model.inviteText.isEmpty {
                        // Native paste, no permission prompt: the most likely
                        // reason anyone is here is a link already sitting on
                        // the clipboard.
                        PasteButton(payloadType: String.self) { strings in
                            Task { @MainActor in
                                model.inviteText = strings.first ?? ""
                                model.parseInvite()
                            }
                        }
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(Palette.chartreuse)
                        .labelStyle(.iconOnly)
                    }
                }
            } header: {
                Text("Invite link")
            } footer: {
                // Said here, under the field, rather than after the join
                // attempt: an expired link is the one problem the reader can do
                // nothing about, and making them fill the rest of the form
                // first only delays the same answer.
                if let expiredOn = model.expiredOn {
                    InlineNotice(
                        kind: .failure,
                        text: "This invite expired on \(expiredOn.formatted(date: .abbreviated, time: .omitted)). Ask for a fresh one."
                    )
                } else if let host = model.parsedHost {
                    // Sealed only once the host has actually answered. The
                    // same glyph on the card above means "this is a real
                    // relay, and it is reachable"; showing it the instant a
                    // string parses vouched for hosts nobody had contacted,
                    // and could sit on screen while the card still said
                    // "Checking…". Until then this is a plain statement of
                    // where the invite points.
                    InlineNotice(kind: model.isVerified ? .success : .info, text: host)
                } else if !model.inviteText.isEmpty {
                    Text("Paste the whole link, including the https:// part.")
                } else if let communityName {
                    Text("\(communityName) is invite only. Paste the invite a member sent you.")
                }
            }
            .combRows()

            Section {
                TextField("Your name", text: $model.displayName)
                    .textContentType(.nickname)
                    .focused($focus, equals: .name)
            } header: {
                Text("What should people call you?")
            }
            .combRows()

            // Only when it has something to ask. A policy with nothing to show
            // is still accepted on your behalf at join time, silently, because
            // there is no question to put to you.
            if let policy = model.policy, !policy.isEmpty {
                Section {
                    // One row holding both, rather than a row each. Two
                    // agreements are a single act of consent, and two full-size
                    // rows gave them the weight of a settings screen.
                    // No spacing of its own: each row now carries a full hit
                    // target, and that height is the separation.
                    VStack(alignment: .leading, spacing: 0) {
                        if policy.hasDocuments {
                            Toggle(isOn: $model.acceptsTerms) {
                                Text(Self.agreementLabel(policy))
                            }
                        }
                        // Asked as its own question because the relay records
                        // it as its own answer, and because bundling an age
                        // assertion into a terms checkbox is how you get one
                        // that is not true.
                        if policy.ageAttestationRequired {
                            // No trailing full stop, to match the row above it.
                            // These are labels, not sentences.
                            Toggle("I am 18 years of age or older", isOn: $model.confirmsAge)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, Space.xxs)
                } footer: {
                    // The documents sit in the footer copy as links rather than
                    // as two full-width rows. Whose terms they are is the part
                    // worth saying out loud; opening them is a detour most
                    // people will not take, and rows that size promised more
                    // than a link does.
                    Text(Self.policyFooter(host: model.parsedHost))
                }
                // Its own, larger spacing. Every other group is introduced by a
                // header, which carries its own space above it; this one has
                // none, so at the shared value it sat closer to the name field
                // than the name field sat to the invite, and read as part of
                // the question above it rather than as a new one.
                .listSectionSpacing(.custom(Space.xxxl))
                .combRows()
            }

            if let failure = model.failure {
                Section {
                    InlineNotice(kind: .failure, text: failure)
                }
                .combRows()
            }
        }
        // One rhythm for the whole screen. A Form's default section spacing is
        // tuned for sections that all carry headers and footers; here some do
        // and some do not, so the default left the gap above the agreements
        // nearly twice the gap above the name field. Setting it once makes the
        // spacing a property of the screen rather than of which section
        // happened to have a footer.
        .listSectionSpacing(.custom(Space.lg))
        // The card is the screen's answer to "which community is this?" and
        // wants to sit near the title that asks it, not float in the middle of
        // an empty field.
        .contentMargins(.top, Space.xxs, for: .scrollContent)
        .combForm()
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            // Fine print and the action are two different things, so they take
            // the between-groups step rather than the within-group one. Tighter
            // than this the caption sat close enough to the chartreuse fill to
            // read as a label on the control instead of a statement about what
            // the control will do.
            VStack(spacing: Space.md) {
                // Fine print, and deliberately shaped like it. Joining mints an
                // account that exists nowhere else, and a reader who learns
                // that afterwards has already been given something they did not
                // know they were taking on. So it is said before the tap, and
                // only when one is actually about to be made: a rejoin reuses
                // the account already here.
                //
                // Pinned to the button rather than placed in the form, where it
                // was tried both as a footer and as its own titled section. In
                // the scroll content it either drifted between two headers with
                // nothing to belong to, or, once given a header and a card, it
                // took on the weight of a step to complete. Neither is what a
                // disclosure is. Here it cannot be scrolled away from and it
                // reads as the small print above the button it qualifies, which
                // is the thing it actually modifies.
                //
                // Subtext and caption, no glyph, no fill. The ethos asks for
                // the limitation to be stated, not for it to be alarming: a
                // warning badge on a screen whose whole purpose is to say yes
                // argues with the reader instead of informing them.
                //
                // The loss is stated without being called certain. The key can
                // be exported and pasted into any Nostr client, so a flat "you
                // lose the account" would overstate a limitation the app ships
                // a remedy for, which is its own kind of dishonesty.
                if model.createsNewAccount {
                    Text("Joining creates an account that lives only on this iPhone. Save a copy from Settings, or losing the iPhone loses the account.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.subtext)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                PrimaryButton(
                    title: model.isJoining ? "Joining…" : model.joinLabel,
                    isBusy: model.isJoining,
                    isDisabled: !model.canJoin
                ) {
                    focus = nil
                    Task {
                        if let session = await model.join() {
                            joined += 1
                            onJoined(session)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.xs)
            // Its own, because the Form's animation for the same value no
            // longer reaches this: the disclosure sits in the inset now, which
            // is a sibling of the Form rather than a row inside it.
            .animation(Motion.standard, value: model.createsNewAccount)
        }
        .sensoryFeedback(Haptics.milestone, trigger: joined)
        // Paired with the message on screen, never alone. An invite that did
        // not work is the most common way this screen ends badly, and it is
        // worth feeling as well as reading.
        .sensoryFeedback(Haptics.failure, trigger: model.failure) { _, failure in
            failure != nil
        }
        .navigationTitle(displayCommunityName.isEmpty ? "Join" : "Join \(displayCommunityName)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $reading) { document in
            PolicyDocumentView(title: document.title, markdown: document.markdown)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == PolicyDocument.scheme, let policy = model.policy else {
                return .systemAction
            }
            switch url.host() {
            case PolicyDocument.terms:
                guard let markdown = policy.termsMarkdown else { return .discarded }
                reading = PolicyDocument(title: "Terms of Service", markdown: markdown)
            case PolicyDocument.privacy:
                guard let markdown = policy.privacyMarkdown else { return .discarded }
                reading = PolicyDocument(title: "Privacy Policy", markdown: markdown)
            default:
                return .discarded
            }
            return .handled
        })
        .onAppear {
            if let text = prefilledInvite, model.inviteText.isEmpty {
                model.inviteText = text
                model.parseInvite()
            }
            // Reading the pasteboard unprompted triggers the system banner;
            // focusing the field invites the paste instead.
            focus = model.inviteText.isEmpty ? .invite : .name
        }
    }
}

/// The community you are about to join, shown the moment an invite parses.
///
/// The point is to turn "designers.communities.buzz.xyz ✓" from a footer note
/// into a place with a face. What it can honestly show is deliberately narrow:
/// the icon (the one per-community NIP-11 field), the name from the host or the
/// index, and a description only when browse supplied one. It never invents the
/// generic name a Buzz relay would hand back for every community alike.
private struct CommunityCard: View {
    let name: String
    let summary: String?
    let icon: URL?
    let isVerifying: Bool
    let isVerified: Bool

    /// Scaled, so the badge grows with the name beside it. Sized from a token
    /// and grown by Dynamic Type, the same way `AvatarView` does it: a fixed
    /// square next to text at the largest accessibility sizes reads as a
    /// rendering fault rather than as a mark.
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = Sizing.avatar * 1.6

    var body: some View {
        HStack(spacing: Space.md) {
            iconView
                .frame(width: iconSize, height: iconSize)
                .clipShape(.rect(cornerRadius: Radii.card))
                // Decorative. The community's name sits beside it and says the
                // same thing, so announcing an unlabelled image here would
                // only make VoiceOver read the card twice.
                .accessibilityHidden(true)
                .overlay(
                    RoundedRectangle(cornerRadius: Radii.card)
                        .strokeBorder(Palette.glyphHairline, lineWidth: Stroke.hairline)
                )

            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(name)
                    .font(Typography.screenTitle)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)

                if let summary {
                    Text(summary)
                        .font(Typography.secondary)
                        .foregroundStyle(Palette.subtext)
                        .lineLimit(2)
                } else if isVerifying {
                    Label("Checking…", systemImage: "ellipsis")
                        .labelStyle(.compact)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.subtext)
                } else if isVerified {
                    // The only claim the relay actually backs: it is real and
                    // reachable. Not "this community is X", which it will not say.
                    Label("Verified community", systemImage: "checkmark.seal.fill")
                        .labelStyle(.compact)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.success)
                }
            }

            Spacer(minLength: 0)
        }
        // No fill or stroke of its own. It used to draw them itself, inside the
        // row's content insets, which left it a stripe narrower on each side
        // than every field below it. The surface now comes from `combRows`,
        // the same one the rest of the form uses, so the two cannot drift.
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.standard, value: icon)
        .animation(Motion.standard, value: isVerified)
    }

    @ViewBuilder private var iconView: some View {
        if let icon {
            // A plain public URL, no Blossom auth: onboarding has no session to
            // sign with, and a community icon is not gated. AsyncImage is right
            // here even though the timeline uses the loader.
            AsyncImage(url: icon, transaction: Transaction(animation: Motion.fast)) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: placeholder
                }
            }
        } else {
            placeholder
        }
    }

    /// The comb-cell mark, so a community with no icon still reads as one of
    /// this app's objects rather than a grey hole.
    private var placeholder: some View {
        ZStack {
            Palette.glyphLift
            Image(systemName: "person.3.fill")
                // Kept as a fraction of the badge it sits in, so the mark and
                // its container grow together.
                .font(.system(size: iconSize * 0.375))
                .foregroundStyle(Palette.glyphMark)
        }
    }
}

@MainActor
@Observable
final class JoinModel {
    var inviteText = ""
    var displayName = ""

    private(set) var invite: InviteLink?
    private(set) var isJoining = false
    private(set) var failure: String?

    /// The community's icon, the one NIP-11 field that varies per community on
    /// a Buzz relay. `name` and `description` are byte-identical across the
    /// whole service to prevent enumeration, so they are deliberately not read
    /// here: showing them would label every community the same generic thing.
    private(set) var icon: URL?
    /// True while the host is being reached for the first time after a paste,
    /// so the card can show it is confirming rather than looking empty.
    private(set) var isVerifying = false
    /// Whether joining will mint a new account rather than reuse the one this
    /// device already holds for the host. Creating a key that only exists here
    /// is the single most consequential thing this screen does, and it used to
    /// happen without saying so.
    private(set) var createsNewAccount = false
    /// Whether the host answered as a real relay. A verified badge is only
    /// honest once this is true.
    private(set) var isVerified = false

    private var verifyTask: Task<Void, Never>?

    var parsedHost: String? { invite?.host }

    /// The operator's terms, when this relay requires any. Nil is the common
    /// case and the one that must stay frictionless.
    private(set) var policy: JoinPolicy?
    var acceptsTerms = false
    var confirmsAge = false

    /// Whether the policy step, if there is one, has been answered.
    var policySatisfied: Bool {
        guard let policy, !policy.isEmpty else { return true }
        let documentsAccepted = policy.hasDocuments ? acceptsTerms : true
        let ageAnswered = policy.ageAttestationRequired ? confirmsAge : true
        return documentsAccepted && ageAnswered
    }

    /// What the code says about its own expiry, when it says anything. Only
    /// ever used to stop a join early; the relay decides for real.
    var expiredOn: Date? {
        guard let invite, invite.hasExpired() else { return nil }
        return invite.expiresAt
    }

    var canJoin: Bool {
        invite != nil && !isJoining && policySatisfied && expiredOn == nil
    }

    /// The community's name. The host's subdomain is the only per-community
    /// name Comb can trust: a Buzz relay's NIP-11 `name` is the same string for
    /// everyone. A browse-originated join passes the index's real name in over
    /// the top of this.
    var derivedName: String {
        invite.map { JoinedCommunity.derivedName(from: $0.host) } ?? ""
    }

    var joinLabel: String {
        derivedName.isEmpty ? "Join" : "Join \(derivedName)"
    }

    func parseInvite() {
        let previousHost = invite?.host
        invite = InviteLink.parse(inviteText)

        // Only re-verify when the host actually changed, so every keystroke in
        // a pasted token does not fire a fetch.
        guard invite?.host != previousHost else { return }
        icon = nil
        isVerified = false
        verifyTask?.cancel()

        // A different community means different terms, and an answer given to
        // one operator must never be carried to another.
        policy = nil
        acceptsTerms = false
        confirmsAge = false

        guard let invite else {
            isVerifying = false
            createsNewAccount = false
            return
        }
        createsNewAccount = !KeychainStore.exists(host: invite.host)
        verify(invite)
    }

    /// Reaches the host for its NIP-11 document: proof it is a real relay, and
    /// its icon. Best-effort and non-blocking; a host that never answers simply
    /// leaves the card unverified, and the join button still works, because the
    /// claim step is where a bad invite is actually caught.
    private func verify(_ invite: InviteLink) {
        isVerifying = true
        verifyTask = Task {
            // Both are unauthenticated reads of the same host, so they go out
            // together rather than making the join step wait on the second.
            async let document = RelayInfoClient().fetch(from: invite.relayURL)
            async let declared = JoinPolicyClient().policy(for: invite)

            let info = try? await document
            let policy = try? await declared
            guard !Task.isCancelled else { return }
            isVerifying = false

            // Kept whether or not it has anything to show. The relay demands a
            // receipt for *any* configured policy, so a policy with no
            // documents and no age question still has to be accepted; it just
            // has nothing to put on screen. Storing only the ones with content
            // meant those relays refused every claim and the recovery path had
            // nothing to offer.
            self.policy = policy

            guard let info else { return }
            isVerified = true
            if let icon = info.icon, let url = URL(string: icon),
               url.scheme?.lowercased() == "https" {
                self.icon = url
            }
        }
    }

    /// The whole handshake. Order matters: the claim must precede the socket,
    /// because membership is what NIP-42 authentication is checked against.
    func join() async -> CommunitySession? {
        guard let invite else { return nil }
        isJoining = true
        failure = nil
        defer { isJoining = false }

        do {
            // Reuse this device's identity for the host when one exists. This
            // makes leave-and-rejoin keep the same identity, and makes retrying
            // a claim after a dropped response idempotent instead of minting a
            // stranger per attempt.
            let key = try (KeychainStore.load(host: invite.host)) ?? PrivateKey()
            let signer = InMemorySigner(key)

            // Acceptance is exchanged for a receipt bound to this code and the
            // revision that was on screen, so a policy edited mid-join fails
            // here rather than being silently agreed to.
            var receipt: String?
            if let policy {
                receipt = try await JoinPolicyClient().acceptPolicy(
                    for: invite,
                    version: policy.version,
                    ageConfirmed: confirmsAge
                )
            }

            let claim = try await InviteClient().claim(
                invite,
                signer: signer,
                policyReceipt: receipt
            )
            guard claim.isMember else {
                failure = "That community did not accept the invite. Ask for a fresh one."
                return nil
            }

            // Custody before connection: a crash between here and the first
            // paint must not orphan a claimed membership.
            try KeychainStore.save(key, host: invite.host)
            CommunityRegistry.add(JoinedCommunity(
                host: invite.host,
                relay: invite.relayURL,
                name: nil,
                joinedAt: Date()
            ))

            let session = try CommunitySession(url: invite.relayURL, key: key)
            try await session.start()

            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                await session.setProfile(displayName: name)
            }

            return session
        } catch InviteClient.Failure.expired {
            failure = "That invite has expired. Ask for a fresh one."
        } catch InviteClient.Failure.invalid {
            failure = "That invite did not work. Check the whole link was copied."
        } catch InviteClient.Failure.policyRequired {
            // The policy fetch is best-effort, so it can miss: a host that was
            // slow to answer, or terms added between opening this screen and
            // tapping join. Fetch again and show the step rather than blaming
            // the invite, which is what this used to do.
            await loadPolicyAfterRefusal(invite)
        } catch JoinPolicyClient.Failure.notAccepted {
            await loadPolicyAfterRefusal(invite)
        } catch InviteClient.Failure.rateLimited {
            failure = "Too many tries. Give it a minute."
        } catch {
            failure = "Could not reach the community. Check the connection and try again."
        }
        return nil
    }

    /// The relay refused for want of an accepted policy. Load it and put the
    /// step on screen; the answer, if one was already given, is cleared because
    /// the revision it applied to is exactly what is in doubt.
    private func loadPolicyAfterRefusal(_ invite: InviteLink) async {
        acceptsTerms = false
        confirmsAge = false
        policy = try? await JoinPolicyClient().policy(for: invite)

        failure = if policy == nil {
            // Required by the community but unreadable by us: honest about
            // which side is stuck, rather than sending the reader back to
            // their clipboard.
            "This community requires accepting its terms, and Comb could not load them. Try again in a moment."
        } else if policy?.isEmpty == false {
            "Please accept the terms above, then join."
        } else {
            // Nothing to accept and the claim still failed. Saying "accept the
            // terms" would point at a step that is not on screen.
            "That did not go through. Try again in a moment."
        }
    }
}
