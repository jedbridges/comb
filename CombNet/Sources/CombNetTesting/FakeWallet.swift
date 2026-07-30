import CombCore
import CombNet
import Foundation

/// A wallet service on the other end of a `MockTransport`.
///
/// Pins Comb's model of NIP-47 the way `BuzzFake` pins its model of the relay.
/// Everything a wallet can do to this app is expressible here in a line: pay,
/// refuse, claim a settlement it cannot prove, answer as the wrong key, or say
/// nothing at all. Those are the cases that matter, and none of them can be
/// arranged reliably against a real wallet.
public actor FakeWallet {
    /// How this wallet behaves when asked to pay.
    public enum Behaviour: Sendable {
        case pays(preimage: String, feesPaid: Int64?)
        case refuses(code: String, message: String)
        /// Says it settled and offers no preimage, so the claim is unprovable.
        case claimsSettlementWithoutProof
        /// Answers, but signed by a different key. A response carries the
        /// preimage Comb will publish as proof, so this is the case that
        /// matters most.
        case answersAsSomeoneElse
        /// Never answers. Not a refusal: the payment may still have happened.
        case silent

        public static var pays: Behaviour { .pays(preimage: "aabbccdd", feesPaid: 0) }
    }

    public let key: PrivateKey
    public let connection: NWC.Connection
    private let transport: MockTransport
    private var behaviour: Behaviour
    /// What the wallet advertises in its info event. Nil means no `encryption`
    /// tag at all, which NIP-47 says means nip04 only.
    private var encryption: String?
    private var publishesInfo: Bool

    public init(
        behaviour: Behaviour = .pays,
        encryption: String? = "nip44_v2",
        publishesInfo: Bool = true,
        transport: MockTransport = MockTransport()
    ) throws {
        self.key = try PrivateKey()
        self.transport = transport
        self.behaviour = behaviour
        self.encryption = encryption
        self.publishesInfo = publishesInfo
        self.connection = NWC.Connection(
            walletPubkey: key.publicKey,
            relays: [URL(string: "wss://wallet.example")!],
            secret: try PrivateKey()
        )
    }

    /// A session wired to this wallet, with the challenge grace skipped so tests
    /// are not the wait.
    public func session() -> NWCSession {
        NWCSession(
            connection: connection,
            transport: transport,
            challengeSleep: { _ in }
        )
    }

    /// Starts answering. Call before driving the session.
    public func start() async {
        let wallet = self
        await transport.setBehaviour { request, transport in
            await wallet.handle(request, on: transport)
        }
    }

    public func set(behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    // MARK: - Inspection

    /// A session whose deadline is short enough that a test can wait it out.
    /// Only the timeout differs; the rest is the production path.
    public func sessionWithShortDeadlineForTesting() -> NWCSession {
        NWCSession(
            connection: connection,
            transport: transport,
            challengeSleep: { _ in },
            responseTimeout: .milliseconds(150)
        )
    }

    /// Everything the client put on the socket, as one string.
    ///
    /// Deliberately raw: the point of the assertion using it is that an invoice
    /// does not appear anywhere in what the relay saw, and decoding first would
    /// let a leak in an unexamined field pass.
    public func sentFramesForTesting() async -> String {
        await transport.sentFrames.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
    }

    public func sentTypesForTesting() async -> [String] {
        await transport.sent().map(\.type)
    }

    public func dropForTesting() async {
        await transport.drop()
    }

    // MARK: - Answering

    private func handle(_ request: RelayRequest, on transport: MockTransport) async {
        switch request {
        case .req(let id, let filters):
            // An info lookup and a response subscription are told apart by the
            // kind asked for, the same way the wallet would.
            guard filters.contains(where: { $0.kinds?.contains(.nwcInfo) == true }) else { return }
            if publishesInfo, let info = try? info() {
                try? await transport.push(event: info, subscription: id)
            }
            await transport.push("[\"EOSE\",\"\(id)\"]")

        case .event(let event):
            guard event.kind == .nwcRequest else { return }
            await answer(event, on: transport)

        default:
            return
        }
    }

    private func answer(_ request: NostrEvent, on transport: MockTransport) async {
        guard case .silent = behaviour else {
            let body: [String: Any]
            var signer = key

            switch behaviour {
            case .pays(let preimage, let fees):
                var result: [String: Any] = ["preimage": preimage]
                if let fees { result["fees_paid"] = fees }
                body = ["result_type": "pay_invoice", "result": result]
            case .refuses(let code, let message):
                body = [
                    "result_type": "pay_invoice",
                    "error": ["code": code, "message": message],
                ]
            case .claimsSettlementWithoutProof:
                body = ["result_type": "pay_invoice", "result": [:] as [String: Any]]
            case .answersAsSomeoneElse:
                body = [
                    "result_type": "pay_invoice",
                    "result": ["preimage": "deadbeef"],
                ]
                signer = (try? PrivateKey()) ?? key
            case .silent:
                return
            }

            guard let response = try? reply(body, to: request, as: signer) else { return }
            // The subscription id the session used, derived the same way.
            let subscription = "nwc-\(request.id.prefix(8))"
            try? await transport.push(event: response, subscription: subscription)
            return
        }
    }

    private func reply(
        _ body: [String: Any],
        to request: NostrEvent,
        as signer: PrivateKey
    ) throws -> NostrEvent {
        let json = try JSONSerialization.data(withJSONObject: body)
        // Encrypted for the connection either way: a response from the wrong key
        // must fail the identity check rather than merely fail to decrypt, or the
        // test proves the weaker thing.
        let conversationKey = try NIP44.conversationKey(
            privateKey: signer,
            peer: connection.secret.publicKey
        )
        return try NostrEvent.signed(
            kind: .nwcResponse,
            content: try NIP44.encrypt(
                String(decoding: json, as: UTF8.self),
                conversationKey: conversationKey
            ),
            tags: [["p", connection.secret.publicKey.hex], ["e", request.id]],
            with: signer
        )
    }

    private func info() throws -> NostrEvent {
        var tags: [[String]] = []
        if let encryption { tags.append(["encryption", encryption]) }
        return try NostrEvent.signed(
            kind: .nwcInfo,
            content: "pay_invoice get_balance get_info",
            tags: tags,
            with: key
        )
    }
}
