import Foundation

/// A websocket, reduced to the four operations the relay protocol needs.
///
/// Pull-based rather than stream-based, which maps directly onto
/// `URLSessionWebSocketTask.receive()` and makes backpressure trivial: when the
/// session is saturated it simply stops calling `receive`, the TCP receive
/// window closes, and the relay is throttled by the transport rather than by a
/// buffer that would either grow without bound or silently drop history.
///
/// Existing as a protocol is what lets the entire protocol state machine be
/// tested with no network, no relay, and no timing flakiness.
public protocol WebSocketTransport: Actor {
    func open(url: URL) async throws
    func send(_ frame: Data) async throws
    /// Returns the next frame, suspending until one arrives.
    /// Throws when the connection closes.
    func receive() async throws -> Data
    func close() async
}

/// The production transport.
public actor URLSessionTransport: WebSocketTransport {
    private var task: URLSessionWebSocketTask?
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func open(url: URL) async throws {
        // A stale task must be torn down first, or its read loop would race the
        // new one for frames.
        task?.cancel(with: .goingAway, reason: nil)

        let task = session.webSocketTask(with: url)
        task.resume()
        self.task = task
    }

    public func send(_ frame: Data) async throws {
        guard let task else { throw TransportError.notOpen }
        // Relays expect text frames; NIP-01 is JSON, and some relays reject
        // binary frames outright.
        try await task.send(.string(String(decoding: frame, as: UTF8.self)))
    }

    public func receive() async throws -> Data {
        guard let task else { throw TransportError.notOpen }

        switch try await task.receive() {
        case .string(let text):
            return Data(text.utf8)
        case .data(let data):
            return data
        @unknown default:
            throw TransportError.unsupportedFrame
        }
    }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}

public enum TransportError: Error, Equatable {
    case notOpen
    case unsupportedFrame
}
