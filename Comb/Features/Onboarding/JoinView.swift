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
    let onJoined: (CommunitySession) -> Void

    @State private var model = JoinModel()
    @FocusState private var focus: Field?

    private enum Field { case invite, name }

    var body: some View {
        Form {
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
        .navigationTitle(communityName.map { "Join \($0)" } ?? "Join")
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

@MainActor
@Observable
final class JoinModel {
    var inviteText = ""
    var displayName = ""

    private(set) var invite: InviteLink?
    private(set) var isJoining = false
    private(set) var failure: String?

    var parsedHost: String? { invite?.host }
    var canJoin: Bool { invite != nil && !isJoining }

    var joinLabel: String {
        if let host = invite?.host, let community = host.split(separator: ".").first {
            return "Join \(community)"
        }
        return "Join"
    }

    func parseInvite() {
        invite = InviteLink.parse(inviteText)
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
