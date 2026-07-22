import CombCore
import Foundation
@testable import CombNet

/// A scripted websocket standing in for a relay.
///
/// The entire protocol state machine is exercised through this: no network, no
/// server, no timing flakiness. Frames the client sends are recorded and can be
/// answered by a behaviour closure, which is what lets a test express "a relay
/// that rejects this publish" in one line.
actor MockTransport: WebSocketTransport {
    private var inbox: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var failure: Error?

    private(set) var sentFrames: [Data] = []
    private(set) var openCount = 0
    private(set) var isClosed = false

    /// Answers a frame from the client with zero or more frames back.
    var behaviour: (@Sendable (RelayRequest, MockTransport) async -> Void)?

    // MARK: - WebSocketTransport

    func open(url: URL) async throws {
        openCount += 1
        isClosed = false
        failure = nil
    }

    func send(_ frame: Data) async throws {
        if let failure { throw failure }
        sentFrames.append(frame)

        if let behaviour, let request = RelayRequest(frame: frame) {
            await behaviour(request, self)
        }
    }

    func receive() async throws -> Data {
        if let failure, inbox.isEmpty { throw failure }
        if !inbox.isEmpty { return inbox.removeFirst() }

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func close() async {
        isClosed = true
    }

    // MARK: - Test control

    /// Delivers a frame to the client.
    func push(_ text: String) {
        let data = Data(text.utf8)
        if waiters.isEmpty {
            inbox.append(data)
        } else {
            waiters.removeFirst().resume(returning: data)
        }
    }

    func push(event: NostrEvent, subscription: String) throws {
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        push("[\"EVENT\",\"\(subscription)\",\(json)]")
    }

    /// Simulates the connection dropping.
    func drop(_ error: Error = TransportError.notOpen) {
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
    func sent() -> [SentFrame] {
        sentFrames.compactMap(SentFrame.init(frame:))
    }

    func sent(ofType type: String) -> [SentFrame] {
        sent().filter { $0.type == type }
    }

    func reset() {
        sentFrames.removeAll()
    }
}

/// A frame the client sent, in a form tests can assert against.
struct SentFrame: Sendable {
    let type: String
    let subscriptionID: String?
    let event: NostrEvent?
    let filters: [Filter]

    init?(frame: Data) {
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
enum RelayRequest {
    case auth(NostrEvent)
    case event(NostrEvent)
    case req(id: String, filters: [[String: Any]])
    case close(id: String)

    init?(frame: Data) {
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
            self = .req(id: id, filters: array.dropFirst(2).compactMap { $0 as? [String: Any] })
        case "CLOSE":
            guard let id = array[1] as? String else { return nil }
            self = .close(id: id)
        default:
            return nil
        }
    }
}

/// Collects everything the session ingests.
actor RecordingSink: EventSink {
    private(set) var events: [NostrEvent] = []
    private(set) var eoseSubscriptions: [String] = []

    func ingest(_ events: [NostrEvent], subscription: String) async {
        self.events.append(contentsOf: events)
    }

    func endOfStoredEvents(subscription: String) async {
        eoseSubscriptions.append(subscription)
    }
}

// MARK: - Behaviours

enum Behaviour {
    /// A relay that authenticates anyone and answers every REQ with an
    /// immediate EOSE. The common case.
    static func cooperative(
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
func waitUntil(
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

enum WaitError: Error, CustomStringConvertible {
    case timedOut(String)

    var description: String {
        switch self {
        case .timedOut(let what): "timed out waiting for \(what)"
        }
    }
}

/// A session wired to a mock, with the pieces a test needs to poke at.
struct Harness {
    let session: RelaySession
    let transport: MockTransport
    let sink: RecordingSink
    let signer: InMemorySigner
    let url = URL(string: "wss://designers.communities.buzz.xyz")!

    init(
        behaviour: (@Sendable (RelayRequest, MockTransport) async -> Void)? = Behaviour.cooperative(),
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
    func connect() async throws {
        try await session.start()
        await transport.push("[\"AUTH\",\"challenge-abc\"]")
        try await waitUntil("authentication") { await session.state == .ready }
    }
}

extension MockTransport {
    func setBehaviour(_ behaviour: (@Sendable (RelayRequest, MockTransport) async -> Void)?) {
        self.behaviour = behaviour
    }
}
