import CombCore
import CombNet
import Foundation

/// What a contract case is run against.
///
/// The point of the indirection is that the cases are written once. Today the
/// only implementation is `BuzzFake`; the reason the seam exists is that a fake
/// proves the client agrees with our model of the relay, and only a real relay
/// proves the model is right. A suite that could not be pointed at both would
/// have to be rewritten to find that out, which in practice means never.
///
/// So the cases below never reach for the fake's internals to set something up.
/// A group is created by publishing 9007 and joined by publishing 9021, exactly
/// as the app does, because those are the only moves that work against both.
public struct RelayUnderTest: Sendable {
    public let name: String
    public let url: URL
    public let transport: any WebSocketTransport
    /// Present only when the relay under test is the fake. Cases that use it
    /// are proving something about the suite rather than about the client, and
    /// skip when it is nil.
    public let fake: BuzzFake?

    public static func fake(
        _ rules: BuzzFake.Rules = BuzzFake.Rules(),
        url: URL = URL(string: "wss://fake.communities.buzz.xyz")!
    ) throws -> RelayUnderTest {
        let relay = try BuzzFake(rules: rules)
        return RelayUnderTest(name: "BuzzFake", url: url, transport: relay, fake: relay)
    }

    /// Stage 6 points this at `ghcr.io/block/buzz` in Docker. It exists now so
    /// the cases are written against a factory rather than against the fake,
    /// which is the whole difference between a suite that can be aimed at a
    /// real relay later and one that cannot.
    public static func live(url: URL) -> RelayUnderTest {
        RelayUnderTest(name: "live", url: url, transport: URLSessionTransport(), fake: nil)
    }

    /// A session connected and authenticated, with a sink recording everything
    /// that arrives.
    public func connect(as key: PrivateKey) async throws -> (RelaySession, RecordingSink) {
        let sink = RecordingSink()
        let session = RelaySession(
            url: url,
            signer: InMemorySigner(key),
            sink: sink,
            transport: transport,
            policy: ReconnectPolicy(base: .milliseconds(1), cap: .milliseconds(1)),
            backoffSleep: { _ in }
        )
        try await session.start()
        try await waitUntil("authentication against \(name)") {
            await session.state == .ready
        }
        return (session, sink)
    }
}
