import CombCore
import CombNet
import CombStore
import SwiftUI

/// The door for people who already have an account: community address plus
/// their key.
///
/// This screen is where the technical vocabulary is allowed to exist, because
/// anyone arriving here brought it with them. Restoring persists custody the
/// same as joining does, so the next launch opens straight into channels.
struct SignInView: View {
    let onSignedIn: (CommunitySession) -> Void

    @State private var model = SignInModel()
    @FocusState private var focus: Field?
    /// The manual URL + key path, collapsed by default. Scanning is the route
    /// that carries both pieces for you; typing a wss:// address and a key from
    /// memory is the fallback, so it lives behind a disclosure rather than
    /// facing every returning user with two intimidating fields.
    @State private var showsManual = false

    private enum Field { case url, key }

    var body: some View {
        Form {
            // The recommended way in, given its own prominent card rather than
            // a plain row: pairing needs no typing, and a returning Buzz user
            // rarely has their relay address memorised.
            Section {
                NavigationLink {
                    PairingView(onPaired: onSignedIn)
                } label: {
                    HStack(spacing: Space.md) {
                        Image(systemName: "qrcode")
                            .font(.system(size: Sizing.avatar * 0.7))
                            .foregroundStyle(Palette.chartreuse)
                            .frame(width: Sizing.avatar * 1.2, height: Sizing.avatar * 1.2)

                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text("Scan the code from Buzz")
                                .font(Typography.name)
                                .foregroundStyle(Palette.text)
                            // The exact clicks on the other machine, because
                            // the person reading this has Buzz open beside
                            // them: the avatar menu is per community, so the
                            // community comes first.
                            Text("In the community you want to add, click your avatar, then Settings, then Mobile.")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.subtext)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, Space.xxs)
                }
            }
            .combRows()

            Section {
                DisclosureGroup("Enter it manually instead", isExpanded: $showsManual) {
                    TextField("Community address (wss://…)", text: $model.relayURL)
                        .font(Typography.mono)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focus, equals: .url)

                    SecureField("Private key (nsec1…)", text: $model.secretKey)
                        .font(Typography.mono)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .key)
                }
                .tint(Palette.chartreuse)
            } footer: {
                if showsManual {
                    // "Private key" because that is what Buzz calls it, and
                    // this screen exists to receive a key copied out of Buzz. A
                    // softer word would send people looking for something that
                    // does not exist on the other side.
                    Text("Paste the address and the key from Buzz. They stay on this iPhone and are sent nowhere.")
                }
            }
            .combRows()

            if let failure = model.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.danger)
                }
                .combRows()
            }

            #if DEBUG
            Section {
                Button("Preview with sample data") {
                    Task {
                        if let session = await model.demo() {
                            onSignedIn(session)
                        }
                    }
                }
                .foregroundStyle(Palette.subtext)
            }
            #endif
        }
        .scrollContentBackground(.hidden)
        .background(Palette.backgroundGradient.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            // Only present once the manual path is open. Scanning has its own
            // way forward (the pairing screen), so a permanent "Sign in" button
            // over an empty form would imply typing is the expected route.
            if showsManual {
                PrimaryButton(
                    title: model.isSigningIn ? "Signing in…" : "Sign in",
                    isDisabled: model.secretKey.isEmpty || model.isSigningIn
                ) {
                    focus = nil
                    Task {
                        if let session = await model.signIn() {
                            onSignedIn(session)
                        }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xs)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.standard, value: showsManual)
        .navigationTitle("Sign in")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
@Observable
final class SignInModel {
    /// Empty in release: prefilling one community's address would send
    /// everyone else's restore to the wrong place. The debug build keeps a
    /// default so testing does not mean retyping it every launch.
    #if DEBUG
    var relayURL = "wss://designers.communities.buzz.xyz"
    #else
    var relayURL = ""
    #endif
    var secretKey = ""

    private(set) var isSigningIn = false
    private(set) var failure: String?

    func signIn() async -> CommunitySession? {
        guard !isSigningIn else { return nil }
        isSigningIn = true
        failure = nil
        defer { isSigningIn = false }

        guard let url = URL(string: relayURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
              let host = url.host
        else {
            failure = "That does not look like a community address. It should start with wss://"
            return nil
        }

        let key: PrivateKey
        do {
            key = try Self.parseKey(secretKey)
        } catch {
            failure = "That does not look like a private key. Paste an nsec1 key, or 64 hex characters."
            return nil
        }

        do {
            let session = try CommunitySession(url: url, key: key)
            try await session.start()

            // Custody after the relay accepted the identity, so a typo never
            // overwrites a stored key with a wrong one.
            try KeychainStore.save(key, host: host)
            CommunityRegistry.add(JoinedCommunity(
                host: host,
                relay: url,
                name: nil,
                joinedAt: Date()
            ))
            secretKey = ""

            return session
        } catch {
            failure = Self.describe(error)
            return nil
        }
    }

    #if DEBUG
    func demo() async -> CommunitySession? {
        do {
            let key = try PrivateKey()
            let session = try CommunitySession(
                url: URL(string: "wss://demo.local")!,
                key: key,
                store: try EventStore()   // in-memory: fresh every launch
            )
            try await DemoSeed.seed(into: session.store, as: key)
            return session
        } catch {
            failure = Self.describe(error)
            return nil
        }
    }
    #endif

    /// Accepts either form a person is likely to have to hand.
    static func parseKey(_ input: String) throws -> PrivateKey {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("nsec") {
            return try PrivateKey(nsec: trimmed)
        }
        guard let data = Data(hex: trimmed) else { throw CryptoError.invalidKeyLength(0) }
        return try PrivateKey(data: data)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case RelayError.authenticationFailed:
            // The relay's own reason is protocol text; what the person needs to
            // know is that this key is not a member here.
            "That community did not recognise this key."
        case RelayError.timedOut:
            "The community did not answer in time."
        case RelayError.notConnected:
            "Could not reach that community."
        case RelayError.subscriptionClosed(let reason):
            reason
        default:
            // Never the raw Swift error: it names types the reader has no way
            // to act on. The diagnostics screen is where the detail lives.
            "Could not sign in. Check the address and the key, then try again."
        }
    }
}
