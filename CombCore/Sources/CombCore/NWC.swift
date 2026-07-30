import Foundation

/// Nostr Wallet Connect (NIP-47): asking a wallet to pay an invoice.
///
/// This is the one place Comb's "never a wallet" line moves, and it moves less
/// than it looks. Comb still holds no balance and mints no invoices. What it
/// holds is a connection secret the wallet issued and the reader can revoke at
/// the wallet, which is a delegated permission to ask, not custody.
///
/// The reason to bother: a `lightning:` handoff leaves the app, cannot report
/// whether anything happened, and never learns the preimage. `pay_invoice`
/// returns the preimage, which is the first time Comb can honestly say a zap was
/// paid, and it is exactly what `Zap.attestation` needs to prove it to everyone
/// else.
///
/// **NIP-44 only, deliberately.** NIP-47 negotiates encryption and says that a
/// wallet advertising no `encryption` tag supports only NIP-04. Comb does not
/// implement NIP-04 and will not: it is AES-CBC with no authentication, so a
/// tampered ciphertext decrypts to garbage rather than being rejected, and it
/// leaks plaintext length. Adding an unauthenticated cipher to carry spend
/// authorisation to buy compatibility with older wallets is the wrong trade. A
/// wallet that cannot speak `nip44_v2` is refused, and told why.
public enum NWC {
    // MARK: - Connection

    /// A `nostr+walletconnect://` URI, as a wallet hands it over.
    ///
    /// The secret is a full private key: it signs the requests and derives the
    /// conversation key. It is the credential, so it belongs in the Keychain and
    /// never in `UserDefaults` beside the rest of this.
    public struct Connection: Sendable {
        /// The wallet service's pubkey. Requests are `p`-tagged to it and
        /// encrypted for it, and its responses are only accepted from it.
        public let walletPubkey: PublicKey
        /// Where the wallet service listens. NIP-47 allows more than one; the
        /// first reachable is enough, and Comb uses only the first.
        public let relays: [URL]
        public let secret: PrivateKey
        /// Optional in the URI, and only ever used to prefill a profile.
        public let lightningAddress: String?

        public init(
            walletPubkey: PublicKey,
            relays: [URL],
            secret: PrivateKey,
            lightningAddress: String? = nil
        ) {
            self.walletPubkey = walletPubkey
            self.relays = relays
            self.secret = secret
            self.lightningAddress = lightningAddress
        }
    }

    public enum ConnectionError: Error, Equatable {
        case notAWalletURI
        case malformedWalletPubkey
        case missingRelay
        /// A relay that is not `wss:` or `ws:`, or a `ws:` one that is not
        /// loopback. A spend credential does not travel in cleartext to a host
        /// on the internet.
        case insecureRelay
        case missingSecret
        case malformedSecret
    }

    /// Parses a connection URI.
    ///
    /// Hand-parsed rather than trusted to `URLComponents.host`, because the
    /// pubkey sits where a host goes and `URLComponents` lowercases it. Hex is
    /// case-insensitive so that happens to be harmless here, but relying on a
    /// component parser to leave a credential's neighbours alone is not a habit
    /// worth having.
    public static func connection(from uri: String) throws -> Connection {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        // Both spellings appear in the wild. The URI is pasted by a human from
        // a wallet's own screen, so refusing one of them would be refusing a
        // difference the reader cannot see.
        let schemes = ["nostr+walletconnect://", "nostrwalletconnect://"]
        guard let scheme = schemes.first(where: { trimmed.lowercased().hasPrefix($0) }) else {
            throw ConnectionError.notAWalletURI
        }

        let body = String(trimmed.dropFirst(scheme.count))
        let parts = body.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let walletPubkey = PublicKey(hex: String(parts[0])) else {
            throw ConnectionError.malformedWalletPubkey
        }

        // Parsed as part of a URL rather than assigned to `components.query`.
        // That setter treats its input as needing encoding, so a relay already
        // written as `wss%3A%2F%2F…` came back double-escaped and every URI in
        // the world looked like it named no relay.
        let query = parts.count > 1 ? String(parts[1]) : ""
        let items = URLComponents(string: "nwc://x?\(query)")?.queryItems ?? []

        func values(_ name: String) -> [String] {
            items.filter { $0.name == name }.compactMap(\.value).filter { !$0.isEmpty }
        }

        let relayStrings = values("relay")
        guard !relayStrings.isEmpty else { throw ConnectionError.missingRelay }
        let relays = try relayStrings.map { raw -> URL in
            guard let url = URL(string: raw), let host = url.host() else {
                throw ConnectionError.missingRelay
            }
            switch url.scheme?.lowercased() {
            case "wss":
                return url
            case "ws":
                // Loopback only, for a wallet running on this machine during
                // development. Anywhere else this is a spend credential over
                // cleartext.
                guard host == "localhost" || host == "127.0.0.1" || host == "::1" else {
                    throw ConnectionError.insecureRelay
                }
                return url
            default:
                throw ConnectionError.insecureRelay
            }
        }

        guard let secretHex = values("secret").first else { throw ConnectionError.missingSecret }
        guard let data = Hex.decode(secretHex), data.count == 32,
              let secret = try? PrivateKey(data: data)
        else { throw ConnectionError.malformedSecret }

        return Connection(
            walletPubkey: walletPubkey,
            relays: relays,
            secret: secret,
            lightningAddress: values("lud16").first
        )
    }

    // MARK: - Encryption negotiation

    /// The only scheme Comb speaks. See the type's own note for why NIP-04 is
    /// absent rather than merely unimplemented.
    public static let encryption = "nip44_v2"

    /// Whether a wallet's info event says it can speak NIP-44.
    ///
    /// NIP-47 is explicit that a missing `encryption` tag means NIP-04 only, so
    /// absence is a no rather than an unknown. That is the one place in this
    /// codebase where a missing field is read as a definite answer, and it is
    /// because the spec says to.
    public static func supportsNIP44(info: NostrEvent) -> Bool {
        guard info.kind == .nwcInfo else { return false }
        return info.values(for: "encryption")
            .flatMap { $0.split(separator: " ") }
            .contains { $0.lowercased() == encryption }
    }

    /// The methods a wallet says it supports, from its info event's content.
    public static func methods(info: NostrEvent) -> [String] {
        info.content.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: - Requests

    public enum Method: String, Sendable {
        case payInvoice = "pay_invoice"
        case getInfo = "get_info"
        case getBalance = "get_balance"
    }

    /// Builds an encrypted kind 23194.
    ///
    /// Signed by the connection secret, not by the reader's community identity.
    /// The wallet knows this connection by that key and nothing else, so a zap
    /// paid through it is not linkable to the pubkey posting in a community.
    public static func request(
        method: Method,
        params: [String: Any] = [:],
        connection: Connection
    ) throws -> NostrEvent {
        let body: [String: Any] = ["method": method.rawValue, "params": params]
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let key = try NIP44.conversationKey(
            privateKey: connection.secret,
            peer: connection.walletPubkey
        )
        let content = try NIP44.encrypt(String(decoding: json, as: UTF8.self), conversationKey: key)

        return try NostrEvent.signed(
            kind: .nwcRequest,
            content: content,
            tags: [
                ["p", connection.walletPubkey.hex],
                ["encryption", encryption],
            ],
            with: connection.secret
        )
    }

    /// A `pay_invoice` request for one bolt11.
    public static func payInvoice(
        _ bolt11: String,
        connection: Connection
    ) throws -> NostrEvent {
        try request(method: .payInvoice, params: ["invoice": bolt11], connection: connection)
    }

    // MARK: - Responses

    /// What a wallet said, once decrypted and unwrapped.
    public enum Outcome: Equatable, Sendable {
        /// The invoice settled, and this is the proof of it.
        case paid(preimage: String, feesPaid: Int64?)
        /// The wallet answered a non-payment method. Kept opaque: the only
        /// caller that needs the body is `get_info`, which reads it separately.
        case answered
        /// The wallet refused, in its own words. `code` is one of NIP-47's, and
        /// `message` is written by whoever runs the wallet.
        case refused(code: String, message: String)
    }

    public enum ResponseError: Error, Equatable {
        case notAResponse
        /// Signed by someone other than the wallet this connection names.
        case wrongWallet
        case badSignature
        case undecryptable
        case malformed
        /// The wallet said it settled and did not say with what, so there is
        /// nothing to prove it.
        case missingPreimage
    }

    /// Decrypts and unwraps a kind 23195.
    ///
    /// The issuer check is first and is not a formality. A response carries a
    /// preimage, and a preimage is what Comb will publish as proof of payment,
    /// so accepting one from any key that happened to answer would let a hostile
    /// relay participant hand Comb a payment to attest to.
    public static func outcome(
        of response: NostrEvent,
        connection: Connection
    ) throws -> Outcome {
        guard response.kind == .nwcResponse else { throw ResponseError.notAResponse }
        guard response.pubkey == connection.walletPubkey.hex else {
            throw ResponseError.wrongWallet
        }
        guard response.isValid else { throw ResponseError.badSignature }

        let key = try NIP44.conversationKey(
            privateKey: connection.secret,
            peer: connection.walletPubkey
        )
        guard let plaintext = try? NIP44.decrypt(response.content, conversationKey: key),
              let data = plaintext.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ResponseError.undecryptable }

        // Checked before the result, because NIP-47 sends both keys with one of
        // them null and a wallet that refused has still filled in `result_type`.
        if let error = body["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "OTHER"
            let message = error["message"] as? String ?? ""
            return .refused(code: code, message: Self.sanitized(message))
        }

        guard let resultType = body["result_type"] as? String else {
            throw ResponseError.malformed
        }
        guard resultType == Method.payInvoice.rawValue else { return .answered }

        guard let result = body["result"] as? [String: Any] else {
            throw ResponseError.malformed
        }
        guard let preimage = result["preimage"] as? String, !preimage.isEmpty,
              Hex.decode(preimage) != nil
        else { throw ResponseError.missingPreimage }

        let fees = (result["fees_paid"] as? NSNumber)?.int64Value
        return .paid(preimage: preimage, feesPaid: fees)
    }

    /// Makes a wallet's own words safe to render.
    ///
    /// The same treatment `LNURLClient` gives an LNURL reason, for the same
    /// reason: this text is written by whoever runs the wallet and ends up in a
    /// sheet in Comb, so it must not be able to forge line breaks or push Comb's
    /// own words off the screen.
    static func sanitized(_ message: String) -> String {
        let flat = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= 120 ? flat : flat.prefix(119) + "…"
    }

    /// A refusal in words a reader can act on.
    ///
    /// Worth being exhaustive rather than printing the code: `INSUFFICIENT_BALANCE`
    /// is the reader's to fix and `INTERNAL` is not, and a screen that showed
    /// both as "the wallet said no" would waste the only information the failure
    /// carried. The wallet's own message is appended where it has one, because it
    /// is usually more specific than anything Comb can say.
    public static func describe(code: String, message: String) -> String {
        let sentence: String
        switch code.uppercased() {
        case "INSUFFICIENT_BALANCE":
            sentence = "Your wallet does not have enough to cover this."
        case "QUOTA_EXCEEDED":
            sentence = "This connection has spent as much as it is allowed to."
        case "RATE_LIMITED":
            sentence = "Your wallet is asking you to slow down."
        case "PAYMENT_FAILED":
            sentence = "The payment did not go through."
        case "UNAUTHORIZED", "RESTRICTED":
            sentence = "Your wallet refused this connection. It may have been revoked."
        case "NOT_IMPLEMENTED", "NOT_FOUND":
            sentence = "Your wallet cannot do this."
        case "UNSUPPORTED_ENCRYPTION":
            sentence = "Your wallet and Comb could not agree on how to talk securely."
        default:
            sentence = "Your wallet could not pay this."
        }
        return message.isEmpty ? sentence : "\(sentence) It said: \(message)"
    }
}
