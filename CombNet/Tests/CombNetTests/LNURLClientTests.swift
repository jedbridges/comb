import CombCore
import Foundation
import Testing
@testable import CombNet

@Suite("LNURL client", .timeLimit(.minutes(1)), .serialized)
struct LNURLClientTests {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var respond: (@Sendable (URLRequest) -> (Int, Data))?
        nonisolated(unsafe) static var lastURL: URL?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastURL = request.url
            let (status, body) = Self.respond?(request) ?? (500, Data())

            // A status of 0 means the host never answered. The stub fails the
            // load rather than returning a response, which is how a DNS or TLS
            // failure actually reaches URLSession, and is the only way to tell
            // "unreachable" apart from "answered with an error".
            guard status != 0 else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                return
            }

            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> LNURLClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return LNURLClient(session: URLSession(configuration: config))
    }

    private let wallet = try! PrivateKey()

    private var endpointJSON: Data {
        Data("""
        {"callback":"https://getalby.com/lnurl/pay","minSendable":1000,
         "maxSendable":100000000,"allowsNostr":true,
         "nostrPubkey":"\(wallet.publicKey.hex)"}
        """.utf8)
    }

    @Test("fetches and validates an endpoint")
    func fetchesEndpoint() async throws {
        Stub.respond = { _ in (200, self.endpointJSON) }
        let address = try #require(Zap.LightningAddress("jed@getalby.com"))

        let endpoint = try await makeClient().endpoint(for: address)
        #expect(endpoint.supportsNostrZaps)
        #expect(Stub.lastURL?.absoluteString
            == "https://getalby.com/.well-known/lnurlp/jed")
    }

    @Test("requests an invoice with the zap request in the query")
    func requestsInvoice() async throws {
        Stub.respond = { request in
            if request.url?.path.contains("lnurlp") == true {
                return (200, self.endpointJSON)
            }
            return (200, Data(#"{"pr":"lnbc210n1pjxyz..."}"#.utf8))
        }

        let sender = try PrivateKey()
        let recipient = try PrivateKey()
        let zapRequest = try Zap.request(
            amountMillisats: 21000,
            recipient: recipient.publicKey,
            relays: [URL(string: "wss://relay.example")!],
            with: sender
        )

        let (invoice, issuer) = try await makeClient().prepareZap(
            to: try #require(Zap.LightningAddress("jed@getalby.com")),
            amountMillisats: 21000,
            zapRequest: zapRequest
        )

        #expect(invoice == "lnbc210n1pjxyz...")
        #expect(issuer == wallet.publicKey)

        // The callback must carry both the amount and the signed request, or the
        // wallet cannot produce a verifiable receipt.
        let query = try #require(URLComponents(url: Stub.lastURL!, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "amount" && $0.value == "21000" })
        #expect(query.contains { $0.name == "nostr" })
    }

    @Test("refuses an endpoint that cannot sign receipts")
    func refusesPlainEndpoint() async throws {
        Stub.respond = { _ in
            (200, Data(#"{"callback":"https://x/pay","minSendable":1000,"maxSendable":1000000}"#.utf8))
        }
        let endpoint = try await makeClient().endpoint(
            for: try #require(Zap.LightningAddress("jed@x.com"))
        )

        let request = try Zap.request(
            amountMillisats: 1000,
            recipient: try PrivateKey().publicKey,
            relays: [],
            with: try PrivateKey()
        )
        await #expect(throws: LNURLClient.Failure.zapsUnsupported) {
            _ = try await makeClient().invoice(
                from: endpoint, zapRequest: request, amountMillisats: 1000
            )
        }
    }

    @Test("enforces the endpoint's amount range")
    func enforcesAmountRange() async throws {
        Stub.respond = { _ in (200, self.endpointJSON) }
        let endpoint = try await makeClient().endpoint(
            for: try #require(Zap.LightningAddress("jed@getalby.com"))
        )
        let request = try Zap.request(
            amountMillisats: 1,
            recipient: try PrivateKey().publicKey,
            relays: [],
            with: try PrivateKey()
        )

        await #expect(throws: LNURLClient.Failure.amountOutOfRange(min: 1000, max: 100000000)) {
            _ = try await makeClient().invoice(
                from: endpoint, zapRequest: request, amountMillisats: 1
            )
        }
    }

    @Test("tells an unreachable host apart from one that answered badly")
    func unreachableVersusRejected() async throws {
        Stub.respond = { _ in (0, Data()) }
        await #expect(throws: LNURLClient.Failure.endpointUnreachable) {
            _ = try await makeClient().endpoint(
                for: try #require(Zap.LightningAddress("jed@getalby.com"))
            )
        }

        Stub.respond = { _ in (404, Data()) }
        await #expect(throws: LNURLClient.Failure.endpointRejected(status: 404)) {
            _ = try await makeClient().endpoint(
                for: try #require(Zap.LightningAddress("jed@getalby.com"))
            )
        }
    }

    /// The case that matters most: LNURL returns its errors in the body, and
    /// endpoints routinely send them with a 200. Reading the status first
    /// turned the endpoint's own explanation into "malformed".
    @Test("reads an LNURL error sent with a 200")
    func lnurlErrorWithSuccessStatus() async throws {
        Stub.respond = { _ in
            (200, Data(#"{"status":"ERROR","reason":"Account is not active"}"#.utf8))
        }
        await #expect(throws: LNURLClient.Failure.endpointError(reason: "Account is not active")) {
            _ = try await makeClient().endpoint(
                for: try #require(Zap.LightningAddress("jed@getalby.com"))
            )
        }
    }

    @Test("reads an LNURL error from the invoice callback")
    func invoiceError() async throws {
        Stub.respond = { request in
            if request.url?.path.contains("lnurlp") == true {
                return (200, self.endpointJSON)
            }
            return (400, Data(#"{"status":"ERROR","reason":"Comment too long"}"#.utf8))
        }

        let zapRequest = try Zap.request(
            amountMillisats: 21000,
            recipient: try PrivateKey().publicKey,
            relays: [],
            with: try PrivateKey()
        )
        await #expect(throws: LNURLClient.Failure.invoiceError(reason: "Comment too long")) {
            _ = try await makeClient().prepareZap(
                to: try #require(Zap.LightningAddress("jed@getalby.com")),
                amountMillisats: 21000,
                zapRequest: zapRequest
            )
        }
    }

    /// `reason` is written by whoever runs the recipient's wallet host and is
    /// rendered in Comb's UI, so it must not be able to smuggle in line breaks
    /// or run to arbitrary length.
    @Test("flattens and clamps hostile error text")
    func sanitisesReason() async throws {
        // Escaped in the source so the JSON stays valid and the newlines are
        // real once decoded, which is what the sanitiser has to strip.
        let hostile = #"Denied.\n\n\n"# + String(repeating: "padding ", count: 60)
        Stub.respond = { _ in
            (200, Data(#"{"status":"ERROR","reason":"\#(hostile)"}"#.utf8))
        }

        do {
            _ = try await makeClient().endpoint(
                for: try #require(Zap.LightningAddress("jed@getalby.com"))
            )
            Issue.record("expected an endpoint error")
        } catch let LNURLClient.Failure.endpointError(reason) {
            #expect(!reason.contains("\n"))
            #expect(reason.count <= 120)
            #expect(reason.hasPrefix("Denied. padding"))
        }
    }

    /// An error body with no reason carries nothing worth reporting, so it must
    /// fall through to the status rather than surfacing an empty sentence.
    @Test("ignores an error body with no reason")
    func errorWithoutReason() async throws {
        Stub.respond = { _ in (503, Data(#"{"status":"ERROR"}"#.utf8)) }
        await #expect(throws: LNURLClient.Failure.endpointRejected(status: 503)) {
            _ = try await makeClient().endpoint(
                for: try #require(Zap.LightningAddress("jed@getalby.com"))
            )
        }
    }
}
