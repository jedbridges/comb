import CombCore
import Foundation
import Testing
@testable import CombNet

/// A scripted Buzz desktop: the source side of NIP-AB, built from the same
/// CombCore primitives, driving a PairingSession through the mock transport.
/// The whole handshake runs with no relay, no camera, and no timing luck.
actor FakeDesktop {
    let key: PrivateKey
    let sessionSecret: Data
    let transport: MockTransport

    /// The offer's decoded fields, in Sendable form so tests can assert on them.
    struct Offer: Sendable, Equatable {
        let type: String
        let version: Int
        let sessionID: String
    }

    private(set) var offer: Offer?
    private(set) var targetPubkey: PublicKey?
    private(set) var receivedComplete = false
    private(set) var receivedAbortReason: String?

    init(transport: MockTransport) throws {
        self.key = try PrivateKey()
        self.sessionSecret = Data((0..<32).map { _ in UInt8.random(in: 1...255) })
        self.transport = transport
    }

    var invitationURI: String {
        "nostrpair://\(key.publicKey.hex)?secret=\(sessionSecret.hex)"
            + "&relay=wss%3A%2F%2Fpairing.buzz.xyz&v=1"
    }

    /// Reads the phone's offer off the wire and learns its ephemeral identity.
    @discardableResult
    func consumeOffer() async throws -> Offer {
        let transport = transport
        try await waitUntil("offer") {
            await !transport.sent(ofType: "EVENT").isEmpty
        }
        let event = try #require(await transport.sent(ofType: "EVENT").first?.event)

        let ephemeral = try #require(PublicKey(hex: event.pubkey))
        targetPubkey = ephemeral

        let conversationKey = try NIP44.conversationKey(privateKey: key, peer: ephemeral)
        let decrypted = try NIP44.decrypt(event.content, conversationKey: conversationKey)
        let object = try JSONSerialization.jsonObject(with: Data(decrypted.utf8)) as? [String: Any]
        let offer = Offer(
            type: object?["type"] as? String ?? "",
            version: object?["version"] as? Int ?? 0,
            sessionID: object?["session_id"] as? String ?? ""
        )
        self.offer = offer
        return offer
    }

    /// Sends a NIP-AB message to the phone, encrypted and signed properly.
    func send(_ message: [String: Any], signedBy signer: PrivateKey? = nil) async throws {
        let target = try #require(targetPubkey)
        let sender = signer ?? key
        let conversationKey = try NIP44.conversationKey(privateKey: sender, peer: target)

        let json = try JSONSerialization.data(withJSONObject: message)
        let event = try NostrEvent.signed(
            kind: EventKind(rawValue: 24134),
            content: try NIP44.encrypt(
                String(decoding: json, as: UTF8.self),
                conversationKey: conversationKey
            ),
            tags: [["p", target.hex]],
            with: sender
        )
        try await transport.push(event: event, subscription: "pair")
    }

    /// The correct transcript for this session, as the desktop computes it.
    func correctTranscript() throws -> String {
        let target = try #require(targetPubkey)
        let shared = try Pairing.sharedSecret(privateKey: key, peer: target)
        let sas = Pairing.shortAuthentication(sharedSecret: shared, sessionSecret: sessionSecret)
        return Pairing.transcriptHash(
            sessionID: Pairing.sessionID(sessionSecret: sessionSecret),
            sourcePubkey: key.publicKey,
            targetPubkey: target,
            sasInput: sas.input,
            sessionSecret: sessionSecret
        ).hex
    }

    func expectedSASCode() throws -> String {
        let target = try #require(targetPubkey)
        let shared = try Pairing.sharedSecret(privateKey: key, peer: target)
        return Pairing.shortAuthentication(
            sharedSecret: shared,
            sessionSecret: sessionSecret
        ).code
    }

    /// Decrypts the phone's final message off the wire, whichever it is.
    /// Polls on the actor so no state escapes a Sendable closure.
    func observeOutcome() async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            for frame in await transport.sent(ofType: "EVENT").dropFirst() {
                guard let event = frame.event,
                      let target = targetPubkey,
                      event.pubkey == target.hex,
                      let conversationKey = try? NIP44.conversationKey(privateKey: key, peer: target),
                      let decrypted = try? NIP44.decrypt(event.content, conversationKey: conversationKey),
                      let message = try? JSONSerialization.jsonObject(with: Data(decrypted.utf8)) as? [String: Any]
                else { continue }

                switch message["type"] as? String {
                case "complete":
                    receivedComplete = true
                    return
                case "abort":
                    receivedAbortReason = message["reason"] as? String
                    return
                default:
                    continue
                }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@Suite("Pairing session", .timeLimit(.minutes(1)))
struct PairingSessionTests {
    struct Rig {
        let session: PairingSession
        let desktop: FakeDesktop
        let transport: MockTransport
        let states: AsyncStream<PairingSession.State>
        var iterator: AsyncStream<PairingSession.State>.AsyncIterator

        mutating func next() async -> PairingSession.State? {
            await iterator.next()
        }
    }

    private func makeRig(
        validate: @escaping @Sendable (URL, String) async throws -> Void = { _, _ in }
    ) async throws -> Rig {
        let transport = MockTransport()
        let desktop = try FakeDesktop(transport: transport)
        let invitation = try Pairing.parse(await desktop.invitationURI)

        let session = try PairingSession(
            invitation: invitation,
            transport: transport,
            validateCredentials: validate,
            sleep: { _ in }   // no real waiting in tests
        )
        let states = await session.start()
        return Rig(
            session: session,
            desktop: desktop,
            transport: transport,
            states: states,
            iterator: states.makeAsyncIterator()
        )
    }

    @Test("completes the full handshake and delivers credentials")
    func happyPath() async throws {
        var rig = try await makeRig()

        #expect(await rig.next() == .connecting)

        // The phone subscribes for its ephemeral identity and sends an offer.
        let offer = try await rig.desktop.consumeOffer()
        #expect(offer.type == "offer")
        #expect(offer.version == 1)
        #expect(offer.sessionID
            == Pairing.sessionID(sessionSecret: await rig.desktop.sessionSecret).hex)

        // Both screens show the same six digits.
        guard case .comparing(let code) = await rig.next() else {
            Issue.record("expected the SAS state")
            return
        }
        #expect(code == (try await rig.desktop.expectedSASCode()))

        // Desktop confirms with the correct transcript; the human agrees.
        try await rig.desktop.send([
            "type": "sas-confirm",
            "transcript_hash": try await rig.desktop.correctTranscript(),
        ])
        await rig.session.confirmMatch()
        #expect(await rig.next() == .transferring)

        // The account arrives.
        let account = try PrivateKey()
        let payload: [String: Any] = [
            "type": "payload",
            "payload_type": "buzz-credentials",
            "payload": #"{"relayUrl":"https://designers.communities.buzz.xyz","pubkey":"\#(account.publicKey.hex)","nsec":"\#(account.nsec)"}"#,
        ]
        try await rig.desktop.send(payload)

        #expect(await rig.next() == .validating)
        guard case .complete(let credentials) = await rig.next() else {
            Issue.record("expected completion")
            return
        }
        #expect(credentials.nsec == account.nsec)
        #expect(credentials.relayURL.absoluteString == "wss://designers.communities.buzz.xyz")

        // And the desktop heard the phone say so.
        await rig.desktop.observeOutcome()
        #expect(await rig.desktop.receivedComplete)
    }

    @Test("a wrong transcript burns the session as an attack")
    func transcriptMismatch() async throws {
        var rig = try await makeRig()
        _ = await rig.next()
        try await rig.desktop.consumeOffer()
        _ = await rig.next()

        try await rig.desktop.send([
            "type": "sas-confirm",
            "transcript_hash": String(repeating: "ab", count: 32),
        ])

        #expect(await rig.next() == .failed(reason: .securityMismatch))
        await rig.desktop.observeOutcome()
        #expect(await rig.desktop.receivedAbortReason == "sas_mismatch")
    }

    @Test("the human rejecting the digits aborts with sas_mismatch")
    func userRejects() async throws {
        var rig = try await makeRig()
        _ = await rig.next()
        try await rig.desktop.consumeOffer()
        _ = await rig.next()

        await rig.session.rejectMatch()

        #expect(await rig.next() == .failed(reason: .userRejected))
        await rig.desktop.observeOutcome()
        #expect(await rig.desktop.receivedAbortReason == "sas_mismatch")
    }

    @Test("a payload racing ahead of the human is buffered, not dropped")
    func earlyPayloadBuffers() async throws {
        var rig = try await makeRig()
        _ = await rig.next()
        try await rig.desktop.consumeOffer()
        _ = await rig.next()

        // Desktop confirms and immediately ships the payload; the human has
        // not tapped yet.
        try await rig.desktop.send([
            "type": "sas-confirm",
            "transcript_hash": try await rig.desktop.correctTranscript(),
        ])
        let account = try PrivateKey()
        try await rig.desktop.send([
            "type": "payload",
            "payload": #"{"relayUrl":"https://a.communities.buzz.xyz","nsec":"\#(account.nsec)"}"#,
        ])

        // Only after the tap does anything move.
        await rig.session.confirmMatch()
        #expect(await rig.next() == .transferring)
        #expect(await rig.next() == .validating)
        guard case .complete = await rig.next() else {
            Issue.record("expected completion from the buffered payload")
            return
        }
    }

    @Test("messages from a stranger are silently ignored")
    func strangerIgnored() async throws {
        var rig = try await makeRig()
        _ = await rig.next()
        try await rig.desktop.consumeOffer()
        _ = await rig.next()

        // Correctly encrypted for us, properly signed, right kind, but not
        // from the pubkey the QR promised.
        let stranger = try PrivateKey()
        try await rig.desktop.send(
            ["type": "abort", "reason": "hijack"],
            signedBy: stranger
        )

        // Then a legitimate flow completes untouched.
        try await rig.desktop.send([
            "type": "sas-confirm",
            "transcript_hash": try await rig.desktop.correctTranscript(),
        ])
        await rig.session.confirmMatch()
        #expect(await rig.next() == .transferring)
    }

    @Test("credentials that fail validation fail the pairing")
    func badCredentials() async throws {
        var rig = try await makeRig(validate: { _, _ in
            throw RelayError.authenticationFailed("nope")
        })
        _ = await rig.next()
        try await rig.desktop.consumeOffer()
        _ = await rig.next()

        try await rig.desktop.send([
            "type": "sas-confirm",
            "transcript_hash": try await rig.desktop.correctTranscript(),
        ])
        await rig.session.confirmMatch()
        _ = await rig.next() // transferring

        let account = try PrivateKey()
        try await rig.desktop.send([
            "type": "payload",
            "payload": #"{"relayUrl":"https://a.communities.buzz.xyz","nsec":"\#(account.nsec)"}"#,
        ])

        _ = await rig.next() // validating
        #expect(await rig.next() == .failed(reason: .credentialsRejected))
    }

    @Test("a private-network relay in the payload is refused")
    func ssrfRefused() async throws {
        // The payload's relay URL arrived over the network; connecting to it
        // blindly would let a hostile desktop point the phone at a router.
        #expect(PairingSession.validatedRelayURL("https://192.168.1.1") == nil)
        #expect(PairingSession.validatedRelayURL("wss://10.0.0.1") == nil)
        #expect(PairingSession.validatedRelayURL("ftp://relay.example") == nil)
        #expect(PairingSession.validatedRelayURL("") == nil)
        #expect(
            PairingSession.validatedRelayURL("https://designers.communities.buzz.xyz")?
                .absoluteString == "wss://designers.communities.buzz.xyz"
        )
        #expect(
            PairingSession.validatedRelayURL("ws://localhost:3000")?
                .absoluteString == "ws://localhost:3000"
        )
    }

    @Test("a source abort surfaces its reason")
    func sourceAbort() async throws {
        var rig = try await makeRig()
        _ = await rig.next()
        try await rig.desktop.consumeOffer()
        _ = await rig.next()

        try await rig.desktop.send(["type": "abort", "reason": "user_cancelled"])
        #expect(await rig.next() == .failed(reason: .sourceAborted("user_cancelled")))
    }
}
