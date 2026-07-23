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
    @State private var profile: ProfileSummary?
    @State private var isZapping = false

    var body: some View {
        NavigationStack {
            Group {
                if let profile {
                    content(profile)
                } else {
                    ContentUnavailableView(
                        "Nobody here",
                        systemImage: "person.slash",
                        description: Text("Nothing is known about this account yet.")
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
            if let profile, let address = profile.lightningAddress,
               let recipient = PublicKey(hex: pubkey) {
                ZapSheet(
                    session: session,
                    recipient: recipient,
                    lightningAddress: address,
                    messageID: nil,
                    recipientName: profile.name
                )
            }
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
                            .font(Typography.screenTitle)
                            .foregroundStyle(Palette.text)
                        if let nip05 = profile.nip05, !nip05.isEmpty {
                            Label(nip05, systemImage: "checkmark.seal")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.success)
                        }
                    }
                }
                .padding(.vertical, Space.xs)

                if let about = profile.about, !about.isEmpty {
                    Text(about)
                        .font(Typography.secondary)
                        .foregroundStyle(Palette.text)
                }
            }
            .combRows()

            Section {
                LabeledContent("Messages here", value: "\(profile.messageCount)")

                if profile.canReceiveZaps {
                    Button {
                        isZapping = true
                    } label: {
                        Label("Send a zap", systemImage: "bolt.fill")
                    }
                }
            }
            .combRows()

            // The technical identity, last and quiet: anyone who wants it knows
            // what it is, and nobody else has to meet it.
            Section {
                Text(PublicKey(hex: pubkey)?.npub ?? pubkey)
                    .font(Typography.monoSmall)
                    .foregroundStyle(Palette.subtext)
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

    @State private var members: [ProfileSummary] = []
    @State private var selected: ProfileTarget?

    var body: some View {
        Group {
            if members.isEmpty {
                ContentUnavailableView(
                    "No members listed",
                    systemImage: "person.2.slash",
                    description: Text("This community has not shared who is in \(channelName).")
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

    private func row(_ member: ProfileSummary) -> some View {
        HStack(spacing: Space.sm) {
            AvatarView(name: member.name, picture: member.picture)
            VStack(alignment: .leading, spacing: 1) {
                Text(member.name)
                    .font(Typography.name)
                    .foregroundStyle(Palette.text)
                if member.messageCount > 0 {
                    Text("\(member.messageCount) messages")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.subtext)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
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
