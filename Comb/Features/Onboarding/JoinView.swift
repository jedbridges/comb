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
    @FocusState private var focus: Field?

    private enum Field { case invite, name }

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
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                // Field and paste share one row. As its own row the button sat
                // alone in a full-width card, which read as an empty container
                // with something dropped into it.
                HStack(spacing: Space.sm) {
                    TextField("Paste your invite", text: $model.inviteText, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .invite)
                        .onChange(of: model.inviteText) { _, _ in model.parseInvite() }

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
                if let host = model.parsedHost {
                    Label(host, systemImage: "checkmark.seal")
                        .foregroundStyle(Palette.success)
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
            } footer: {
                // The consequence of skipping it, stated: without a name the
                // channel shows a code where a person should be.
                Text("Without a name, people see a code instead of you. Comb keeps your account on this iPhone.")
            }
            .combRows()

            if let failure = model.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.danger)
                }
                .combRows()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.backgroundGradient.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(
                title: model.isJoining ? "Joining…" : model.joinLabel,
                isDisabled: !model.canJoin
            ) {
                focus = nil
                Task {
                    if let session = await model.join() {
                        onJoined(session)
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.xs)
        }
        .navigationTitle(displayCommunityName.isEmpty ? "Join" : "Join \(displayCommunityName)")
        .navigationBarTitleDisplayMode(.inline)
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

    var body: some View {
        HStack(spacing: Space.md) {
            iconView
                .frame(width: Sizing.avatar * 1.6, height: Sizing.avatar * 1.6)
                .clipShape(.rect(cornerRadius: Radii.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Radii.card)
                        .strokeBorder(Palette.glyphHairline, lineWidth: 0.75)
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
                        .font(Typography.caption)
                        .foregroundStyle(Palette.subtext)
                } else if isVerified {
                    // The only claim the relay actually backs: it is real and
                    // reachable. Not "this community is X", which it will not say.
                    Label("Verified community", systemImage: "checkmark.seal.fill")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.success)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.liftOnGradient, in: .rect(cornerRadius: Radii.card))
        .overlay(
            RoundedRectangle(cornerRadius: Radii.card)
                .strokeBorder(Palette.hairlineOnGradient, lineWidth: 0.5)
        )
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.xs)
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
                .font(.system(size: Sizing.avatar * 0.6))
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
    /// Whether the host answered as a real relay. A verified badge is only
    /// honest once this is true.
    private(set) var isVerified = false

    private var verifyTask: Task<Void, Never>?

    var parsedHost: String? { invite?.host }
    var canJoin: Bool { invite != nil && !isJoining }

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

        guard let invite else {
            isVerifying = false
            return
        }
        verify(invite)
    }

    /// Reaches the host for its NIP-11 document: proof it is a real relay, and
    /// its icon. Best-effort and non-blocking; a host that never answers simply
    /// leaves the card unverified, and the join button still works, because the
    /// claim step is where a bad invite is actually caught.
    private func verify(_ invite: InviteLink) {
        isVerifying = true
        verifyTask = Task {
            let info = try? await RelayInfoClient().fetch(from: invite.relayURL)
            guard !Task.isCancelled else { return }
            isVerifying = false
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

            let claim = try await InviteClient().claim(invite, signer: signer)
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
        } catch InviteClient.Failure.rateLimited {
            failure = "Too many tries. Give it a minute."
        } catch {
            failure = "Could not reach the community. Check the connection and try again."
        }
        return nil
    }
}
