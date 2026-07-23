import CombCore
import CombNet
import CombStore
import SwiftUI

/// The door for people who already have an account: relay plus recovery code.
///
/// This screen is where the technical vocabulary is allowed to exist, because
/// anyone arriving here brought it with them. Restoring persists custody the
/// same as joining does, so the next launch opens straight into channels.
struct RestoreView: View {
    let onRestored: (CommunitySession) -> Void

    @State private var model = RestoreModel()
    @FocusState private var focus: Field?

    private enum Field { case url, key }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    PairingView(onPaired: onRestored)
                } label: {
                    Label("Pair with a device", systemImage: "qrcode")
                }
            } footer: {
                Text("Scan a code from Buzz on your computer to move your account across.")
            }
            .combRows()

            Section("Community relay") {
                TextField("wss://…", text: $model.relayURL)
                    .font(Typography.mono)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focus, equals: .url)
            }
            .combRows()

            Section {
                SecureField("nsec1…", text: $model.secretKey)
                    .font(Typography.mono)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .key)
            } header: {
                // "Private key" because that is what Buzz calls it, and this
                // screen exists to receive a key copied out of Buzz. A softer
                // word here would send people looking for something that does
                // not exist on the other side.
                Text("Private key")
            } footer: {
                Text("Paste the key from Buzz, or 64 hex characters. It stays on this iPhone and is sent nowhere.")
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
                            onRestored(session)
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
            PrimaryButton(
                title: model.isRestoring ? "Restoring…" : "Restore",
                isDisabled: model.secretKey.isEmpty || model.isRestoring
            ) {
                focus = nil
                Task {
                    if let session = await model.restore() {
                        onRestored(session)
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.xs)
        }
        .navigationTitle("Restore")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
@Observable
final class RestoreModel {
    /// Empty in release: prefilling one community's address would send
    /// everyone else's restore to the wrong place. The debug build keeps a
    /// default so testing does not mean retyping it every launch.
    #if DEBUG
    var relayURL = "wss://designers.communities.buzz.xyz"
    #else
    var relayURL = ""
    #endif
    var secretKey = ""

    private(set) var isRestoring = false
    private(set) var failure: String?

    func restore() async -> CommunitySession? {
        guard !isRestoring else { return nil }
        isRestoring = true
        failure = nil
        defer { isRestoring = false }

        guard let url = URL(string: relayURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
              let host = url.host
        else {
            failure = "That does not look like a relay URL."
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
        case RelayError.authenticationFailed(let reason):
            "The relay rejected this account: \(reason)"
        case RelayError.timedOut:
            "The relay did not answer in time."
        case RelayError.notConnected:
            "Could not reach the relay."
        case RelayError.subscriptionClosed(let reason):
            reason
        default:
            // Never the raw Swift error: it names types the reader has no way
            // to act on. The diagnostics screen is where the detail lives.
            "Could not restore this account. Check the address and the code, then try again."
        }
    }
}
