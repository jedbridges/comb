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
            Section("Community relay") {
                TextField("wss://…", text: $model.relayURL)
                    .font(Typography.mono)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focus, equals: .url)
            }

            Section {
                SecureField("nsec1… or 64 hex characters", text: $model.secretKey)
                    .font(Typography.mono)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .key)
            } header: {
                Text("Recovery code")
            } footer: {
                Text("Stored in this iPhone's Keychain, on this device only. Sent nowhere.")
            }

            if let failure = model.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.danger)
                }
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
    var relayURL = "wss://designers.communities.buzz.xyz"
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
            failure = "Could not read that code. Paste an nsec1… or 64 hex characters."
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
            "Something went wrong: \(String(describing: error))"
        }
    }
}
