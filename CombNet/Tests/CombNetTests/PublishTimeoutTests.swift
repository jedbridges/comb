import CombCore
import CombNetTesting
import Foundation
import Testing

@testable import CombNet

/// A relay that takes an event and never answers.
///
/// This is not a hypothetical. It is what build 12 did to every reaction and
/// every direct message: `publish` suspended on a continuation that only an OK
/// frame resumes, so a relay that accepted the socket and stayed quiet stopped
/// the caller forever. From the outside it was a reaction that never appeared
/// and a spinner that never stopped.
@Suite("Publish timeout", .timeLimit(.minutes(1)))
struct PublishTimeoutTests {
    /// Answers the AUTH challenge so `waitForAuthentication` clears, then says
    /// nothing at all about published events.
    private func silentRelay() -> MockTransport {
        let transport = MockTransport()
        Task {
            await transport.setBehaviour { request, transport in
                if case .auth(let event) = request {
                    await transport.push("[\"OK\",\"\(event.id)\",true,\"\"]")
                }
                // An EVENT gets nothing back. That is the whole point.
            }
        }
        return transport
    }

    @Test("a relay that never answers fails the publish instead of hanging")
    func timesOut() async throws {
        let transport = silentRelay()
        let key = try PrivateKey()
        let session = RelaySession(
            url: URL(string: "wss://relay.example")!,
            signer: InMemorySigner(key),
            sink: RecordingSink(),
            transport: transport,
            publishTimeout: .milliseconds(200)
        )

        try await session.start()
        await transport.push("[\"AUTH\",\"challenge\"]")

        let event = try await NostrEvent.signed(
            kind: .groupChatMessage, content: "hello",
            tags: [["h", "room-1"]], with: key
        )

        // Without the watchdog this call never returns and the time limit on the
        // suite is what fails, which reads as a hung test rather than a bug.
        await #expect(throws: RelayError.timedOut) {
            _ = try await session.publish(event)
        }

        await session.stop()
    }

    @Test("an OK that arrives in time still wins, and the watchdog does not fire")
    func okBeatsTheWatchdog() async throws {
        let transport = MockTransport()
        await transport.setBehaviour { request, transport in
            switch request {
            case .auth(let event), .event(let event):
                await transport.push("[\"OK\",\"\(event.id)\",true,\"stored\"]")
            default:
                break
            }
        }

        let key = try PrivateKey()
        let session = RelaySession(
            url: URL(string: "wss://relay.example")!,
            signer: InMemorySigner(key),
            sink: RecordingSink(),
            transport: transport,
            // Short, so a watchdog that fired anyway would race and flake here
            // rather than passing quietly.
            publishTimeout: .milliseconds(500)
        )

        try await session.start()
        await transport.push("[\"AUTH\",\"challenge\"]")

        let event = try await NostrEvent.signed(
            kind: .groupChatMessage, content: "hello",
            tags: [["h", "room-1"]], with: key
        )
        #expect(try await session.publish(event) == "stored")

        await session.stop()
    }
}
