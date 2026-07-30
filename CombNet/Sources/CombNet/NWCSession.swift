import CombCore
import Foundation

/// One conversation with a wallet, over the wallet's own relay.
///
/// Deliberately not built on `RelaySession`, and the reason is structural rather
/// than stylistic. Every `subscribe`, `query` and `publish` there goes through
/// `waitForAuthentication()`, and the only thing that sets that gate open is
/// completing a NIP-42 challenge. A wallet's relay usually never sends one, so
/// each call would suspend until the thirty-second watchdog fired and then
/// throw. `PairingSession` already solved this shape, and this follows it: drive
/// the transport directly, wait out a short grace for a challenge, and proceed
/// unauthenticated when none arrives.
///
/// Short-lived on purpose. Opened for one request, closed after its answer, the
/// way `BackgroundRefresh` builds and drops whole sessions. A standing socket to
/// a third party's relay is a standing statement that this device is here, and a
/// zap does not need one.
public actor NWCSession {
    public enum Failure: Error, Equatable {
        case cannotReachRelay
        /// No answer inside the deadline. The payment may still have happened,
        /// which is why this is not reported as a refusal.
        case timedOut
        case connectionLost
        /// The wallet advertises no nip44 support, so Comb will not talk to it.
        /// See `NWC` for why nip04 is not the fallback.
        case encryptionUnsupported
        /// The wallet published no info event on this relay.
        case noWalletFound
    }

    /// How long to wait for a wallet to answer.
    ///
    /// A payment routes in seconds, and the reader is holding a phone waiting to
    /// find out. Long enough for a slow route, short enough that the sheet is
    /// not lying about being busy.
    public static let responseTimeout: Duration = .seconds(45)
    /// A wallet relay may be open. Wait this long for a NIP-42 challenge before
    /// proceeding without one. Injectable so tests skip it; the response
    /// deadline is real and deliberately is not.
    private static let challengeGrace: Duration = .seconds(2)

    private let connection: NWC.Connection
    private let transport: any WebSocketTransport
    /// Skips the NIP-42 challenge grace in tests. Deliberately does NOT cover
    /// the response deadline: one closure serving both meant a test that skipped
    /// the grace also made the deadline fire instantly, so every wallet looked
    /// silent and the timeout proved nothing.
    private let challengeSleep: @Sendable (Duration) async throws -> Void
    /// A real deadline, always. Shortened in tests by passing a shorter one, not
    /// by making sleeping a no-op.
    private let responseTimeout: Duration

    public init(
        connection: NWC.Connection,
        transport: any WebSocketTransport = URLSessionTransport(),
        challengeSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        responseTimeout: Duration = NWCSession.responseTimeout
    ) {
        self.connection = connection
        self.transport = transport
        self.challengeSleep = challengeSleep
        self.responseTimeout = responseTimeout
    }

    // MARK: - Public operations

    /// Asks the wallet to pay an invoice, and waits for it to say what happened.
    public func pay(_ bolt11: String) async throws -> NWC.Outcome {
        let request = try NWC.payInvoice(bolt11, connection: connection)
        return try await exchange(request)
    }

    /// Checks that the wallet is reachable and can speak nip44.
    ///
    /// Run once when connecting rather than before every payment. It is the only
    /// thing that can tell a working connection from a URI that merely parsed,
    /// and a reader who pasted the wrong string should learn that then rather
    /// than at the moment they try to pay someone.
    public func checkReachable() async throws {
        guard let relay = connection.relays.first else { throw Failure.cannotReachRelay }
        do {
            try await transport.open(url: relay)
        } catch {
            throw Failure.cannotReachRelay
        }
        defer { Task { await transport.close() } }

        try? await challengeSleep(Self.challengeGrace)

        // The info event is replaceable and published by the wallet, so one
        // filter on its author and kind is the whole question.
        let subscription = "nwc-info"
        var filter = Filter(kinds: [.nwcInfo])
        filter.authors = [connection.walletPubkey.hex]
        filter.limit = 1
        try await send(.req(subscriptionID: subscription, filters: [filter]))

        let info = try await awaitFrame(subscription: subscription) { event in
            event.kind == .nwcInfo && event.pubkey == self.connection.walletPubkey.hex
        }

        guard let info else { throw Failure.noWalletFound }
        guard NWC.supportsNIP44(info: info) else { throw Failure.encryptionUnsupported }
    }

    // MARK: - The exchange

    /// Subscribes for the answer, then sends the question.
    ///
    /// That order is load-bearing. A wallet can answer faster than a second
    /// round trip, so publishing first and subscribing after loses the response
    /// on exactly the fast wallets, and the failure looks like a timeout rather
    /// than like a race.
    private func exchange(_ request: NostrEvent) async throws -> NWC.Outcome {
        guard let relay = connection.relays.first else { throw Failure.cannotReachRelay }
        do {
            try await transport.open(url: relay)
        } catch {
            throw Failure.cannotReachRelay
        }
        defer { Task { await transport.close() } }

        try? await challengeSleep(Self.challengeGrace)

        let subscription = "nwc-\(request.id.prefix(8))"
        var filter = Filter(kinds: [.nwcResponse])
        filter.authors = [connection.walletPubkey.hex]
        // Scoped to this request, so a response to some other in-flight payment
        // on the same connection cannot be read as the answer to this one.
        filter.tags = ["e": [request.id]]
        try await send(.req(subscriptionID: subscription, filters: [filter]))
        try await send(.event(request))

        let response = try await awaitFrame(subscription: subscription) { event in
            event.kind == .nwcResponse && event.firstValue(for: "e") == request.id
        }

        guard let response else { throw Failure.timedOut }
        return try NWC.outcome(of: response, connection: connection)
    }

    /// Reads frames until one satisfies `matches`, the deadline passes, or the
    /// socket closes.
    ///
    /// Answers a NIP-42 challenge if one arrives, because some wallet relays are
    /// gated even though most are not, and the connection secret is the right
    /// key to answer with: it is the identity this wallet knows.
    private func awaitFrame(
        subscription: String,
        matches: @escaping @Sendable (NostrEvent) -> Bool
    ) async throws -> NostrEvent? {
        try await withThrowingTaskGroup(of: NostrEvent?.self) { group in
            group.addTask { [transport, connection] in
                while true {
                    let frame: Data
                    do {
                        frame = try await transport.receive()
                    } catch {
                        throw Failure.connectionLost
                    }

                    guard let message = try? RelayMessage(json: frame) else { continue }
                    switch message {
                    case .event(_, let event) where matches(event):
                        return event
                    case .authChallenge(let challenge):
                        let response = try? NostrEvent.authResponse(
                            challenge: challenge,
                            relayURL: connection.relays.first!,
                            with: connection.secret
                        )
                        if let response {
                            try? await transport.send(try ClientMessage.auth(response).encoded())
                        }
                    // An EOSE means the wallet has published nothing matching
                    // yet. For an info lookup that is a final answer; for a
                    // response it is not, because the answer is still coming.
                    case .endOfStoredEvents(let id) where id == subscription:
                        if subscription == "nwc-info" { return nil }
                    default:
                        continue
                    }
                }
            }

            group.addTask { [responseTimeout] in
                try? await Task.sleep(for: responseTimeout)
                return nil
            }

            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func send(_ message: ClientMessage) async throws {
        do {
            try await transport.send(try message.encoded())
        } catch {
            throw Failure.connectionLost
        }
    }
}
