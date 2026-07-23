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

    @Test("surfaces an unreachable endpoint")
    func unreachable() async throws {
        Stub.respond = { _ in (404, Data()) }
        await #expect(throws: LNURLClient.Failure.endpointUnreachable) {
            _ = try await makeClient().endpoint(
                for: try #require(Zap.LightningAddress("jed@getalby.com"))
            )
        }
    }
}
