import CombCore
import Foundation

/// Where verified events go. The seam between the network and storage.
///
/// CombNet has no idea a database exists; CombStore has no idea a socket does.
/// They meet here, which is what lets each be tested without the other.
public protocol EventSink: Sendable {
    func ingest(_ events: [NostrEvent], subscription: String) async
    /// Stored history for this subscription is exhausted; everything after is
    /// live. The UI drops its loading state on this.
    func endOfStoredEvents(subscription: String) async
}

public enum ConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case authenticating
    case ready
    case reconnecting(attempt: Int)
    case stopped
}

public enum RelayError: Error, Equatable {
    /// A filter with no `kinds` is refused by Buzz relays with a 403 rather than
    /// being treated as unconstrained, so it is caught before sending.
    case filterMissingKinds
    /// Gift wraps and membership notices must be scoped with `#p` to the
    /// authenticated user, or the relay closes the subscription.
    case filterRequiresPubkeyScope
    /// The relay rejected a published event, with its stated reason.
    case publishRejected(String)
    /// The relay closed a subscription, with its stated reason.
    case subscriptionClosed(String)
    case authenticationFailed(String)
    case notConnected
    case timedOut
}

/// One relay connection: authentication, subscriptions, publishing, reconnect.
///
/// A relay host is a community in Buzz, so one session is one community.
public actor RelaySession {
    // MARK: - Configuration

    private let url: URL
    private let signer: any EventSigner
    private let sink: any EventSink
    private let transport: any WebSocketTransport
    private let policy: ReconnectPolicy
    /// Injectable so tests do not spend real time in reconnect backoff. Query
    /// deadlines deliberately do not use this.
    private let backoffSleep: @Sendable (Duration) async throws -> Void

    /// Replay overlap on reconnect. Relay clocks drift and many events share a
    /// second, so resuming exactly at the last timestamp drops messages. The
    /// duplicates this causes are free: the store keys on event id.
    private static let replaySkew: Int64 = 5

    // MARK: - State

    public private(set) var state: ConnectionState = .idle

    private var subscriptions: [String: Subscription] = [:]
    private var nextSubscriptionID = 0

    private var readTask: Task<Void, Never>?
    private var isStopping = false

    /// Continuations waiting for authentication to complete.
    private var authWaiters: [CheckedContinuation<Void, Error>] = []
    /// The id of the in-flight NIP-42 response, so its OK can be told apart from
    /// a publish OK.
    private var pendingAuthEventID: String?
    private var authenticatedAs: PublicKey?

    /// Publishes waiting on their OK, keyed by event id.
    private var pendingPublishes: [String: CheckedContinuation<Void, Error>] = [:]

    private struct Subscription {
        let id: String
        let label: String
        var filters: [Filter]
        let isOneShot: Bool
        /// Newest event seen, for resuming after a reconnect.
        var lastSeen: Int64?
        var collected: [NostrEvent] = []
        var continuation: CheckedContinuation<[NostrEvent], Error>?
        /// Guards the re-auth retry so a genuinely forbidden subscription cannot
        /// loop forever.
        var retriedAfterAuth = false
    }

    // MARK: - Lifecycle

    public init(
        url: URL,
        signer: any EventSigner,
        sink: any EventSink,
        transport: any WebSocketTransport = URLSessionTransport(),
        policy: ReconnectPolicy = .default,
        backoffSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.url = url
        self.signer = signer
        self.sink = sink
        self.transport = transport
        self.policy = policy
        self.backoffSleep = backoffSleep
    }

    public func start() async throws {
        guard state == .idle || state == .stopped else { return }
        isStopping = false
        try await connect()
    }

    public func stop() async {
        isStopping = true
        readTask?.cancel()
        readTask = nil
        await transport.close()

        // Anything waiting will never be answered now, so fail it rather than
        // leaving callers suspended forever.
        failAllWaiters(with: RelayError.notConnected)
        state = .stopped
    }

    private func connect() async throws {
        state = .connecting
        try await transport.open(url: url)

        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    // MARK: - Read loop

    private func readLoop() async {
        while !isStopping, !Task.isCancelled {
            do {
                let frame = try await transport.receive()
                await handle(frame: frame)
            } catch {
                guard !isStopping, !Task.isCancelled else { return }
                await scheduleReconnect()
                return
            }
        }
    }

    private func handle(frame: Data) async {
        guard let message = try? RelayMessage(json: frame) else {
            // An unparseable or future message type is not fatal. Relays add
            // message types, and refusing to continue would take the app down
            // for something it could safely ignore.
            return
        }

        switch message {
        case .authChallenge(let challenge):
            await respondToChallenge(challenge)

        case .event(let subscriptionID, let event):
            await receive(event, for: subscriptionID)

        case .endOfStoredEvents(let subscriptionID):
            await handleEndOfStoredEvents(subscriptionID)

        case .ok(let eventID, let accepted, let reason):
            handleOK(eventID: eventID, accepted: accepted, reason: reason)

        case .closed(let subscriptionID, let reason):
            await handleClosed(subscriptionID, reason: reason)

        case .notice:
            // Advisory only. Using notices for control flow would be guessing,
            // since their text is not specified.
            break
        }
    }

    // MARK: - Authentication

    private func respondToChallenge(_ challenge: String) async {
        state = .authenticating
        do {
            let event = try await NostrEvent.authResponse(
                challenge: challenge,
                relayURL: url,
                with: signer
            )
            pendingAuthEventID = event.id
            try await send(.auth(event))
        } catch {
            completeAuth(with: .failure(RelayError.authenticationFailed("\(error)")))
        }
    }

    private func completeAuth(with result: Result<PublicKey, Error>) {
        pendingAuthEventID = nil

        switch result {
        case .success(let key):
            authenticatedAs = key
            state = .ready
            for waiter in authWaiters { waiter.resume() }
        case .failure(let error):
            authenticatedAs = nil
            for waiter in authWaiters { waiter.resume(throwing: error) }
        }
        authWaiters.removeAll()
    }

    /// Suspends until the relay has accepted our identity.
    ///
    /// Every REQ and EVENT goes through this. Buzz relays advertise
    /// `auth_required: true` unconditionally, so sending before authentication
    /// only earns a `CLOSED auth-required:` and a wasted round trip.
    private func waitForAuthentication() async throws {
        if state == .ready, authenticatedAs != nil { return }
        guard !isStopping else { throw RelayError.notConnected }

        try await withCheckedThrowingContinuation { continuation in
            authWaiters.append(continuation)
        }
    }

    // MARK: - Subscriptions

    /// Opens a live subscription. Events flow to the sink until cancelled.
    @discardableResult
    public func subscribe(_ filters: [Filter], label: String = "") async throws -> String {
        try validate(filters)
        try await waitForAuthentication()

        let id = makeSubscriptionID()
        subscriptions[id] = Subscription(
            id: id,
            label: label,
            filters: filters,
            isOneShot: false
        )
        try await send(.req(subscriptionID: id, filters: filters))
        return id
    }

    public func unsubscribe(_ id: String) async {
        guard subscriptions.removeValue(forKey: id) != nil else { return }
        try? await send(.close(subscriptionID: id))
    }

    /// Runs a one-shot query, returning everything stored that matches.
    ///
    /// Resolves on EOSE and closes itself, which is what NIP-50 search and the
    /// initial channel-metadata fetch need.
    public func query(
        _ filters: [Filter],
        timeout: Duration = .seconds(15)
    ) async throws -> [NostrEvent] {
        try validate(filters)
        try await waitForAuthentication()

        let id = makeSubscriptionID()

        // A real deadline, not the injectable backoff sleep. Tests skip
        // reconnect delays but still need query timeouts to mean what they say.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timeOutQuery(id)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            subscriptions[id] = Subscription(
                id: id,
                label: "query",
                filters: filters,
                isOneShot: true,
                continuation: continuation
            )
            Task { try? await send(.req(subscriptionID: id, filters: filters)) }
        }
    }

    private func timeOutQuery(_ id: String) async {
        guard let subscription = subscriptions.removeValue(forKey: id) else { return }
        subscription.continuation?.resume(throwing: RelayError.timedOut)
        try? await send(.close(subscriptionID: id))
    }

    /// Catches filters the relay will refuse, so the failure is a clear error
    /// here rather than a confusing CLOSED later.
    private func validate(_ filters: [Filter]) throws {
        for filter in filters {
            // Buzz treats a missing `kinds` as an unscoped query and rejects it
            // outright rather than serving everything.
            guard let kinds = filter.kinds, !kinds.isEmpty else {
                throw RelayError.filterMissingKinds
            }
            guard !filter.needsPubkeyScope else {
                throw RelayError.filterRequiresPubkeyScope
            }
        }
    }

    private func makeSubscriptionID() -> String {
        nextSubscriptionID += 1
        return "s\(nextSubscriptionID)"
    }

    // MARK: - Publishing

    /// Publishes an event, suspending until the relay accepts or rejects it.
    public func publish(_ event: NostrEvent) async throws {
        guard !event.kind.isRelaySigned else {
            throw RelayError.publishRejected("kind \(event.kind) is signed by the relay")
        }
        try await waitForAuthentication()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingPublishes[event.id] = continuation
            Task {
                do {
                    try await send(.event(event))
                } catch {
                    resumePublish(event.id, with: .failure(error))
                }
            }
        }
    }

    private func resumePublish(_ eventID: String, with result: Result<Void, Error>) {
        guard let continuation = pendingPublishes.removeValue(forKey: eventID) else { return }
        continuation.resume(with: result)
    }

    // MARK: - Message handling

    private func receive(_ event: NostrEvent, for subscriptionID: String) async {
        // A stale frame for a subscription closed during reconnect. Dropping it
        // is correct; there is nobody left to deliver it to.
        guard var subscription = subscriptions[subscriptionID] else { return }

        subscription.lastSeen = max(subscription.lastSeen ?? 0, event.createdAt)

        if subscription.isOneShot {
            subscription.collected.append(event)
            subscriptions[subscriptionID] = subscription
        } else {
            subscriptions[subscriptionID] = subscription
            await sink.ingest([event], subscription: subscriptionID)
        }
    }

    private func handleEndOfStoredEvents(_ subscriptionID: String) async {
        guard let subscription = subscriptions[subscriptionID] else { return }

        if subscription.isOneShot {
            subscriptions.removeValue(forKey: subscriptionID)
            subscription.continuation?.resume(returning: subscription.collected)
            try? await send(.close(subscriptionID: subscriptionID))
        } else {
            await sink.endOfStoredEvents(subscription: subscriptionID)
        }
    }

    private func handleOK(eventID: String, accepted: Bool, reason: String) {
        // The NIP-42 response gets an OK like any other event, so it has to be
        // told apart from a publish before the publish table is consulted.
        if eventID == pendingAuthEventID {
            if accepted {
                Task {
                    let key = try? await signer.publicKey()
                    await finishAuth(key: key, reason: reason)
                }
            } else {
                completeAuth(with: .failure(RelayError.authenticationFailed(reason)))
            }
            return
        }

        resumePublish(
            eventID,
            with: accepted ? .success(()) : .failure(RelayError.publishRejected(reason))
        )
    }

    private func finishAuth(key: PublicKey?, reason: String) {
        guard let key else {
            completeAuth(with: .failure(RelayError.authenticationFailed(reason)))
            return
        }
        completeAuth(with: .success(key))
    }

    private func handleClosed(_ subscriptionID: String, reason: String) async {
        guard let subscription = subscriptions[subscriptionID] else { return }

        // A relay that restarted forgets we authenticated and answers with
        // auth-required. Rather than going silently deaf, treat that as a
        // demotion, wait for the next challenge, and retry the subscription once.
        //
        // `restricted:` is deliberately not retried. NIP-01 draws a real
        // distinction: auth-required means authenticate and try again, while
        // restricted means this pubkey may not have this, and retrying would
        // hammer the relay for something that will never be permitted.
        if Self.isAuthRequired(reason), !subscription.retriedAfterAuth {
            authenticatedAs = nil
            state = .authenticating

            var retried = subscription
            retried.retriedAfterAuth = true
            subscriptions[subscriptionID] = retried

            Task {
                try? await waitForAuthentication()
                try? await send(.req(
                    subscriptionID: subscriptionID,
                    filters: retried.filters
                ))
            }
            return
        }

        subscriptions.removeValue(forKey: subscriptionID)
        subscription.continuation?.resume(throwing: RelayError.subscriptionClosed(reason))
    }

    /// NIP-01 machine-readable prefix. The text after the colon is for humans
    /// and is not matched on.
    private static func isAuthRequired(_ reason: String) -> Bool {
        reason.hasPrefix("auth-required:")
    }

    // MARK: - Reconnect

    private func scheduleReconnect() async {
        guard !isStopping else { return }

        // In-flight publishes cannot be answered across a reconnect, because the
        // relay never sends an OK for a socket that no longer exists. The outbox
        // is what makes the retry safe.
        failPendingPublishes(with: RelayError.notConnected)

        var attempt = 0
        while !isStopping {
            attempt += 1
            state = .reconnecting(attempt: attempt)

            do {
                try await backoffSleep(policy.delay(forAttempt: attempt))
                try await transport.open(url: url)

                readTask = Task { [weak self] in
                    await self?.readLoop()
                }

                try await waitForAuthentication()
                await resubscribeAll()
                return
            } catch {
                continue
            }
        }
    }

    /// Re-opens every live subscription, resuming just before the last event
    /// seen so nothing that arrived during the outage is missed.
    private func resubscribeAll() async {
        for (id, subscription) in subscriptions where !subscription.isOneShot {
            var filters = subscription.filters
            if let lastSeen = subscription.lastSeen {
                for index in filters.indices {
                    filters[index].since = lastSeen - Self.replaySkew
                }
            }

            var updated = subscription
            updated.retriedAfterAuth = false
            subscriptions[id] = updated

            try? await send(.req(subscriptionID: id, filters: filters))
        }

        // One-shot queries are not replayed. Their caller sees a thrown error
        // and can decide whether the answer is still wanted.
        for (id, subscription) in subscriptions where subscription.isOneShot {
            subscriptions.removeValue(forKey: id)
            subscription.continuation?.resume(throwing: RelayError.notConnected)
        }
    }

    // MARK: - Plumbing

    private func send(_ message: ClientMessage) async throws {
        try await transport.send(try message.encoded())
    }

    private func failPendingPublishes(with error: Error) {
        for (_, continuation) in pendingPublishes { continuation.resume(throwing: error) }
        pendingPublishes.removeAll()
    }

    private func failAllWaiters(with error: Error) {
        failPendingPublishes(with: error)

        for waiter in authWaiters { waiter.resume(throwing: error) }
        authWaiters.removeAll()

        for (id, subscription) in subscriptions {
            subscription.continuation?.resume(throwing: error)
            subscriptions.removeValue(forKey: id)
        }
    }
}
