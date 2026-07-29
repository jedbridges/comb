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

    /// The response shape the callback returns.
    private struct InvoiceResponse: Decodable {
        let pr: String
        /// LUD-21. Where to ask later whether this invoice was paid. Optional,
        /// and plenty of hosts do not implement it.
        let verify: String?
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
    ) async throws -> Invoice {
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

        guard let decoded = try? JSONDecoder().decode(InvoiceResponse.self, from: data),
              !decoded.pr.isEmpty
        else { throw Failure.malformedInvoice }

        return Invoice(
            bolt11: decoded.pr,
            verify: Self.verifyURL(decoded.verify, sameHostAs: endpoint.callback)
        )
    }

    /// A payable invoice, and where to ask whether it was paid.
    public struct Invoice: Equatable, Sendable {
        public let bolt11: String
        /// Nil when the host does not implement LUD-21, or offered one Comb
        /// declined to use.
        public let verify: URL?
    }

    /// Accepts a LUD-21 verify URL only if it is https and on the same host as
    /// the callback that produced the invoice.
    ///
    /// LUD-21 says nothing about the URL's host, which means a wallet host can
    /// name any address in the world and, without this, Comb would poll it.
    /// That is a request to a host nobody chose, made on a timer, which is the
    /// definition of a bug in this app. Pinning it to the callback's host costs
    /// nothing real: a provider verifying its own invoices is already that
    /// host, and one that is not can simply not be polled.
    ///
    /// Same rule `BlossomClient` applies before signing for a media host, for
    /// the same reason.
    static func verifyURL(_ raw: String?, sameHostAs callback: URL) -> URL? {
        guard let raw, let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased(),
              host == callback.host()?.lowercased()
        else { return nil }
        return url
    }

    /// What a `verify` poll came back with.
    public enum Settlement: Equatable, Sendable {
        /// Paid, with the preimage that proves it.
        case settled(preimage: String)
        /// Answered, and the invoice is not paid yet.
        case unsettled
        /// No usable answer: no verify URL, unreachable, or a reply Comb could
        /// not read. Deliberately not an error. A zap whose settlement cannot
        /// be confirmed is the normal case on a host without LUD-21, and it
        /// costs the attestation, never the payment.
        case unknown
    }

    private struct VerifyResponse: Decodable {
        let settled: Bool?
        let preimage: String?
    }

    /// Asks once whether an invoice has been paid.
    public func settlement(of verify: URL) async -> Settlement {
        var request = URLRequest(url: verify, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              Self.lnurlError(in: data) == nil,
              let decoded = try? JSONDecoder().decode(VerifyResponse.self, from: data)
        else { return .unknown }

        // Both have to be there. LUD-21 sends `settled: false` with a null
        // preimage, and a host that sends a preimage without saying it settled
        // is not making the claim the preimage would be proof of.
        guard decoded.settled == true, let preimage = decoded.preimage,
              !preimage.isEmpty
        else { return decoded.settled == false ? .unsettled : .unknown }

        return .settled(preimage: preimage)
    }

    /// Waits for an invoice to settle, or gives up.
    ///
    /// Bounded on purpose, and short. A wallet handoff either happens in the
    /// minute after the reader leaves for their wallet or it does not happen at
    /// all, and a poll that ran for an hour would be a background timer against
    /// a third party's host on behalf of a payment that was probably abandoned.
    /// Giving up returns `.unknown`, which costs the attestation and nothing
    /// else: the money already moved or it did not, entirely without Comb.
    ///
    /// The delays widen rather than repeating, because the first seconds are
    /// when a Lightning payment normally settles and the later ones are just
    /// hope.
    public func awaitSettlement(
        of verify: URL,
        delays: [Duration] = [
            .seconds(2), .seconds(3), .seconds(5), .seconds(10), .seconds(20),
        ]
    ) async -> Settlement {
        for delay in delays {
            try? await Task.sleep(for: delay)
            if Task.isCancelled { return .unknown }

            switch await settlement(of: verify) {
            case .settled(let preimage): return .settled(preimage: preimage)
            // Keep waiting on both. `unknown` covers a host that blinked, and
            // one bad answer is not a reason to abandon a payment that may
            // still be in flight.
            case .unsettled, .unknown: continue
            }
        }
        return .unknown
    }

    /// The full path from an address to a payable invoice, for the common case.
    /// Returns the invoice plus the endpoint's issuer key, which the caller
    /// needs to verify the eventual receipt.
    public func prepareZap(
        to address: Zap.LightningAddress,
        amountMillisats: Int64,
        zapRequest: NostrEvent
    ) async throws -> (invoice: Invoice, issuer: PublicKey) {
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
