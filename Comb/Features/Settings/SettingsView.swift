import CombCore
import SwiftUI
import UniformTypeIdentifiers

/// The account and community screen, and the one place in the primary UI where
/// the technical vocabulary is allowed to surface, behind a disclosure.
///
/// This screen exists now rather than at polish time because of a custody gap:
/// an identity generated silently at join lives only in this device's
/// Keychain, and until the real backup flow lands, the recovery code view here
/// is the only way off the phone.
struct SettingsView: View {
    let session: CommunitySession
    let onSignOut: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingSignOut = false
    @State private var isReportingProblem = false
    @State private var displayName = ""
    @State private var notifyMentions = NotificationSettings.isEnabled
    @State private var systemDenied = false

    private var host: String { session.relayURL.host ?? "" }
    /// The subdomain reads as the community; the full host is the address.
    private var communityName: String { JoinedCommunity.derivedName(from: host) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Who you are, finally visible somewhere. The name was
                    // asked for once at join and then never shown again, which
                    // read as the app forgetting it.
                    TextField("Your name", text: $displayName)
                        .textContentType(.nickname)
                        .onSubmit { saveName() }

                    NavigationLink {
                        RecoveryCodeView(host: host)
                    } label: {
                        Label("Private key", systemImage: "key.horizontal")
                    }
                } header: {
                    Text("Your account")
                } footer: {
                    // A claim about what Comb does, not about the world. The
                    // previous wording said this was the only copy of the
                    // account, which Comb cannot know: anyone who arrived
                    // through Sign in with your key already has it on the
                    // machine they copied it from.
                    Text("Your name is what people see in channels. Comb keeps this account on this iPhone: it is never copied to iCloud or included in a backup.")
                }
                .combRows()

                Section {
                    LabeledContent {
                        Text("Connected")
                            .foregroundStyle(Palette.success)
                    } label: {
                        Label(communityName, systemImage: "checkmark.seal")
                    }

                    // Not a destructive role: nothing is destroyed. The key
                    // survives in the Keychain and rejoining picks it back up,
                    // so red would claim a danger the copy right below denies.
                    Button {
                        isConfirmingSignOut = true
                    } label: {
                        RowLabel(title: "Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .confirmationDialog(
                        "Sign out of \(communityName)?",
                        isPresented: $isConfirmingSignOut,
                        titleVisibility: .visible
                    ) {
                        Button("Sign out") {
                            dismiss()
                            onSignOut()
                        }
                    } message: {
                        Text("Your account stays saved on this iPhone. You can rejoin this community later as the same person.")
                    }
                } header: {
                    Text("Community")
                } footer: {
                    Text(host).font(Typography.monoSmall)
                }
                .combRows()

                Section {
                    Toggle("Notify me about mentions", isOn: $notifyMentions)
                        .tint(Palette.chartreuse)
                        .onChange(of: notifyMentions) { _, wantsOn in
                            Task {
                                if wantsOn {
                                    let ok = await BackgroundRefresh.enable()
                                    // Spring the switch back if the system
                                    // prompt was declined: an "on" toggle that
                                    // delivers nothing is a lie.
                                    if !ok { notifyMentions = false }
                                    systemDenied = !ok
                                } else {
                                    await BackgroundRefresh.disable()
                                    systemDenied = false
                                }
                            }
                        }
                } header: {
                    Text("Notifications")
                } footer: {
                    if systemDenied {
                        Text("Notifications are off for Comb in iOS Settings. Turn them on there first.")
                            .foregroundStyle(Palette.danger)
                    } else {
                        // The latency is stated, not hidden. Comb has no push
                        // server, so this is a periodic background check, and
                        // promising more than that would be dishonest.
                        Text("Comb has no notification server, so it checks in the background every so often. A mention can arrive a while after it was sent.")
                    }
                }
                .combRows()

                Section {
                    // First, and phrased as the problem rather than the tool.
                    // Someone who has just hit a bug is looking for a way to
                    // say so, not for a diagnostics screen they have to work
                    // out the relevance of.
                    Button {
                        isReportingProblem = true
                    } label: {
                        RowLabel(title: "Report a problem", systemImage: "exclamationmark.bubble")
                    }

                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } footer: {
                    Text("A report attaches the local log so a bug can be traced. Nothing is sent unless you send it.")
                }
                .combRows()

                Section {
                    LabeledContent("Comb", value: appVersion)
                } footer: {
                    Text("An independent, open source client for Buzz relays. Not affiliated with Block, Inc.")
                }
                .combRows()
            }
            .scrollContentBackground(.hidden)
            .background(Palette.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                let profile = try? session.store.profile(pubkey: session.me.hex)
                displayName = profile?.displayName ?? ""
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isReportingProblem) {
                ReportProblemView()
            }
        }
    }

    /// Publishes the new name. Kind 0 is replaceable, so this is idempotent
    /// and safe to call on every submit.
    private func saveName() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await session.setProfile(displayName: trimmed) }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// The identity, in exportable form, shown only on explicit request.
struct RecoveryCodeView: View {
    let host: String

    @State private var isRevealed = false
    @State private var didCopy = false

    private var key: PrivateKey? {
        try? KeychainStore.load(host: host)
    }

    var body: some View {
        Form {
            if let key {
                Section {
                    Group {
                        if isRevealed {
                            Text(key.nsec)
                                .font(Typography.monoSmall)
                                .textSelection(.enabled)
                        } else {
                            Text(String(repeating: "•", count: 24))
                                .font(Typography.monoSmall)
                                .foregroundStyle(Palette.subtext)
                        }
                    }

                    Button(isRevealed ? "Hide" : "Reveal") {
                        withAnimation(Motion.instant) { isRevealed.toggle() }
                    }

                    Button(didCopy ? "Copied" : "Copy") {
                        // Expires from the pasteboard rather than lingering
                        // behind every later paste.
                        UIPasteboard.general.setItems(
                            [[UTType.plainText.identifier: key.nsec]],
                            options: [.expirationDate: Date().addingTimeInterval(60)]
                        )
                        withAnimation(Motion.instant) { didCopy = true }
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            didCopy = false
                        }
                    }
                } header: {
                    Text("Private key (nsec)")
                } footer: {
                    Text("This key is your account: anyone who has it can post as you, and losing it means losing the account if this iPhone is lost. Copies expire from the clipboard after a minute. Store it in a password manager, not a screenshot.")
                }
                .combRows()

                Section {
                    Text(key.publicKey.npub)
                        .font(Typography.monoSmall)
                        .textSelection(.enabled)
                } header: {
                    Text("Public key (npub)")
                } footer: {
                    Text("The public half is safe to share. It is how other clients and communities recognize you.")
                }
                .combRows()
            } else {
                Section {
                    Label("No private key found on this device.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.danger)
                }
                .combRows()
            }
        }
        .combForm()
        .navigationTitle("Private key")
        .navigationBarTitleDisplayMode(.inline)
    }
}
