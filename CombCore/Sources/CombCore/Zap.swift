import Foundation

/// Lightning zaps (NIP-57): sending sats to another member and proving it.
///
/// Comb is never a wallet. It builds the request, hands the invoice to whatever
/// Lightning app the user has, and later verifies the receipt someone else's
/// wallet published. No custody, no balance, no spend key here.
public enum Zap {
    // MARK: - Recipient

    /// A Lightning address parsed from a profile's `lud16`.
    ///
    /// `name@host` resolves to the LNURL-pay endpoint
    /// `https://host/.well-known/lnurlp/name`, exactly like NIP-05 but for
    /// payments.
    public struct LightningAddress: Equatable, Sendable {
        public let name: String
        public let host: String

        public init?(_ address: String) {
            let parts = address.split(separator: "@", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let name = String(parts[0]), host = String(parts[1])
            guard !name.isEmpty, !host.isEmpty,
                  !host.contains("/"), host.contains(".")
            else { return nil }
            self.name = name
            self.host = host
        }

        public var lnurlpURL: URL? {
            URL(string: "https://\(host)/.well-known/lnurlp/\(name)")
        }
    }

    /// The LNURL-pay endpoint's advertised parameters.
    public struct PayEndpoint: Equatable, Sendable, Decodable {
        public let callback: URL
        public let minSendable: Int64
        public let maxSendable: Int64
        /// Present and non-nil only when the endpoint accepts Nostr zaps.
        public let allowsNostr: Bool?
        /// The pubkey the endpoint will sign receipts with.
        public let nostrPubkey: String?
        /// How long a comment the endpoint accepts. Absent or zero means none.
        public let commentAllowed: Int?

        enum CodingKeys: String, CodingKey {
            case callback, minSendable, maxSendable, allowsNostr, nostrPubkey
            case commentAllowed
        }

        /// Characters the endpoint will accept in a zap comment.
        ///
        /// Zero is a real answer, not a missing one: plenty of endpoints take
        /// no comment at all, and offering the field anyway means the invoice
        /// request is refused for a reason the reader never sees.
        public var allowedCommentLength: Int { commentAllowed ?? 0 }

        /// Whether this endpoint can produce a verifiable Nostr zap receipt, as
        /// opposed to only a plain Lightning payment.
        public var supportsNostrZaps: Bool {
            allowsNostr == true && nostrPubkey != nil
        }
    }

    // MARK: - Zap request (kind 9734)

    /// Builds the kind 9734 request that goes to the LNURL callback.
    ///
    /// This event is not published to a relay; it rides along with the invoice
    /// request and is echoed back inside the receipt the recipient's wallet
    /// eventually signs. Signing it proves the zap came from this account.
    public static func request(
        amountMillisats: Int64,
        recipient: PublicKey,
        relays: [URL],
        comment: String = "",
        eventID: String? = nil,
        with key: PrivateKey
    ) throws -> NostrEvent {
        var tags: [[String]] = [
            // NIP-57 encodes relays as one tag, relay urls following the name.
            ["relays"] + relays.map(\.absoluteString),
            ["amount", String(amountMillisats)],
            ["p", recipient.hex],
        ]
        if let eventID {
            tags.append(["e", eventID])
        }

        return try NostrEvent.signed(
            kind: .zapRequest,
            content: comment,
            tags: tags,
            with: key
        )
    }

    /// Signer-based overload, for the app where the key lives in an actor.
    public static func request(
        amountMillisats: Int64,
        recipient: PublicKey,
        relays: [URL],
        comment: String = "",
        eventID: String? = nil,
        with signer: some EventSigner
    ) async throws -> NostrEvent {
        var tags: [[String]] = [
            ["relays"] + relays.map(\.absoluteString),
            ["amount", String(amountMillisats)],
            ["p", recipient.hex],
        ]
        if let eventID { tags.append(["e", eventID]) }
        return try await signer.sign(kind: .zapRequest, content: comment, tags: tags)
    }

    // MARK: - Zap receipt (kind 9735)

    /// A zap receipt's contents, once its internal claims hold together.
    public struct Receipt: Equatable, Sendable {
        public let amountMillisats: Int64
        public let sender: PublicKey
        public let recipient: String
        public let targetEventID: String?
        public let comment: String
        public let receiptID: String
        /// The id of the embedded kind 9734. This is what ties a receipt back
        /// to the handoff the reader made, so a pending marker can stop being
        /// shown once its answer arrives.
        public let requestID: String
        /// The key that signed the receipt. Whether it is the *right* key is a
        /// separate question, answered by `verifyReceipt` where the endpoint's
        /// advertised key is known.
        public let issuer: String
        /// The payment string, unique per invoice. Deduplicating on it is what
        /// stops a genuine receipt being republished to count twice.
        public let bolt11: String
    }

    public enum ReceiptError: Error, Equatable {
        case notAReceipt
        case missingBolt11
        case missingRequest
        case requestInvalid
        case recipientMismatch
        case amountMismatch
        /// The receipt was not signed by the pubkey the LNURL endpoint promised.
        case wrongIssuer
    }

    /// Validates a kind 9735 receipt against the endpoint that should have
    /// issued it, and extracts what it attests.
    ///
    /// Two different questions live in here, and only one of them can be
    /// answered offline. `decodeReceipt` checks everything the receipt says
    /// about itself, which is fixed forever and needs nothing but the event.
    /// The issuer check needs the recipient's LNURL endpoint, an HTTPS fetch,
    /// and its answer can change when someone moves wallet provider. So the
    /// pure half runs at write time in the projector and this whole function
    /// runs at read time, where the endpoint's key is known.
    ///
    /// That split is the same shape as edits and deletions: record the claim,
    /// judge it where the evidence is.
    public static func verifyReceipt(
        _ receipt: NostrEvent,
        expectedIssuer: PublicKey
    ) throws -> Receipt {
        let decoded = try decodeReceipt(receipt)

        // The receipt must be signed by the LNURL endpoint's advertised key, not
        // by whoever relayed it. Without this, anyone can mint a request from a
        // key they own, sign their own receipt for it, and claim a payment that
        // never happened.
        guard decoded.issuer == expectedIssuer.hex else {
            throw ReceiptError.wrongIssuer
        }
        return decoded
    }

    /// Everything a receipt can be checked on without asking the network.
    ///
    /// What this establishes is narrower than it looks, and worth stating
    /// plainly: the embedded request is signed by the sender, so its amount,
    /// recipient, target and comment cannot be altered by anyone republishing
    /// it. What it does not establish is that the signer of the *receipt* was
    /// entitled to issue it, or that any payment occurred.
    public static func decodeReceipt(_ receipt: NostrEvent) throws -> Receipt {
        guard receipt.kind == .zapReceipt else { throw ReceiptError.notAReceipt }

        guard receipt.isValid else { throw ReceiptError.wrongIssuer }

        guard let bolt11 = receipt.firstValue(for: "bolt11") else {
            throw ReceiptError.missingBolt11
        }

        // The description tag carries the original signed zap request, and its
        // signature is what proves who sent the zap.
        guard let descriptionJSON = receipt.firstValue(for: "description"),
              let requestData = descriptionJSON.data(using: .utf8),
              let request = try? JSONDecoder().decode(NostrEvent.self, from: requestData)
        else { throw ReceiptError.missingRequest }

        guard request.kind == .zapRequest, request.isValid else {
            throw ReceiptError.requestInvalid
        }

        // The receipt's recipient must be the request's recipient: a wallet
        // cannot honestly issue a receipt redirecting the zap to someone else.
        let receiptRecipient = receipt.firstValue(for: "p")
        guard let sender = request.author,
              let requestRecipient = request.firstValue(for: "p"),
              receiptRecipient == requestRecipient
        else { throw ReceiptError.recipientMismatch }

        let amount = request.firstValue(for: "amount").flatMap { Int64($0) } ?? 0

        return Receipt(
            amountMillisats: amount,
            sender: sender,
            recipient: requestRecipient,
            targetEventID: request.firstValue(for: "e"),
            comment: request.content,
            receiptID: receipt.id,
            requestID: request.id,
            issuer: receipt.pubkey,
            bolt11: bolt11
        )
    }
}
