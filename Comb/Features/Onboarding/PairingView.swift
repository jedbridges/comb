import AVFoundation
import CombCore
import CombNet
import SwiftUI

/// The QR pairing flow: scan the desktop's code, compare six digits, receive
/// the account. Camera scanning on device; a paste field stands in on the
/// simulator and for anyone whose camera is unavailable.
struct PairingView: View {
    let onPaired: (CommunitySession) -> Void

    @State private var model = PairingModel()

    var body: some View {
        Backdrop {
            switch model.phase {
            case .scanning:
                ScannerPane(
                    manualEntry: $model.manualURI,
                    onScan: { model.begin(uri: $0) }
                )
            case .connecting:
                statusPane("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
            case .comparing(let code):
                comparePane(code)
            case .transferring, .validating:
                statusPane("Setting up your account…", systemImage: "checkmark.shield")
            case .failed(let message):
                failurePane(message)
            }
        }
        .navigationTitle("Pair a device")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.pairedSession != nil) { _, ready in
            // CommunitySession is an actor and not Equatable, so the readiness
            // flag is what drives the handoff.
            if ready, let session = model.pairedSession { onPaired(session) }
        }
    }

    private func comparePane(_ code: String) -> some View {
        VStack(spacing: Space.xl) {
            Spacer()

            VStack(spacing: Space.md) {
                Text("Do these numbers match?")
                    .font(Typography.screenTitle)
                    .foregroundStyle(Palette.text)

                Text(code.spacedDigits)
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .foregroundStyle(Palette.chartreuse)
                    .kerning(2)

                Text("Check the other device shows the same code.")
                    .font(Typography.secondary)
                    .foregroundStyle(Palette.subtext)
                    .multilineTextAlignment(.center)
            }
            .arrival(true)

            Spacer()

            VStack(spacing: Space.sm) {
                PrimaryButton(title: "They match") {
                    Task { await model.confirm() }
                }
                SecondaryButton(title: "They don't match") {
                    Task { await model.reject() }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.xxxl)
        }
    }

    private func statusPane(_ text: String, systemImage: String) -> some View {
        VStack(spacing: Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(Palette.subtext)
                .symbolEffect(.pulse)
            Text(text)
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.text)
        }
    }

    private func failurePane(_ message: String) -> some View {
        VStack(spacing: Space.lg) {
            Spacer()
            InlineNotice(kind: .failure, text: message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.lg)
            SecondaryButton(title: "Try again") { model.reset() }
                .padding(.horizontal, Space.lg)
            Spacer()
        }
    }
}

/// The scanner surface: live camera on device, a paste field everywhere else.
private struct ScannerPane: View {
    @Binding var manualEntry: String
    let onScan: (String) -> Void

    var body: some View {
        VStack(spacing: Space.lg) {
            #if targetEnvironment(simulator)
            simulatorFallback
            #else
            QRScannerView(onScan: onScan)
                .clipShape(.rect(cornerRadius: Radii.card))
                .padding(Space.lg)
            manualField
            #endif
        }
    }

    private var manualField: some View {
        VStack(spacing: Space.xs) {
            Text("or paste a pairing code")
                .font(Typography.caption)
                .foregroundStyle(Palette.subtext)
            HStack {
                TextField("nostrpair://…", text: $manualEntry)
                    .font(Typography.monoSmall)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Go") { onScan(manualEntry) }
                    .disabled(manualEntry.isEmpty)
            }
            .padding(Space.sm)
            .glassEffect(in: .rect(cornerRadius: Radii.control))
        }
        .padding(.horizontal, Space.lg)
    }

    private var simulatorFallback: some View {
        VStack(spacing: Space.md) {
            Spacer()
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(Palette.subtext)
            Text("The camera is unavailable in the simulator. Paste a pairing code to continue.")
                .font(Typography.secondary)
                .foregroundStyle(Palette.subtext)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.xl)
            manualField
            Spacer()
        }
    }
}

@MainActor
@Observable
final class PairingModel {
    enum Phase: Equatable {
        case scanning
        case connecting
        case comparing(code: String)
        case transferring
        case validating
        case failed(String)
    }

    private(set) var phase: Phase = .scanning
    private(set) var pairedSession: CommunitySession?
    var manualURI = ""

    private var pairing: PairingSession?
    private var driver: Task<Void, Never>?

    func begin(uri: String) {
        guard case .scanning = phase else { return }

        guard let invitation = try? Pairing.parse(uri.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            phase = .failed("That is not a Comb pairing code.")
            return
        }

        phase = .connecting
        do {
            let pairing = try PairingSession(
                invitation: invitation,
                validateCredentials: { url, nsec in
                    // Prove the delivered account authenticates before trusting
                    // it, by opening a throwaway session and letting it fail if
                    // the relay refuses.
                    let key = try PrivateKey(nsec: nsec)
                    let probe = try CommunitySession(url: url, key: key)
                    try await probe.start()
                    await probe.stop()
                }
            )
            self.pairing = pairing
            drive(pairing)
        } catch {
            phase = .failed("Could not start pairing.")
        }
    }

    func confirm() async {
        await pairing?.confirmMatch()
    }

    func reject() async {
        await pairing?.rejectMatch()
    }

    func reset() {
        driver?.cancel()
        pairing = nil
        manualURI = ""
        phase = .scanning
    }

    private func drive(_ pairing: PairingSession) {
        driver = Task {
            for await state in await pairing.start() {
                switch state {
                case .connecting:
                    phase = .connecting
                case .comparing(let code):
                    phase = .comparing(code: code)
                case .transferring:
                    phase = .transferring
                case .validating:
                    phase = .validating
                case .complete(let credentials):
                    await store(credentials)
                case .failed(let reason):
                    phase = .failed(Self.describe(reason))
                }
            }
        }
    }

    /// Persists the paired account and opens its community, the same custody
    /// path as join and restore.
    private func store(_ credentials: PairingSession.Credentials) async {
        guard let key = try? PrivateKey(nsec: credentials.nsec),
              let host = credentials.relayURL.host
        else {
            phase = .failed("The paired account could not be read.")
            return
        }

        do {
            let session = try CommunitySession(url: credentials.relayURL, key: key)
            try await session.start()
            try? KeychainStore.save(key, host: host)
            CommunityRegistry.add(JoinedCommunity(
                host: host,
                relay: credentials.relayURL,
                name: nil,
                joinedAt: Date()
            ))
            self.pairedSession = session
        } catch {
            phase = .failed("Paired, but could not connect. Try again.")
        }
    }

    static func describe(_ reason: PairingSession.FailureReason) -> String {
        switch reason {
        case .securityMismatch:
            "The codes did not match, which can mean someone is interfering. Pairing stopped for your safety."
        case .userRejected:
            "Pairing cancelled."
        case .sourceAborted(let reason):
            "The other device stopped pairing (\(reason))."
        case .timedOut:
            "Pairing timed out. Start again on the other device."
        case .connectionLost:
            "Lost the connection. Try again."
        case .invalidPayload:
            "The other device sent something unexpected."
        case .credentialsRejected:
            "The account did not work against its community."
        }
    }
}

private extension String {
    /// "482917" becomes "482 917", easier to read aloud and compare.
    var spacedDigits: String {
        guard count == 6 else { return self }
        let middle = index(startIndex, offsetBy: 3)
        return "\(self[startIndex..<middle]) \(self[middle...])"
    }
}
