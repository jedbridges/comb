import CombCore
import CombStore
import SwiftUI

/// Who someone is, from a tap on their name or avatar.
///
/// Before this, names had no faces: you had to remember who "M" was from an
/// initial. Everything here comes from the local store, so it opens instantly
/// and works offline.
struct ProfileSheet: View {
    let session: CommunitySession
    let pubkey: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openChannel) private var openChannel
    @State private var profile: ProfileSummary?
    @State private var isZapping = false
    @State private var isOpeningDirectMessage = false
    @State private var directMessageFailure: String?

    /// Opens the conversation and goes to it.
    ///
    /// The first version created it and dismissed, on the reasoning that the
    /// conversation reaches the channel list on its own. Tested against a real
    /// community that was plainly wrong: the sheet closed, the new row landed
    /// eight places down a list nobody was looking at, and the button read as
    /// broken. A control called "Send a message" has to end somewhere you can
    /// send a message.
    private func openDirectMessage() async {
        isOpeningDirectMessage = true
        directMessageFailure = nil
        defer { isOpeningDirectMessage = false }

        do {
            let channelID = try await session.openDirectMessage(with: [pubkey])
            dismiss()
            openChannel?(channelID)
        } catch CommunitySession.DirectMessageFailure.noChannelReturned {
            directMessageFailure = "The conversation may have been created, but this community did not say where. Check your conversations."
        } catch {
            directMessageFailure = "This community does not support starting conversations from Comb."
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let profile {
                    content(profile)
                } else {
                    ContentUnavailableView(
                        "No profile yet",
                        systemImage: "person.slash",
                        description: Text("This person has not added a name or picture.")
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            profile = try? session.store.profile(pubkey: pubkey)
        }
        .sheet(isPresented: $isZapping) {
            ZapPresenter(
                session: session,
                pubkey: pubkey,
                lightningAddress: profile?.lightningAddress,
                capability: profile?.zapCapability ?? .unknown,
                messageID: nil,
                displayName: profile?.name ?? String(pubkey.prefix(8))
            )
        }
    }

    private func content(_ profile: ProfileSummary) -> some View {
        Form {
            Section {
                HStack(spacing: Space.md) {
                    AvatarView(name: profile.name, picture: profile.picture)
                        .scaleEffect(1.6)
                        .frame(width: Sizing.avatar * 1.6, height: Sizing.avatar * 1.6)

                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(profile.name)
                            .textRole(.title)
                            .lineLimit(2)
                        if let nip05 = profile.nip05, !nip05.isEmpty {
                            Label(nip05, systemImage: "checkmark.seal")
                                .textRole(.meta, .success)
                        }
                    }
                }
                .padding(.vertical, Space.xs)

                if let about = profile.about, !about.isEmpty {
                    Text(about)
                        .textRole(.support, .primary)
                }
            }
            .combRows()

            Section {
                LabeledContent("Messages in this community", value: "\(profile.messageCount)")

                // Not for yourself: a conversation with one participant is
                // something the relay would refuse anyway, and offering it
                // reads as a feature rather than as the mistake it is.
                if pubkey != session.me.hex {
                    Button {
                        Task { await openDirectMessage() }
                    } label: {
                        if isOpeningDirectMessage {
                            Label {
                                Text("Opening…")
                            } icon: {
                                ProgressView().controlSize(.small)
                            }
                        } else {
                            Label("Send a message", systemImage: "bubble.left")
                        }
                    }
                    .disabled(isOpeningDirectMessage)
                }

                // Offered when the answer is yes, and when Comb has never seen
                // their profile and so has no answer. Hidden only when they
                // published one and it carries no Lightning address.
                if profile.zapCapability != .no {
                    Button {
                        isZapping = true
                    } label: {
                        Label("Send a zap", systemImage: "bolt.fill")
                    }
                }
            } footer: {
                if let directMessageFailure {
                    // Stated rather than swallowed. Opening a conversation is a
                    // Buzz command with no NIP-29 equivalent, so a plain relay
                    // refuses it outright, and a button that quietly did
                    // nothing would be the worst version of that.
                    Label(directMessageFailure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.danger)
                }
            }
            .combRows()

            // The technical identity, last and quiet: anyone who wants it knows
            // what it is, and nobody else has to meet it.
            Section {
                Text(PublicKey(hex: pubkey)?.npub ?? pubkey)
                    .textRole(.monoSupport)
                    .textSelection(.enabled)
            } header: {
                Text("Public identity")
            }
            .combRows()
        }
        .combForm()
    }
}

/// Everyone in a channel, most talkative first.
struct MemberListView: View {
    let session: CommunitySession
    let channelID: String
    let channelName: String

    @State private var members: [ChannelMember] = []
    @State private var selected: ProfileTarget?

    var body: some View {
        Group {
            if members.isEmpty {
                ContentUnavailableView(
                    "No members yet",
                    systemImage: "person.2.slash",
                    description: Text("Nobody has been listed in \(channelName) yet.")
                )
            } else {
                Form {
                    Section {
                        ForEach(members) { member in
                            Button {
                                selected = ProfileTarget(pubkey: member.pubkey)
                            } label: {
                                row(member)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("\(members.count) members")
                    }
                    .combRows()
                }
                .combForm()
            }
        }
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            members = (try? session.store.members(of: channelID)) ?? []
        }
        .sheet(item: $selected) { target in
            ProfileSheet(session: session, pubkey: target.pubkey)
        }
    }

    private func row(_ member: ChannelMember) -> some View {
        HStack(spacing: Space.sm) {
            AvatarView(name: member.name, picture: member.picture, pubkey: member.pubkey)
            VStack(alignment: .leading, spacing: Space.hairline) {
                HStack(spacing: Space.xs) {
                    Text(member.name)
                        .textRole(.bodyStrong)
                        .lineLimit(1)
                    // Owners and admins only. Nothing is drawn for an ordinary
                    // member, and nothing at all when the relay publishes no
                    // roles: a badge reading "Member" on a relay that never said
                    // so would be Comb inventing the fact.
                    // Owner takes the accent, Admin does not. This is the one
                    // unbounded chartreuse in the app: a roster's owner count
                    // is one in practice, but its admin count grows with the
                    // community, and four accent chips on one screen is three
                    // more than the budget allows. The words carry the meaning
                    // either way.
                    if let role = member.role, role.isElevated {
                        Text(role == .owner ? "Owner" : "Admin")
                            .textRole(.meta, role == .owner ? .brand : .muted)
                            .combChip()
                    }
                }
                if member.messageCount > 0 {
                    Text("\(member.messageCount) messages")
                        .textRole(.meta)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            member.role.map { $0.isElevated ? "\(member.name), \($0.rawValue)" : member.name }
                ?? member.name
        )
    }
}

/// An identity to show a profile for.
///
/// A wrapper rather than a retroactive `String: Identifiable` conformance:
/// conforming a stdlib type app-wide risks colliding with a conformance in any
/// linked module, and a duplicate protocol conformance aborts at load.
struct ProfileTarget: Identifiable, Equatable {
    let pubkey: String
    var id: String { pubkey }
}
