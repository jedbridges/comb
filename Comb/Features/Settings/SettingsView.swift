import CombCore
import SwiftUI
import UniformTypeIdentifiers

/// Whether a copy of an account has ever left this device, per community.
///
/// Not a security control and not a promise: it records that the key was put
/// on the clipboard, which is the last moment Comb can see. Whether it reached
/// a password manager is the reader's business and unknowable from here, so
/// nothing in the UI claims more than "you have copied this".
enum AccountBackup {
    private static func key(host: String) -> String { "accountCopied.\(host)" }

    static func hasCopied(host: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(host: host))
    }

    static func recordCopy(host: String) {
        UserDefaults.standard.set(true, forKey: key(host: host))
    }
}

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
    @State private var syncsReadState = SyncSettings.syncsReadState
    @State private var loadsRemoteImages = SyncSettings.loadsRemoteImages
    @State private var systemDenied = false
    /// Set when a name change could not be published, so the footer can say so
    /// instead of the field quietly looking saved.
    @State private var nameUndelivered = false
    /// Whether a copy of this account has ever been taken off the device.
    /// Seeded on appear and flipped the moment it happens, so the prompt below
    /// the name field disappears without needing the screen reopened.
    @State private var hasCopiedAccount = true

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
                        // Clears as soon as they start fixing it: a warning
                        // about the previous attempt, still on screen while
                        // they type the next one, reads as a verdict on what
                        // they are typing now.
                        .onChange(of: displayName) { _, _ in nameUndelivered = false }

                    NavigationLink {
                        RecoveryCodeView(host: host, onCopied: { hasCopiedAccount = true })
                    } label: {
                        // Named for the job, not for the object. Someone who
                        // was told at join that the account lives only on this
                        // iPhone comes looking for a way to keep it, and
                        // "Private key" is the wrong end of that sentence for
                        // a reader who never asked to learn the word. The
                        // vocabulary is still there, inside, where whoever
                        // wants it will find it.
                        //
                        // Two words, like "Blocked" and "Diagnostics". The
                        // section header already says whose account it is, so
                        // repeating it here only made this row the odd long one.
                        Label("Save a copy", systemImage: "key.horizontal")
                    }
                } header: {
                    Text("Your account")
                } footer: {
                    // A claim about what Comb does, not about the world. The
                    // previous wording said this was the only copy of the
                    // account, which Comb cannot know: anyone who arrived
                    // through Sign in with your key already has it on the
                    // machine they copied it from.
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Your name is what people see in channels. Comb keeps this account on this iPhone: it is never copied to iCloud or included in a backup.")

                        // Stated once, plainly, and never again once it is
                        // done. The join screen says what happens if the phone
                        // is lost; this is the one place that can do anything
                        // about it, so it is the one place that mentions it.
                        // Not a badge and not a nag: a sentence that stops
                        // being true and then stops being shown.
                        if !hasCopiedAccount {
                            Text("You have not saved a copy of this account yet.")
                        }

                        // Added below rather than swapped in. The privacy
                        // sentence is most worth reading at exactly the moment
                        // something went wrong with the name, so replacing it
                        // takes the reassurance away when it is needed.
                        if nameUndelivered {
                            InlineNotice(kind: .warning, text: FailureText.nameUndelivered)
                        }
                    }
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
                    NavigationLink {
                        BlockedListView(session: session)
                    } label: {
                        Label("Blocked", systemImage: "hand.raised")
                    }
                } footer: {
                    Text("People you have hidden on this iPhone. Blocking is never published, and they are not told.")
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
                    Toggle("Load pictures from other sites", isOn: $loadsRemoteImages)
                        .tint(Palette.chartreuse)
                        .onChange(of: loadsRemoteImages) { _, enabled in
                            SyncSettings.loadsRemoteImages = enabled
                        }
                } header: {
                    Text("Pictures")
                } footer: {
                    // Off by default, so this explains a thing the reader may
                    // have already noticed rather than offering a new risk.
                    Text("Most pictures live on your community's own server and always load. A few people point theirs somewhere else, and fetching those tells that site you are here. Their initials show instead.")
                }
                .combRows()

                Section {
                    Toggle("Sync what I have read", isOn: $syncsReadState)
                        .tint(Palette.chartreuse)
                        .onChange(of: syncsReadState) { _, enabled in
                            SyncSettings.syncsReadState = enabled
                            Task { await session.setSyncsReadState(enabled) }
                        }
                } header: {
                    Text("Other devices")
                } footer: {
                    // What it costs, in the same breath as what it does. The
                    // markers are encrypted to this account's own key, so the
                    // relay cannot read which rooms were read; the thing it
                    // does learn is that something was read, and roughly when.
                    //
                    // Comb publishes this twice: its own shape, which carries
                    // when each decision was made, and NIP-RS, which other
                    // clients read. The second sentence is the difference
                    // between them, and it is a limit of the standard rather
                    // than of Comb: NIP-RS is a grow-only maximum, so there is
                    // no way to express "I marked this unread" in it at all.
                    Text("Keeps unread badges in step across your devices, including other apps on this account that read the same standard. Marking something unread stays between your Comb devices, because the standard has no way to say it. Your read markers are encrypted to your own key, so the relay cannot read them, but it can see when they are sent. Off by default: this is the one thing Comb can keep entirely on this iPhone.")
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
                    // What Buzz is, from the people who make it. Comb explains
                    // itself but should not try to explain someone else's
                    // product secondhand.
                    Link(destination: URL(string: "https://buzz.xyz")!) {
                        RowLabel(title: "What is Buzz?", systemImage: "arrow.up.right.square")
                    }
                } footer: {
                    Text("An independent, open source client for Buzz relays. Not affiliated with Block, Inc.")
                }
                .combRows()
            }
            .combForm()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                let profile = try? session.store.profile(pubkey: session.me.hex)
                displayName = profile?.displayName ?? ""
                hasCopiedAccount = AccountBackup.hasCopied(host: host)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .a11y(A11y.settingsDone)
                }
            }
            .a11y(A11y.settingsScreen)
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
        Task { nameUndelivered = await !session.setProfile(displayName: trimmed) }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// The identity, in exportable form, shown only on explicit request.
struct RecoveryCodeView: View {
    let host: String
    /// Fired when the key reaches the clipboard, which is the last moment this
    /// app can observe. Revealing is not enough: looking at something is not
    /// keeping it.
    var onCopied: () -> Void = {}

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
                        AccountBackup.recordCopy(host: host)
                        onCopied()
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
        // Matches the row that opens it. Tapping "Save a copy" and landing on
        // a screen called "Private key" made the reader wonder whether they
        // had arrived somewhere else. The section headers below still name the
        // thing exactly, which is where that vocabulary belongs.
        .navigationTitle("Save a copy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
