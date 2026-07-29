import CombCore
import Foundation
import CombNet

/// A scripted websocket standing in for a relay.
///
/// The entire protocol state machine is exercised through this: no network, no
/// server, no timing flakiness. Frames the client sends are recorded and can be
/// answered by a behaviour closure, which is what lets a test express "a relay
/// that rejects this publish" in one line.
public actor MockTransport: WebSocketTransport {
    private var inbox: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var failure: Error?

    public private(set) var sentFrames: [Data] = []
    public private(set) var openCount = 0
    public private(set) var isClosed = false

    /// Answers a frame from the client with zero or more frames back.
    public var behaviour: (@Sendable (RelayRequest, MockTransport) async -> Void)?

    public init() {}

    // MARK: - WebSocketTransport

    public func open(url: URL) async throws {
        openCount += 1
        isClosed = false
        failure = nil
    }

    public func send(_ frame: Data) async throws {
        if let failure { throw failure }
        sentFrames.append(frame)

        if let behaviour, let request = RelayRequest(frame: frame) {
            await behaviour(request, self)
        }
    }

    public func receive() async throws -> Data {
        if let failure, inbox.isEmpty { throw failure }
        if !inbox.isEmpty { return inbox.removeFirst() }

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func close() async {
        isClosed = true
    }

    // MARK: - Test control

    /// Delivers a frame to the client.
    public func push(_ text: String) {
        let data = Data(text.utf8)
        if waiters.isEmpty {
            inbox.append(data)
        } else {
            waiters.removeFirst().resume(returning: data)
        }
    }

    public func push(event: NostrEvent, subscription: String) throws {
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        push("[\"EVENT\",\"\(subscription)\",\(json)]")
    }

    /// Simulates the connection dropping.
    public func drop(_ error: Error = TransportError.notOpen) {
        failure = error
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: error) }
    }

    /// Frames the client sent, decoded into Sendable values.
    ///
    /// Typed rather than `[[Any]]` because a JSON array of `Any` cannot cross an
    /// actor boundary under strict concurrency, and because asserting on
    /// `frame.filters.first?.since` reads better than subscripting into
    /// dictionaries.
    public func sent() -> [SentFrame] {
        sentFrames.compactMap(SentFrame.init(frame:))
    }

    public func sent(ofType type: String) -> [SentFrame] {
        sent().filter { $0.type == type }
    }

    public func reset() {
        sentFrames.removeAll()
    }
}

/// A frame the client sent, in a form tests can assert against.
public struct SentFrame: Sendable {
    public let type: String
    public let subscriptionID: String?
    public let event: NostrEvent?
    public let filters: [Filter]

    public init?(frame: Data) {
        guard let array = try? JSONSerialization.jsonObject(with: frame) as? [Any],
              let type = array.first as? String
        else { return nil }
        self.type = type

        switch type {
        case "AUTH", "EVENT":
            subscriptionID = nil
            filters = []
            event = (array.count > 1 ? array[1] as? [String: Any] : nil)
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(NostrEvent.self, from: $0) }

        case "REQ":
            subscriptionID = array.count > 1 ? array[1] as? String : nil
            event = nil
            filters = array.dropFirst(2).compactMap { element in
                (element as? [String: Any])
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { try? JSONDecoder().decode(Filter.self, from: $0) }
            }

        default:
            subscriptionID = array.count > 1 ? array[1] as? String : nil
            event = nil
            filters = []
        }
    }
}

/// A frame the client sent, decoded enough for a fake relay to respond to.
///
/// `Sendable`, which matters now that it is the parameter of a public
/// `@Sendable` closure: filters are decoded into `Filter` rather than carried
/// as `[String: Any]`, so a behaviour written outside this module can hold one.
public enum RelayRequest: Sendable {
    case auth(NostrEvent)
    case event(NostrEvent)
    case req(id: String, filters: [Filter])
    case close(id: String)

    public init?(frame: Data) {
        guard let array = try? JSONSerialization.jsonObject(with: frame) as? [Any],
              let type = array.first as? String
        else { return nil }

        func event(at index: Int) -> NostrEvent? {
            guard let object = array[index] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: object)
            else { return nil }
            return try? JSONDecoder().decode(NostrEvent.self, from: data)
        }

        switch type {
        case "AUTH":
            guard let value = event(at: 1) else { return nil }
            self = .auth(value)
        case "EVENT":
            guard let value = event(at: 1) else { return nil }
            self = .event(value)
        case "REQ":
            guard let id = array[1] as? String else { return nil }
            let filters = array.dropFirst(2).compactMap { element in
                (element as? [String: Any])
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { try? JSONDecoder().decode(Filter.self, from: $0) }
            }
            self = .req(id: id, filters: filters)
        case "CLOSE":
            guard let id = array[1] as? String else { return nil }
            self = .close(id: id)
        default:
            return nil
        }
    }
}

/// Collects everything the session ingests.
public actor RecordingSink: EventSink {
    public private(set) var events: [NostrEvent] = []
    public private(set) var eoseSubscriptions: [String] = []

    public init() {}

    public func ingest(_ events: [NostrEvent], subscription: String) async {
        self.events.append(contentsOf: events)
    }

    public func endOfStoredEvents(subscription: String) async {
        eoseSubscriptions.append(subscription)
    }
}

// MARK: - Transport fixtures

/// Canned answers for tests whose subject is the transport, not the protocol.
///
/// This used to be called `Behaviour.cooperative`, which flattered it. It
/// authenticates anyone, accepts anything, and evaluates no filters, so it can
/// prove a reconnect resubscribes and a backoff backs off, and it cannot prove
/// anything at all about relay rules: a client that stopped sending `h` tags
/// would pass against it. `BuzzFake` is the conformance target. Reach for this
/// one only when the relay's answer is irrelevant to what is being tested.
public enum TransportFixture {
    /// Says yes to everything and EOSEs every REQ immediately.
    public static func answersEverything(
        onReq: (@Sendable (String, MockTransport) async -> Void)? = nil
    ) -> @Sendable (RelayRequest, MockTransport) async -> Void {
        { request, transport in
            switch request {
            case .auth(let event):
                await transport.push("[\"OK\",\"\(event.id)\",true,\"\"]")
            case .event(let event):
                await transport.push("[\"OK\",\"\(event.id)\",true,\"\"]")
            case .req(let id, _):
                if let onReq {
                    await onReq(id, transport)
                } else {
                    await transport.push("[\"EOSE\",\"\(id)\"]")
                }
            case .close:
                break
            }
        }
    }
}

// MARK: - Async helpers

/// Polls until a condition holds, so tests never depend on a fixed sleep.
public func waitUntil(
    _ description: String = "condition",
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw WaitError.timedOut(description)
}

public enum WaitError: Error, CustomStringConvertible {
    case timedOut(String)

    public var description: String {
        switch self {
        case .timedOut(let what): "timed out waiting for \(what)"
        }
    }
}

/// A session wired to a mock, with the pieces a test needs to poke at.
public struct Harness: Sendable {
    public let session: RelaySession
    public let transport: MockTransport
    public let sink: RecordingSink
    public let signer: InMemorySigner
    public let url = URL(string: "wss://designers.communities.buzz.xyz")!

    public init(
        behaviour: (@Sendable (RelayRequest, MockTransport) async -> Void)? = TransportFixture.answersEverything(),
        policy: ReconnectPolicy = ReconnectPolicy(base: .milliseconds(1), cap: .milliseconds(1))
    ) async throws {
        transport = MockTransport()
        await transport.setBehaviour(behaviour)
        sink = RecordingSink()
        signer = try InMemorySigner()

        session = RelaySession(
            url: url,
            signer: signer,
            sink: sink,
            transport: transport,
            policy: policy,
            // Backoff is asserted directly against ReconnectPolicy, so tests of
            // the session itself should not spend real time asleep.
            backoffSleep: { _ in }
        )
    }

    /// Starts the session and completes the NIP-42 handshake.
    public func connect() async throws {
        try await session.start()
        await transport.push("[\"AUTH\",\"challenge-abc\"]")
        try await waitUntil("authentication") { await session.state == .ready }
    }
}

extension MockTransport {
    public func setBehaviour(_ behaviour: (@Sendable (RelayRequest, MockTransport) async -> Void)?) {
        self.behaviour = behaviour
    }
}
