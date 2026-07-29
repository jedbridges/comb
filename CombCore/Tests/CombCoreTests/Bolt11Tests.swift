import Foundation
import Testing

@testable import CombCore

/// BOLT-11's own published test vectors.
///
/// Written out in full rather than reduced to a fixture, because the point of
/// them is that they were produced by somebody else's encoder. A decoder tested
/// only against invoices this repo made would agree with itself about a
/// misreading forever.
///
/// All four carry the same payment hash, which the spec gives in hex, so the
/// expected value is not something this test derived.
@Suite("BOLT-11 vectors")
struct Bolt11VectorTests {
    /// The `payment_hash` every vector below commits to.
    static let hash = "0001020304050607080900010203040506070809000102030405060708090102"

    static let noAmount = """
        lnbc1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rq\
        wzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6t\
        wvus8g6rfwvs8qun0dfjkxaq9qrsgq357wnc5r2ueh7ck6q93dj32dlqnls087fxdwk8qakdyafkq3yap9\
        us6v52vjjsrvywa6rt52cm9r9zqt8r2t7mlcwspyetp5h2tztugp9lfyql
        """

    static let microBitcoin = """
        lnbc2500u1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqc\
        yq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpu9qrsgquk0\
        rl77nj30yxdy8j9vdx85fkpmdla2087ne0xh8nhedh8w27kyke0lp53ut353s06fv3qfegext0eh0ymjpf\
        39tuven09sam30g4vgpfna3rh
        """

    static let milliBitcoin = """
        lnbc20m1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq\
        5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqhp58yjmdan79s6qqdhdzgynm4zwqd5d7xmw5fk9\
        8klysy043l2ahrqs9qrsgq7ea976txfraylvgzuxs8kgcw23ezlrszfnh8r6qtfpr6cxga50aj6txm9rxr\
        ydzd06dfeawfk6swupvz4erwnyutnjq7x39ymw6j38gp7ynn44
        """

    static let withMetadata = """
        lnbc25m1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5vdhkven9v\
        5sxyetpdeessp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygs9q5sqqqqqqqqqqqq\
        qqqqsgq2a25dxl5hrntdtn6zvydt7d66hyzsyhqs4wdynavys42xgl6sgx9c4g7me86a27t07mdtfry458\
        rtjr0v92cnmswpsjscgt2vcse3sgpz3uapa
        """

    @Test("an invoice for any amount decodes with no amount")
    func openAmount() throws {
        let invoice = try Bolt11.decode(Self.noAmount)
        #expect(invoice.paymentHash.hex == Self.hash)
        // Not zero. Zero is an amount somebody chose; nil is the absence of one,
        // and an attestation has to be able to refuse the second.
        #expect(invoice.amountMillisats == nil)
    }

    @Test("2500 micro-bitcoin is 250,000,000 millisatoshis")
    func micro() throws {
        let invoice = try Bolt11.decode(Self.microBitcoin)
        #expect(invoice.paymentHash.hex == Self.hash)
        #expect(invoice.amountMillisats == 250_000_000)
    }

    @Test("20 milli-bitcoin is 2,000,000,000 millisatoshis")
    func milli() throws {
        let invoice = try Bolt11.decode(Self.milliBitcoin)
        #expect(invoice.paymentHash.hex == Self.hash)
        #expect(invoice.amountMillisats == 2_000_000_000)
    }

    /// Carries an `m` metadata field and a nine-word feature field, so it also
    /// covers walking past tagged fields the decoder does not care about.
    @Test("unknown tagged fields are stepped over, not tripped on")
    func metadata() throws {
        let invoice = try Bolt11.decode(Self.withMetadata)
        #expect(invoice.paymentHash.hex == Self.hash)
        #expect(invoice.amountMillisats == 2_500_000_000)
    }

    @Test("an uppercase invoice decodes the same")
    func uppercase() throws {
        let invoice = try Bolt11.decode(Self.microBitcoin.uppercased())
        #expect(invoice.paymentHash.hex == Self.hash)
        #expect(invoice.amountMillisats == 250_000_000)
    }

    @Test("every vector agrees on the timestamp the spec encoded")
    func timestamps() throws {
        // 1496314658, the moment the vectors were written. Shared by all four,
        // which is the cheapest possible check that the 35-bit big-endian read
        // is not off by a word.
        for invoice in [Self.noAmount, Self.microBitcoin, Self.milliBitcoin, Self.withMetadata] {
            #expect(try Bolt11.decode(invoice).timestamp == 1_496_314_658)
        }
    }
}

/// What a hostile or broken invoice does. A decoder that reaches the zap path
/// is handed strings by a third party's wallet host, so refusing has to be
/// ordinary rather than exceptional.
@Suite("BOLT-11 refusals")
struct Bolt11RefusalTests {
    @Test("a bech32 string that is not an invoice is refused")
    func notAnInvoice() throws {
        // A valid npub: real bech32, wrong prefix.
        let npub = Bech32.encode(prefix: "npub", data: Data(repeating: 0xAB, count: 32))
        #expect(throws: Bolt11.Failure.notAnInvoice) { try Bolt11.decode(npub) }
    }

    @Test("a corrupted invoice fails its checksum rather than decoding to nonsense")
    func corrupted() throws {
        var broken = Array(Bolt11VectorTests.microBitcoin)
        // Swap a character in the data part for another in the charset, so it
        // stays decodable as bech32 and fails only on the checksum.
        broken[40] = broken[40] == "q" ? "p" : "q"
        #expect(throws: Bolt11.Failure.malformed) { try Bolt11.decode(String(broken)) }
    }

    @Test("nothing is not an invoice")
    func empty() throws {
        #expect(throws: Bolt11.Failure.self) { try Bolt11.decode("") }
        #expect(throws: Bolt11.Failure.self) { try Bolt11.decode("lnbc") }
    }

    @Test("a pico amount that is not a whole millisatoshi is refused, not rounded")
    func indivisiblePico() throws {
        // 1p is a tenth of a millisatoshi. Rounding it to 0 or 1 would make the
        // decoded amount a different payment from the one the invoice asked for.
        #expect(throws: Bolt11.Failure.unrepresentableAmount) {
            try Bolt11.amountMillisatsForTesting("lnbc1p")
        }
    }

    @Test("a pico amount that is a whole millisatoshi is kept exactly")
    func divisiblePico() throws {
        #expect(try Bolt11.amountMillisatsForTesting("lnbc10p") == 1)
        #expect(try Bolt11.amountMillisatsForTesting("lnbc2500u") == 250_000_000)
        #expect(try Bolt11.amountMillisatsForTesting("lnbc1") == 100_000_000_000)
        #expect(try Bolt11.amountMillisatsForTesting("lnbc") == nil)
    }

    @Test("an amount too large to represent is refused rather than wrapping")
    func overflow() throws {
        // Wrapping here would turn an absurd invoice into a plausible small one.
        #expect(throws: Bolt11.Failure.unrepresentableAmount) {
            try Bolt11.amountMillisatsForTesting("lnbc99999999999")
        }
    }

    @Test("an unknown multiplier is refused rather than guessed at")
    func unknownMultiplier() throws {
        #expect(throws: Bolt11.Failure.malformed) {
            try Bolt11.amountMillisatsForTesting("lnbc10k")
        }
    }

    @Test("the testnet and regtest prefixes are read like any other")
    func otherCurrencies() throws {
        #expect(try Bolt11.amountMillisatsForTesting("lntb20m") == 2_000_000_000)
        #expect(try Bolt11.amountMillisatsForTesting("lnbcrt20m") == 2_000_000_000)
    }
}
