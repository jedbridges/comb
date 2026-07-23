import CombCore
import Foundation

/// Talks to LNURL-pay endpoints to turn a zap into a payable invoice.
///
/// Comb never holds funds. This client fetches the recipient's endpoint,
/// requests an invoice for a signed zap request, and hands back a `bolt11`
/// string for the OS to route to a Lightning wallet. Paying is the wallet's
/// job, and Comb only ever sees the invoice, never a spend key.
public struct LNURLClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public enum Failure: Error, Equatable {
        case noLightningAddress
        case endpointUnreachable
        case malformedEndpoint
        /// The endpoint cannot produce a verifiable Nostr receipt.
        case zapsUnsupported
        case amountOutOfRange(min: Int64, max: Int64)
        case invoiceRequestFailed
        case malformedInvoice
    }

    /// Fetches and validates a recipient's LNURL-pay endpoint.
    public func endpoint(for address: Zap.LightningAddress) async throws -> Zap.PayEndpoint {
        guard let url = address.lnurlpURL else { throw Failure.noLightningAddress }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { throw Failure.endpointUnreachable }

        guard let endpoint = try? JSONDecoder().decode(Zap.PayEndpoint.self, from: data) else {
            throw Failure.malformedEndpoint
        }
        return endpoint
    }

    /// The response shape the callback returns: just the invoice, in practice.
    private struct InvoiceResponse: Decodable {
        let pr: String
    }

    /// Requests a bolt11 invoice for a signed zap request.
    ///
    /// The zap request rides in the query so the wallet can embed it in the
    /// receipt it signs; that embedding is what later makes the payment
    /// verifiable rather than an anonymous transfer.
    public func invoice(
        from endpoint: Zap.PayEndpoint,
        zapRequest: NostrEvent,
        amountMillisats: Int64
    ) async throws -> String {
        guard endpoint.supportsNostrZaps else { throw Failure.zapsUnsupported }
        guard amountMillisats >= endpoint.minSendable,
              amountMillisats <= endpoint.maxSendable
        else {
            throw Failure.amountOutOfRange(
                min: endpoint.minSendable,
                max: endpoint.maxSendable
            )
        }

        guard var components = URLComponents(
            url: endpoint.callback,
            resolvingAgainstBaseURL: false
        ) else { throw Failure.malformedEndpoint }

        let requestJSON = String(
            decoding: try JSONEncoder().encode(zapRequest),
            as: UTF8.self
        )
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "amount", value: String(amountMillisats)))
        query.append(URLQueryItem(name: "nostr", value: requestJSON))
        components.queryItems = query

        guard let url = components.url else { throw Failure.malformedEndpoint }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { throw Failure.invoiceRequestFailed }

        guard let invoice = try? JSONDecoder().decode(InvoiceResponse.self, from: data),
              !invoice.pr.isEmpty
        else { throw Failure.malformedInvoice }

        return invoice.pr
    }

    /// The full path from an address to a payable invoice, for the common case.
    /// Returns the invoice plus the endpoint's issuer key, which the caller
    /// needs to verify the eventual receipt.
    public func prepareZap(
        to address: Zap.LightningAddress,
        amountMillisats: Int64,
        zapRequest: NostrEvent
    ) async throws -> (invoice: String, issuer: PublicKey) {
        let endpoint = try await endpoint(for: address)
        guard let issuerHex = endpoint.nostrPubkey,
              let issuer = PublicKey(hex: issuerHex)
        else { throw Failure.zapsUnsupported }

        let invoice = try await invoice(
            from: endpoint,
            zapRequest: zapRequest,
            amountMillisats: amountMillisats
        )
        return (invoice, issuer)
    }
}
