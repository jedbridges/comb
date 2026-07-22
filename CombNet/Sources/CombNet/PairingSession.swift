import CombCore
import Foundation

/// The receiving side of NIP-AB device pairing: scan a QR on the desktop,
/// compare six digits, receive the account.
///
/// Everything on the wire is a kind 24134 event between two ephemeral keys,
/// content NIP-44 encrypted. The stored account key never touches this
/// connection until the desktop sends it as the final payload, and that
/// payload is not accepted until the transcript hash has verified AND the
/// human has said the digits match.
public actor PairingSession {
    // MARK: - Public surface

    public enum State: Sendable, Equatable {
        case connecting
        /// Show these digits; the person compares them with the desktop.
        case comparing(code: String)
        /// Both sides agree; the account is on its way.
        case transferring
        /// Credentials arrived and are being checked against their relay.
        case validating
        case complete(Credentials)
        case failed(reason: FailureReason)
    }

    public struct Credentials: Sendable, Equatable {
        public let relayURL: URL
        public let nsec: String
        public let pubkey: String?
    }

    public enum FailureReason: Sendable, Equatable {
        /// Transcript mismatch: the cryptographic session disagrees with what
        /// the humans approved. Treated as an attack, not a retry.
        case securityMismatch
        /// The person said the digits differ.
        case userRejected
        case sourceAborted(String)
        case timedOut
        case connectionLost
        case invalidPayload(String)
        case credentialsRejected
    }

    private static let pairingKind = EventKind(rawValue: 24134)
    private static let sessionTimeout: Duration = .seconds(120)
    /// Dedicated pairing relays may be open; wait this long for a NIP-42
    /// challenge before proceeding unauthenticated. Injectable, so tests skip
    /// it; the session timeout is a real deadline and deliberately is not.
    private static let challengeGrace: Duration = .seconds(3)

    // MARK: - Configuration

    private let invitation: Pairing.Invitation
    private let transport: any WebSocketTransport
    /// Proves delivered credentials actually authenticate against their relay
    /// before pairing reports success. Injected so tests need no second relay.
    private let validateCredentials: @Sendable (URL, String) async throws -> Void
    private let challengeSleep: @Sendable (Duration) async throws -> Void

    // MARK: - State

    private let ephemeralKey: PrivateKey
    private let conversationKey: Data
    private let sessionID: Data
    private let sas: Pairing.ShortAuthentication

    private var stateContinuation: AsyncStream<State>.Continuation?
    private var readTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var processedEventIDs: Set<String> = []

    private var transcriptVerified = false
    private var userConfirmed = false
    private var bufferedPayload: [String: Any]?
    private var isFinished = false

    // MARK: - Lifecycle

    public init(
        invitation: Pairing.Invitation,
        transport: any WebSocketTransport = URLSessionTransport(),
        validateCredentials: @escaping @Sendable (URL, String) async throws -> Void,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) throws {
        self.invitation = invitation
        self.transport = transport
        self.validateCredentials = validateCredentials
        self.challengeSleep = sleep

        // A fresh identity for this session only. The QR gave us the source's
        // ephemeral pubkey and the shared secret; everything derives from those
        // plus this key.
        self.ephemeralKey = try PrivateKey()
        self.conversationKey = try NIP44.conversationKey(
            privateKey: ephemeralKey,
            peer: invitation.sourcePubkey
        )
        self.sessionID = Pairing.sessionID(sessionSecret: invitation.sessionSecret)
        self.sas = Pairing.shortAuthentication(
            sharedSecret: try Pairing.sharedSecret(
                privateKey: ephemeralKey,
                peer: invitation.sourcePubkey
            ),
            sessionSecret: invitation.sessionSecret
        )
    }

    /// Runs the handshake. States stream out; the caller drives `confirmMatch`
    /// or `rejectMatch` when the person has compared digits.
    public func start() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream.makeStream(of: State.self)
        stateContinuation = continuation

        Task { await run() }
        return stream
    }

    /// The person says the digits match.
    public func confirmMatch() async {
        userConfirmed = true
        await advanceIfAgreed()
    }

    /// The person says they differ. NIP-AB requires an abort so the desktop
    /// knows the session is burned.
    public func rejectMatch() async {
        await sendMessage(["type": "abort", "reason": "sas_mismatch"])
        await finish(.failed(reason: .userRejected))
    }

    public func cancel() async {
        await sendMessage(["type": "abort", "reason": "cancelled"])
        await finish(.failed(reason: .userRejected))
    }

    // MARK: - The handshake

    private func run() async {
        emit(.connecting)

        // A real deadline, not the injectable challenge-grace sleep. Tests skip
        // the grace but still need the timeout to mean 120 seconds, not zero.
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.sessionTimeout)
            guard !Task.isCancelled else { return }
            await self?.finish(.failed(reason: .timedOut))
        }

        do {
            guard let relay = invitation.relays.first else {
                throw PairingError.noRelays
            }
            try await transport.open(url: relay)

            readTask = Task { [weak self] in
                await self?.readLoop()
            }

            // NIP-42 is optional on a dedicated pairing relay: give a challenge
            // a moment to arrive, then proceed. The read loop answers one if it
            // does.
            try? await challengeSleep(Self.challengeGrace)

            // Listen for the source's messages to our ephemeral identity.
            let filter = Filter(kinds: [Self.pairingKind])
                .taggingPubkey(ephemeralKey.publicKey.hex)
            try await transport.send(
                try ClientMessage.req(subscriptionID: "pair", filters: [filter]).encoded()
            )

            // The offer tells the source which session this ephemeral key
            // belongs to.
            await sendMessage([
                "type": "offer",
                "version": 1,
                "session_id": sessionID.hex,
            ])

            emit(.comparing(code: sas.code))
        } catch {
            await finish(.failed(reason: .connectionLost))
        }
    }

    private func readLoop() async {
        while !isFinished {
            do {
                let frame = try await transport.receive()
                await handle(frame: frame)
            } catch {
                guard !isFinished else { return }
                await finish(.failed(reason: .connectionLost))
                return
            }
        }
    }

    private func handle(frame: Data) async {
        guard let message = try? RelayMessage(json: frame) else { return }

        switch message {
        case .authChallenge(let challenge):
            // Answer with the ephemeral key; the stored identity is never used
            // on this socket.
            if let relay = invitation.relays.first,
               let response = try? NostrEvent.authResponse(
                   challenge: challenge,
                   relayURL: relay,
                   with: ephemeralKey
               ) {
                try? await transport.send(try ClientMessage.auth(response).encoded())
            }

        case .event(_, let event):
            await handlePairingEvent(event)

        default:
            break
        }
    }

    /// NIP-AB event validation, every step of it. Anything that fails is
    /// silently discarded: this socket is reachable by strangers, and error
    /// responses would be an oracle.
    private func handlePairingEvent(_ event: NostrEvent) async {
        guard event.kind == Self.pairingKind else { return }
        guard event.pubkey == invitation.sourcePubkey.hex else { return }
        guard !processedEventIDs.contains(event.id) else { return }
        guard event.referencedPubkeys.contains(ephemeralKey.publicKey.hex) else { return }
        guard event.isValid else { return }

        guard let decrypted = try? NIP44.decrypt(event.content, conversationKey: conversationKey),
              let object = try? JSONSerialization.jsonObject(with: Data(decrypted.utf8)),
              let message = object as? [String: Any],
              let type = message["type"] as? String
        else { return }

        switch type {
        case "sas-confirm":
            await handleSASConfirm(message)
            processedEventIDs.insert(event.id)
        case "payload":
            await handlePayload(message)
            processedEventIDs.insert(event.id)
        case "abort":
            let reason = message["reason"] as? String ?? "unknown"
            await finish(.failed(reason: .sourceAborted(reason)))
        default:
            break
        }
    }

    private func handleSASConfirm(_ message: [String: Any]) async {
        guard let receivedHex = message["transcript_hash"] as? String,
              let received = Data(hex: receivedHex)
        else { return }

        let expected = Pairing.transcriptHash(
            sessionID: sessionID,
            sourcePubkey: invitation.sourcePubkey,
            targetPubkey: ephemeralKey.publicKey,
            sasInput: sas.input,
            sessionSecret: invitation.sessionSecret
        )

        // The desktop claims a session; this proves it is the same session the
        // human approved. Constant time, and a mismatch is an attack signal
        // that burns the session, never a retry.
        guard Pairing.constantTimeEquals(received, expected) else {
            await sendMessage(["type": "abort", "reason": "sas_mismatch"])
            await finish(.failed(reason: .securityMismatch))
            return
        }

        transcriptVerified = true
        await advanceIfAgreed()
    }

    /// The payload gate: cryptography and human must both have said yes.
    private func advanceIfAgreed() async {
        guard transcriptVerified, userConfirmed, !isFinished else { return }
        emit(.transferring)

        if let buffered = bufferedPayload {
            bufferedPayload = nil
            await handlePayload(buffered)
        }
    }

    private func handlePayload(_ message: [String: Any]) async {
        // Early payloads wait for the gate rather than being dropped; the
        // desktop may race ahead of the human.
        guard transcriptVerified, userConfirmed else {
            bufferedPayload = message
            return
        }

        guard let payloadString = message["payload"] as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(payloadString.utf8)),
              let payload = object as? [String: Any],
              let relayString = payload["relayUrl"] as? String
        else {
            await finish(.failed(reason: .invalidPayload("missing relay")))
            return
        }

        guard let nsec = payload["nsec"] as? String, !nsec.isEmpty else {
            await finish(.failed(reason: .invalidPayload("missing account")))
            return
        }

        // The relay URL arrived over the network; the same SSRF guard as the
        // community index applies before anything connects to it.
        guard let relayURL = Self.validatedRelayURL(relayString) else {
            await finish(.failed(reason: .invalidPayload("unsafe relay URL")))
            return
        }

        emit(.validating)

        do {
            // Prove the credentials before reporting success: a payload that
            // cannot authenticate is a failed pairing, not a stored mystery.
            try await validateCredentials(relayURL, nsec)
        } catch {
            await finish(.failed(reason: .credentialsRejected))
            return
        }

        await sendMessage(["type": "complete", "success": true])
        await finish(.complete(Credentials(
            relayURL: relayURL,
            nsec: nsec,
            pubkey: payload["pubkey"] as? String
        )))
    }

    static func validatedRelayURL(_ string: String) -> URL? {
        guard let url = URL(string: string) else { return nil }
        // Buzz sends https origins here; the socket lives at wss on the host.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch components?.scheme?.lowercased() {
        case "https", "wss": components?.scheme = "wss"
        case "http", "ws": components?.scheme = "ws"
        default: return nil
        }
        guard let host = components?.host, !host.isEmpty else { return nil }
        // Plaintext only ever for local development.
        if components?.scheme == "ws" && host != "localhost" && host != "127.0.0.1" {
            return nil
        }
        guard !CommunityIndex.Entry.isPrivateHost(host) || host == "localhost" || host == "127.0.0.1" else {
            return nil
        }
        components?.path = ""
        components?.query = nil
        return components?.url
    }

    // MARK: - Plumbing

    private func sendMessage(_ message: [String: Any]) async {
        guard let json = try? JSONSerialization.data(withJSONObject: message),
              let encrypted = try? NIP44.encrypt(
                  String(decoding: json, as: UTF8.self),
                  conversationKey: conversationKey
              ),
              let event = try? NostrEvent.signed(
                  kind: Self.pairingKind,
                  content: encrypted,
                  tags: [["p", invitation.sourcePubkey.hex]],
                  with: ephemeralKey
              )
        else { return }

        try? await transport.send(try ClientMessage.event(event).encoded())
    }

    private func emit(_ state: State) {
        guard !isFinished else { return }
        stateContinuation?.yield(state)
    }

    private func finish(_ state: State) async {
        guard !isFinished else { return }
        isFinished = true
        stateContinuation?.yield(state)
        stateContinuation?.finish()
        readTask?.cancel()
        timeoutTask?.cancel()
        await transport.close()
    }
}
