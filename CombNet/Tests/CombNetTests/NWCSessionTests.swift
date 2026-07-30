import CombCore
import CombNetTesting
import Foundation
import Testing

@testable import CombNet

/// The wallet conversation, end to end over a scripted socket.
///
/// Every case here is one a real wallet could put Comb in and none of them can
/// be arranged reliably against one: an empty balance, a revoked connection, a
/// settlement claimed without proof, an answer from the wrong key, and silence.
@Suite("NWC session", .timeLimit(.minutes(1)))
struct NWCSessionTests {
    @Test("a wallet that pays hands back the preimage")
    func pays() async throws {
        let wallet = try FakeWallet(behaviour: .pays(preimage: "aabbccdd", feesPaid: 3))
        await wallet.start()

        let outcome = try await wallet.session().pay("lnbc210n1xyz")
        #expect(outcome == .paid(preimage: "aabbccdd", feesPaid: 3))
    }

    @Test("the invoice is not readable by the relay carrying it")
    func invoiceIsEncrypted() async throws {
        let wallet = try FakeWallet()
        await wallet.start()
        _ = try await wallet.session().pay("lnbc210n1secret")

        // The socket saw the request. It must not have seen the invoice.
        let transport = await wallet.sentFramesForTesting()
        #expect(!transport.contains("lnbc210n1secret"))
        #expect(transport.contains("23194"))
    }

    /// The subscription goes out before the publish. A wallet can answer faster
    /// than a second round trip, so the other order loses the response on
    /// exactly the fast wallets and looks like a timeout rather than a race.
    @Test("it subscribes for the answer before asking the question")
    func subscribesFirst() async throws {
        let wallet = try FakeWallet()
        await wallet.start()
        _ = try await wallet.session().pay("lnbc1")

        let types = await wallet.sentTypesForTesting()
        let req = try #require(types.firstIndex(of: "REQ"))
        let event = try #require(types.firstIndex(of: "EVENT"))
        #expect(req < event)
    }

    @Test("an empty balance comes back as the wallet's own refusal")
    func refuses() async throws {
        let wallet = try FakeWallet(
            behaviour: .refuses(code: "INSUFFICIENT_BALANCE", message: "balance is 3 sats")
        )
        await wallet.start()

        let outcome = try await wallet.session().pay("lnbc1")
        #expect(outcome == .refused(code: "INSUFFICIENT_BALANCE", message: "balance is 3 sats"))
    }

    @Test("a revoked connection is reported as one, not as a payment failure")
    func revoked() async throws {
        let wallet = try FakeWallet(behaviour: .refuses(code: "UNAUTHORIZED", message: ""))
        await wallet.start()

        let outcome = try await wallet.session().pay("lnbc1")
        #expect(outcome == .refused(code: "UNAUTHORIZED", message: ""))
    }

    /// A preimage is what Comb publishes as proof of payment, so a wallet that
    /// says it settled and offers nothing has claimed something unprovable.
    @Test("a settlement claimed without a preimage is refused")
    func unprovableSettlement() async throws {
        let wallet = try FakeWallet(behaviour: .claimsSettlementWithoutProof)
        await wallet.start()

        await #expect(throws: NWC.ResponseError.missingPreimage) {
            _ = try await wallet.session().pay("lnbc1")
        }
    }

    /// The case that matters most. Without the identity check, anyone on the
    /// wallet's relay could hand Comb a preimage and have it published as a
    /// payment the reader made.
    @Test("an answer from a key that is not the wallet is refused")
    func wrongKey() async throws {
        let wallet = try FakeWallet(behaviour: .answersAsSomeoneElse)
        await wallet.start()

        await #expect(throws: NWC.ResponseError.wrongWallet) {
            _ = try await wallet.session().pay("lnbc1")
        }
    }

    /// Not a refusal. The payment may well have happened, and reporting it as a
    /// failure would tell the reader something Comb does not know.
    @Test("silence times out rather than being read as a no")
    func silence() async throws {
        let wallet = try FakeWallet(behaviour: .silent)
        await wallet.start()

        await #expect(throws: NWCSession.Failure.timedOut) {
            _ = try await wallet.sessionWithShortDeadlineForTesting().pay("lnbc1")
        }
    }

    @Test("a socket that drops mid-exchange is reported as lost")
    func connectionLost() async throws {
        let wallet = try FakeWallet(behaviour: .silent)
        await wallet.start()
        let session = await wallet.session()

        // A Task rather than `async let`, which cannot be captured by the
        // expectation's closure.
        let paying = Task { try await session.pay("lnbc1") }
        try await Task.sleep(for: .milliseconds(80))
        await wallet.dropForTesting()

        await #expect(throws: NWCSession.Failure.connectionLost) {
            _ = try await paying.value
        }
    }
}

/// Whether Comb will talk to this wallet at all, checked once when connecting
/// rather than at the moment somebody tries to pay.
@Suite("NWC reachability", .timeLimit(.minutes(1)))
struct NWCReachabilityTests {
    @Test("a wallet advertising nip44 is reachable")
    func reachable() async throws {
        let wallet = try FakeWallet(encryption: "nip44_v2 nip04")
        await wallet.start()
        await #expect(throws: Never.self) { try await wallet.session().checkReachable() }
    }

    /// NIP-47 says a missing `encryption` tag means nip04 only, and Comb does
    /// not implement nip04. Refused here, when the reader is pasting a URI and
    /// can be told why, rather than when they are trying to pay a person.
    @Test("a wallet that can only do nip04 is refused when connecting")
    func nip04Only() async throws {
        for advertised in [nil, "nip04"] {
            let wallet = try FakeWallet(encryption: advertised)
            await wallet.start()
            await #expect(throws: NWCSession.Failure.encryptionUnsupported) {
                try await wallet.session().checkReachable()
            }
        }
    }

    @Test("a relay with no wallet on it is reported as having none")
    func noWallet() async throws {
        let wallet = try FakeWallet(publishesInfo: false)
        await wallet.start()
        await #expect(throws: NWCSession.Failure.noWalletFound) {
            try await wallet.session().checkReachable()
        }
    }
}
