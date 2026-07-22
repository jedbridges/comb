import Foundation
import Testing
@testable import CombNet

@Suite("NIP-11 relay info", .timeLimit(.minutes(1)))
struct RelayInfoTests {
    /// The real document served by a hosted Buzz relay, captured verbatim so
    /// these assertions are about what the service actually sends rather than
    /// what the source suggested it would.
    static func liveDocument() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "Fixtures-buzz-relay-nip11",
            withExtension: "json"
        ))
        return try Data(contentsOf: url)
    }

    private func decoded() throws -> RelayInfo {
        try JSONDecoder().decode(RelayInfo.self, from: try Self.liveDocument())
    }

    @Test("parses the document a hosted Buzz relay actually serves")
    func parsesLiveDocument() throws {
        let info = try decoded()

        #expect(info.isBuzzRelay)
        #expect(info.software == "https://github.com/block/buzz")
        #expect(info.selfPubkey?.count == 64)
        #expect(info.pairingRelayURL == "wss://pairing.buzz.xyz")
    }

    @Test("reads capabilities from supported_nips")
    func readsCapabilities() throws {
        let info = try decoded()

        #expect(info.supportsGroups, "NIP-29 is the minimum Comb needs")
        #expect(info.supportsAuth)
        #expect(info.supportsSearch)
        #expect(info.supportsPrivateMessages)
        #expect(info.isUsable)
    }

    @Test("confirms the relay demands authentication")
    func requiresAuth() throws {
        // Every REQ and EVENT is gated behind NIP-42 because of this, and it is
        // unconditional on the hosted service rather than a per-deployment
        // setting.
        let info = try decoded()
        #expect(info.requiresAuth)
        #expect(info.limitation?.restrictedWrites == true)
        #expect(info.limitation?.paymentRequired == false)
    }

    @Test("reads the real subscription and filter ceilings")
    func readsLimits() throws {
        // Checked against the live service rather than assumed: the plan
        // guessed subscriptions would be scarce enough to need an aggressive
        // LRU, and 1024 says otherwise.
        let info = try decoded()
        #expect(info.subscriptionLimit == 1024)
        #expect(info.filterLimit == 10)
        #expect(info.limitation?.maxLimit == 10000)
        #expect(info.limitation?.maxMessageLength == 524_288)
    }

    @Test("carries no per-community identity")
    func hasNoCommunityIdentity() throws {
        // Every Buzz relay returns these same strings, deliberately, so that
        // nobody can enumerate which communities exist. Onboarding therefore
        // cannot show a community's real name from NIP-11 alone, which is why
        // the discovery index has to carry names itself.
        let info = try decoded()
        #expect(info.name == "Buzz Relay")
        #expect(info.description == "Buzz — private team communication relay")
        #expect(info.icon == nil)
    }

    @Test("tolerates a minimal document from a plain relay")
    func tolerantOfMinimalDocument() throws {
        // A generic NIP-29 relay may send almost nothing. Missing fields must
        // not fail the parse, or Comb would refuse relays it can actually use.
        let json = #"{"name":"Some Relay","supported_nips":[1,29]}"#
        let info = try JSONDecoder().decode(RelayInfo.self, from: Data(json.utf8))

        #expect(info.isUsable)
        #expect(!info.isBuzzRelay)
        #expect(!info.requiresAuth)
        #expect(info.supportedExtensions.isEmpty)
        // Falls back to a conservative ceiling rather than assuming generosity.
        #expect(info.subscriptionLimit == 20)
    }

    @Test("marks a relay without NIP-29 as unusable")
    func rejectsNonGroupRelay() throws {
        let json = #"{"name":"Plain Nostr","supported_nips":[1,11]}"#
        let info = try JSONDecoder().decode(RelayInfo.self, from: Data(json.utf8))
        #expect(!info.isUsable)
    }

    @Test("treats an empty document as usable-less rather than a failure")
    func emptyDocument() throws {
        let info = try JSONDecoder().decode(RelayInfo.self, from: Data("{}".utf8))
        #expect(!info.isUsable)
        #expect(info.supportedNIPs.isEmpty)
    }
}

@Suite("Relay URL mapping", .timeLimit(.minutes(1)))
struct RelayURLTests {
    private func map(_ string: String) -> String? {
        URL(string: string).flatMap(RelayInfoClient.httpURL(for:))?.absoluteString
    }

    @Test("maps websocket URLs to their https document")
    func mapsWebsocketURLs() {
        // Users paste wss:// URLs because that is what a relay is; the
        // information document lives on https at the same host.
        #expect(map("wss://designers.communities.buzz.xyz")
            == "https://designers.communities.buzz.xyz/")
        #expect(map("https://designers.communities.buzz.xyz")
            == "https://designers.communities.buzz.xyz/")
    }

    @Test("keeps plaintext local relays on http")
    func keepsLocalPlaintext() {
        // ws:// is only ever a local development relay. Anywhere else it would
        // mean sending a signed auth event over an unencrypted socket.
        #expect(map("ws://localhost:3000") == "http://localhost:3000/")
    }

    @Test("strips paths, queries, and fragments")
    func stripsExtras() {
        #expect(map("wss://relay.example/some/path?token=secret#frag")
            == "https://relay.example/")
    }

    @Test("rejects URLs that are not relays")
    func rejectsNonRelays() {
        #expect(map("ftp://relay.example") == nil)
        #expect(map("not a url at all") == nil)
        #expect(map("wss://") == nil)
    }
}
