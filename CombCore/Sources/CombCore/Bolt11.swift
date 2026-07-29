import Foundation

/// Just enough of BOLT-11 to check a payment against the invoice that asked
/// for it.
///
/// Comb decodes an invoice for two facts and no others: the payment hash, so a
/// preimage can be checked against it, and the amount, so an attestation
/// cannot claim more than was actually asked for. Route hints, expiry,
/// description, fallback addresses and the node's own signature all belong to
/// the wallet that pays the invoice, and are skipped rather than parsed and
/// ignored. Comb is not routing anything.
///
/// This is a decoder and never an encoder. Comb does not mint invoices; it
/// receives them from a recipient's LNURL host and hands them to a wallet.
public enum Bolt11 {
    /// The two facts, and the timestamp that comes free with them.
    public struct Invoice: Equatable, Sendable {
        /// The SHA256 a preimage must hash to. This is the whole reason to
        /// decode: it turns "somebody says they paid" into something checkable.
        public let paymentHash: Data
        /// Nil for an open-amount invoice, which BOLT-11 allows.
        ///
        /// A zap must never accept one. An amount nobody committed to cannot
        /// be checked against the request that asked for it, so an attestation
        /// carrying an open invoice proves a payment of an unknown size, which
        /// is not a proof of the payment claimed.
        public let amountMillisats: Int64?
        /// Seconds since 1970, as the invoice states them.
        public let timestamp: Int64
    }

    public enum Failure: Error, Equatable {
        /// The human-readable part does not begin `ln`.
        case notAnInvoice
        /// Bad bech32, a truncated field, or a field running past the end.
        case malformed
        /// No `p` field. BOLT-11 requires one, so its absence is not a
        /// variation Comb should try to work around.
        case missingPaymentHash
        /// An amount that does not fit, or a pico amount that is not a whole
        /// number of millisatoshis.
        case unrepresentableAmount
    }

    /// BOLT-11: `timestamp` is 35 bits, so seven 5-bit words.
    private static let timestampWords = 7
    /// A 520-bit compact signature: 64 bytes of r||s plus a recovery byte.
    private static let signatureWords = 104
    /// The `p` field. Type is the charset index of "p", which is 1.
    private static let paymentHashType: UInt8 = 1
    /// 52 words is 260 bits: a 256-bit hash with four zero bits of padding.
    private static let paymentHashWords = 52

    public static func decode(_ invoice: String) throws -> Invoice {
        let prefix: String
        let words: [UInt8]
        do {
            (prefix, words) = try Bech32.decodeWords(invoice)
        } catch {
            throw Failure.malformed
        }

        guard prefix.hasPrefix("ln") else { throw Failure.notAnInvoice }
        let amount = try amountMillisats(humanReadable: prefix)

        guard words.count >= timestampWords + signatureWords else { throw Failure.malformed }

        var timestamp: Int64 = 0
        for word in words[0..<timestampWords] {
            timestamp = timestamp << 5 | Int64(word)
        }

        // Everything between the timestamp and the trailing signature is
        // tagged fields. Walking to a fixed end rather than to the end of the
        // string is what stops the signature being read as a field header.
        let fieldsEnd = words.count - signatureWords
        var paymentHash: Data?
        var cursor = timestampWords

        while cursor + 3 <= fieldsEnd {
            let type = words[cursor]
            let length = Int(words[cursor + 1]) << 5 | Int(words[cursor + 2])
            let start = cursor + 3
            guard start + length <= fieldsEnd else { throw Failure.malformed }

            // First `p` wins and the rest are skipped, which is what BOLT-11
            // says to do. Taking the last would let anyone append a second one
            // and change which payment an invoice appears to be for.
            if type == paymentHashType, length == paymentHashWords, paymentHash == nil {
                guard let bytes = Bech32.bytes(fromWords: Array(words[start..<start + length])),
                      bytes.count == 32
                else { throw Failure.malformed }
                paymentHash = Data(bytes)
            }

            // A zero-length field is legal and must still advance the cursor,
            // which the +3 does.
            cursor = start + length
        }

        guard let paymentHash else { throw Failure.missingPaymentHash }
        return Invoice(
            paymentHash: paymentHash,
            amountMillisats: amount,
            timestamp: timestamp
        )
    }

    /// The amount encoded in the human-readable part, in millisatoshis.
    ///
    /// The part is `ln`, then a currency prefix of letters, then an optional
    /// number with an optional multiplier letter. Splitting at the first digit
    /// works precisely because the currency is letters only and the amount
    /// starts with a digit.
    ///
    /// Done in integers throughout. One bitcoin is 10^11 millisatoshis, which
    /// fits an Int64 comfortably, and going through `Double` to divide by a
    /// multiplier is how an amount comes back a millisatoshi light.
    private static func amountMillisats(humanReadable: String) throws -> Int64? {
        let body = humanReadable.dropFirst(2)
        guard let firstDigit = body.firstIndex(where: isASCIIDigit) else {
            // No amount at all: an open invoice, payable for anything.
            return nil
        }
        guard body[body.startIndex..<firstDigit].allSatisfy(\.isLetter) else {
            throw Failure.malformed
        }

        var digits = body[firstDigit...]
        var multiplier: Character?
        if let last = digits.last, !isASCIIDigit(last) {
            multiplier = last
            digits = digits.dropLast()
        }
        guard !digits.isEmpty, digits.allSatisfy(isASCIIDigit),
              let value = Int64(digits)
        else { throw Failure.malformed }

        // Millisatoshis per whole unit of the multiplier.
        let scale: Int64
        switch multiplier {
        case nil: scale = 100_000_000_000
        case "m": scale = 100_000_000
        case "u": scale = 100_000
        case "n": scale = 100
        case "p":
            // A pico-bitcoin is a tenth of a millisatoshi, so only multiples of
            // ten are expressible. BOLT-11 says so, and rounding here would
            // invent a payment slightly different from the one made.
            guard value % 10 == 0 else { throw Failure.unrepresentableAmount }
            return value / 10
        default:
            throw Failure.malformed
        }

        let (product, overflowed) = value.multipliedReportingOverflow(by: scale)
        guard !overflowed else { throw Failure.unrepresentableAmount }
        return product
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// The amount parser on its own, for tests.
    ///
    /// Multipliers, overflow and the pico rounding rule are the fiddly half of
    /// this file, and every published vector uses only `u` and `m`. Reaching
    /// them through `decode` would mean encoding invoices, which would mean
    /// writing an encoder that exists purely to test the decoder and could
    /// agree with it about the same mistake.
    static func amountMillisatsForTesting(_ humanReadable: String) throws -> Int64? {
        try amountMillisats(humanReadable: humanReadable)
    }
}
