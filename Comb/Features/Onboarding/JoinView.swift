import CombCore
import CombNet
import SwiftUI

/// The join flow: paste an invite, say what people should call you, tap once.
///
/// Two screens' worth of work behind one button: parse, mint or reuse a key,
/// claim the invite, persist custody, connect, publish the profile. The user
/// sees none of those words.
struct JoinView: View {
    let prefilledInvite: String?
    let onJoined: (CommunitySession) -> Void

    @State private var model = JoinModel()
    @FocusState private var focus: Field?

    private enum Field { case invite, name }

    var body: some View {
        Backdrop {
            ScrollView {
                GlassCard {
                    VStack(alignment: .leading, spacing: Space.md) {
                        FormField(label: "Invite link") {
                            TextField("Paste your invite", text: $model.inviteText, axis: .vertical)
                                .lineLimit(1...3)
                                .font(Typography.mono)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .invite)
                                .onChange(of: model.inviteText) { _, _ in model.parseInvite() }
                        }

                        if let host = model.parsedHost {
                            InlineNotice(kind: .success, text: host)
                                .arrival(true)
                        } else if !model.inviteText.isEmpty {
                            InlineNotice(kind: .info, text: "That does not look like an invite link yet")
                        }

                        FormField(label: "What should people call you?") {
                            TextField("Your name", text: $model.displayName)
                                .font(Typography.body)
                                .textContentType(.nickname)
                                .focused($focus, equals: .name)
                        }

                        FootnoteText(text: "Comb keeps your account on this iPhone.")

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

                        if let failure = model.failure {
                            InlineNotice(kind: .failure, text: failure)
                        }
                    }
                }
                .padding(Space.lg)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Join")
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
                failure = "The relay did not accept the invite."
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
            failure = "That invite did not work. Check it was copied completely."
        } catch InviteClient.Failure.rateLimited {
            failure = "Too many tries. Give it a minute."
        } catch {
            failure = "Could not reach the community. Check the connection and try again."
        }
        return nil
    }
}
