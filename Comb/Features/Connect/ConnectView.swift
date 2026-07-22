import CombCore
import CombNet
import CombStore
import SwiftUI

/// Manual connection: relay URL plus pasted key.
///
/// This is Phase 4 scaffolding standing where onboarding will go. Real entry
/// is invite links and QR pairing; a pasted nsec survives only as the restore
/// fallback. Until the Keychain lands, the key lives in memory and connecting
/// is explicit on every launch, which is honest about where it is held.
struct ConnectView: View {
    @Bindable var model: ConnectModel
    @FocusState private var focus: Field?

    private enum Field { case url, key }

    var body: some View {
        ZStack {
            Palette.backgroundGradient.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    header
                    form
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Mark().frame(width: 64, height: 64)
            Text("Comb")
                .font(.system(size: 34, weight: .semibold))
                .kerning(-0.7)
                .foregroundStyle(Palette.text)
        }
        .padding(.top, 40)
        .arrival(true)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Community relay") {
                TextField("wss://…", text: $model.relayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focus, equals: .url)
            }

            field("Account key") {
                SecureField("nsec1… or 64 hex characters", text: $model.secretKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .key)
            }

            Text("Held in memory only. Never written to disk, never sent anywhere except as a signature to the relay above.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.subtext)

            Button {
                focus = nil
                Task { await model.connect() }
            } label: {
                Text(model.isConnecting ? "Connecting…" : "Connect")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.chartreuse)
            .foregroundStyle(Palette.ink)
            .disabled(model.isConnecting || model.secretKey.isEmpty)

            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.danger)
            }

            #if DEBUG
            Button("Preview with sample data") {
                Task { await model.connectDemo() }
            }
            .font(.system(size: 13))
            .foregroundStyle(Palette.subtext)
            .frame(maxWidth: .infinity)
            #endif
        }
        .padding(18)
        .glassEffect(in: .rect(cornerRadius: 16))
        .arrival(true, delay: 0.08)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Palette.subtext)
            content()
                .font(.system(size: 15).monospaced())
                .foregroundStyle(Palette.text)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Palette.surface.opacity(0.4), in: .rect(cornerRadius: 8))
        }
    }
}

/// Owns the app's one community session.
@MainActor
@Observable
final class ConnectModel {
    var relayURL = "wss://designers.communities.buzz.xyz"
    /// In memory for the life of the screen. Cleared the moment a session
    /// exists; Keychain custody arrives with onboarding.
    var secretKey = ""

    private(set) var session: CommunitySession?
    private(set) var isConnecting = false
    private(set) var failure: String?

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        failure = nil
        defer { isConnecting = false }

        guard let url = URL(string: relayURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws"
        else {
            failure = "That does not look like a relay URL."
            return
        }

        let key: PrivateKey
        do {
            key = try Self.parseKey(secretKey)
        } catch {
            failure = "Could not read that key. Paste an nsec1… or 64 hex characters."
            return
        }

        do {
            let session = try CommunitySession(url: url, key: key)
            try await session.start()
            self.session = session
            secretKey = ""
        } catch {
            failure = Self.describe(error)
        }
    }

    func disconnect() async {
        await session?.stop()
        session = nil
    }

    #if DEBUG
    /// A local session with fixture data and no relay. Debug builds only.
    func connectDemo() async {
        do {
            let session = try CommunitySession(
                url: URL(string: "wss://demo.local")!,
                key: try PrivateKey(),
                store: try EventStore()   // in-memory: fresh every launch
            )
            try await DemoSeed.seed(into: session.store)
            self.session = session
        } catch {
            failure = Self.describe(error)
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
