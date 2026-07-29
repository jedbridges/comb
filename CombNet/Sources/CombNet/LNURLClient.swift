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

    /// A recipient's wallet host is asked on a session that keeps nothing.
    ///
    /// The same reasoning that moved third-party pictures off `URLSession.shared`
    /// applies here, and more sharply. That session accepts cookies into the
    /// shared persistent store and caches by ETag, so a wallet provider could
    /// set one on the first zap and have it handed back on every later zap to
    /// anyone they host, across launches and across communities. The provider
    /// is meant to learn an IP address and that somebody is paying this person;
    /// a cookie would let them link those payments into one identity over time,
    /// which is a different and worse thing, and it is not what PRIVACY.md says
    /// happens.
    ///
    /// Nothing here is worth caching in any case: an lnurlp document is small
    /// and an invoice must never be served from a cache.
    public static let anonymous: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    public init(session: URLSession = LNURLClient.anonymous) {
        self.session = session
    }

    /// Why a zap could not be turned into an invoice.
    ///
    /// The cases are deliberately fine grained. A zap crosses a third party's
    /// host, so there are half a dozen genuinely different ways it fails and
    /// the reader can act on most of them: a wrong amount is theirs to fix, an
    /// unreachable host is not. Collapsing them into one case throws away the
    /// only information the failure had.
    public enum Failure: Error, Equatable {
        case noLightningAddress
        /// The host never answered: DNS, TLS, timeout, no route.
        case endpointUnreachable
        /// The host answered the lnurlp request with a non-200.
        case endpointRejected(status: Int)
        /// The host returned LNURL's own error shape. `reason` is its text.
        case endpointError(reason: String)
        case malformedEndpoint
        /// The endpoint cannot produce a verifiable Nostr receipt.
        case zapsUnsupported
        case amountOutOfRange(min: Int64, max: Int64)
        /// The callback host never answered.
        case invoiceUnreachable
        case invoiceRejected(status: Int)
        case invoiceError(reason: String)
        case malformedInvoice
    }

    /// LNURL's error shape.
    ///
    /// Endpoints return this with an HTTP 200 as often as with an error status,
    /// so it has to be tried before the success shape on every response
    /// regardless of the status. Reading the status first is how the endpoint's
    /// own explanation ends up reported as "malformed".
    private struct ErrorResponse: Decodable {
        let status: String
        let reason: String?
    }

    /// The endpoint's error text, if this body is one.
    ///
    /// Returns nil when the body is not an LNURL error or carries no reason,
    /// so the caller falls through to the status and decode checks rather than
    /// reporting an error with nothing in it.
    private static func lnurlError(in data: Data) -> String? {
        guard let error = try? JSONDecoder().decode(ErrorResponse.self, from: data),
              error.status.caseInsensitiveCompare("ERROR") == .orderedSame,
              let reason = error.reason.map(sanitized), !reason.isEmpty
        else { return nil }
        return reason
    }

    /// Makes third-party text safe to render.
    ///
    /// `reason` is written by whoever runs the recipient's wallet host, and it
    /// ends up in a sheet in Comb. Collapse the whitespace so it cannot forge
    /// line breaks or blank space around itself, and clamp the length so it
    /// cannot push Comb's own words off the screen.
    private static func sanitized(_ reason: String) -> String {
        let flat = reason.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= 120 ? flat : flat.prefix(119) + "…"
    }

    /// Fetches and validates a recipient's LNURL-pay endpoint.
    public func endpoint(for address: Zap.LightningAddress) async throws -> Zap.PayEndpoint {
        guard let url = address.lnurlpURL else { throw Failure.noLightningAddress }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data, status: Int
        do {
            let (body, response) = try await session.data(for: request)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw Failure.endpointUnreachable
        }

        if let reason = Self.lnurlError(in: data) {
            throw Failure.endpointError(reason: reason)
        }
        guard status == 200 else { throw Failure.endpointRejected(status: status) }

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

        let data: Data, status: Int
        do {
            let (body, response) = try await session.data(for: request)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw Failure.invoiceUnreachable
        }

        // This is the response most worth reading properly: a callback that
        // refuses is usually refusing for a reason it has spelled out, like a
        // comment that is too long or an amount its own advertised range did
        // not actually allow.
        if let reason = Self.lnurlError(in: data) {
            throw Failure.invoiceError(reason: reason)
        }
        guard status == 200 else { throw Failure.invoiceRejected(status: status) }

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
