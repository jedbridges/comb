import CombCore
import CombNet
import CombStore
import Foundation
import Observation

/// Drives the Phase 3 debug screen: connect to a relay, authenticate, and see
/// what actually comes back.
///
/// This is scaffolding, not product. It exists to find out where the real
/// service disagrees with the assumptions the protocol layer was built on, and
/// it gets deleted once there are real screens.
@MainActor
@Observable
final class DebugConnectionModel {
    var relayURL = "wss://designers.communities.buzz.xyz"

    /// Held in memory for the lifetime of this screen and never written
    /// anywhere. Keychain storage arrives with onboarding; until then, treating
    /// a pasted key as disposable is the honest thing to do.
    var secretKey = ""

    private(set) var log: [LogLine] = []
    private(set) var status: Status = .disconnected
    private(set) var channels: [DiscoveredChannel] = []
    private(set) var storedEventCount = 0

    private var session: RelaySession?
    private var store: EventStore?

    enum Status: Equatable {
        case disconnected
        case connecting
        case authenticated(String)
        case failed(String)

        var isBusy: Bool { self == .connecting }
    }

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let at = Date()
        let level: Level
        let text: String

        enum Level: Equatable { case info, sent, received, good, bad }
    }

    struct DiscoveredChannel: Identifiable, Equatable {
        let id: String
        let name: String
        let memberCount: Int?
    }

    // MARK: - Actions

    func connect() async {
        guard status != .connecting else { return }
        log.removeAll()
        channels.removeAll()
        status = .connecting

        guard let url = URL(string: relayURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            fail("That does not look like a relay URL.")
            return
        }

        let key: PrivateKey
        do {
            key = try Self.parseKey(secretKey)
        } catch {
            fail("Could not read that key. Paste an nsec1… or 64 hex characters.")
            return
        }

        let signer = InMemorySigner(key)
        note(.info, "identity \(key.publicKey.abbreviated)")

        // NIP-11 first: it is unauthenticated, so it tells us whether the host
        // is a relay at all before any key is used.
        await probeRelayInfo(url: url)

        do {
            let store = try EventStore()
            self.store = store

            let sink = DebugSink(store: store) { [weak self] update in
                Task { @MainActor in self?.apply(update) }
            }

            let session = RelaySession(url: url, signer: signer, sink: sink)
            self.session = session

            note(.info, "opening socket")
            try await session.start()

            // The relay challenges on connect, so authentication completes as a
            // side effect of the first thing that needs it.
            note(.info, "waiting for NIP-42 challenge")
            try await loadChannels(session: session)

            status = .authenticated(key.publicKey.abbreviated)
            note(.good, "authenticated")
        } catch {
            fail(Self.describe(error))
        }
    }

    func disconnect() async {
        await session?.stop()
        session = nil
        store = nil
        status = .disconnected
        note(.info, "disconnected")
    }

    // MARK: - Steps

    private func probeRelayInfo(url: URL) async {
        do {
            let info = try await RelayInfoClient().fetch(from: url)
            note(.received, "NIP-11 \(info.software ?? "unknown") \(info.version ?? "")")
            note(
                .info,
                "groups \(info.supportsGroups ? "yes" : "no") · "
                    + "auth \(info.requiresAuth ? "required" : "optional") · "
                    + "search \(info.supportsSearch ? "yes" : "no")"
            )
            if !info.isUsable {
                note(.bad, "relay does not support NIP-29 groups")
            }
        } catch {
            // Not fatal. A relay may serve no document and still work.
            note(.bad, "NIP-11 unavailable: \(Self.describe(error))")
        }
    }

    /// The Phase 3 demo: a one-shot query for relay-signed group metadata.
    private func loadChannels(session: RelaySession) async throws {
        note(.sent, "REQ kinds:[39000] limit:100")
        let metadata = try await session.query([Filter(kinds: [.groupMetadata], limit: 100)])
        note(.received, "\(metadata.count) channel metadata events")

        note(.sent, "REQ kinds:[39002] limit:100")
        let rosters = try await session.query([Filter(kinds: [.groupMembers], limit: 100)])
        note(.received, "\(rosters.count) member rosters")

        // Member counts come from a separate relay-signed event, so they are
        // joined here by the channel's `d` tag.
        var counts: [String: Int] = [:]
        for roster in rosters {
            guard let id = roster.addressableIdentifier else { continue }
            counts[id] = roster.values(for: "p").count
        }

        channels = metadata
            .compactMap { event -> DiscoveredChannel? in
                guard let id = event.addressableIdentifier else { return nil }
                let name = (try? JSONDecoder().decode(
                    ChannelName.self,
                    from: Data(event.content.utf8)
                ))?.name
                return DiscoveredChannel(
                    id: id,
                    name: name ?? event.firstValue(for: "name") ?? id,
                    memberCount: counts[id]
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Everything the relay served goes through the same verified ingest the
        // app will use, which is the point of running this against a real relay.
        if let store {
            let result = try await store.ingest(metadata + rosters)
            storedEventCount = try await store.count()
            note(
                result.rejected.isEmpty ? .good : .bad,
                "ingest: \(result.inserted.count) stored, \(result.rejected.count) rejected"
            )
            for rejection in result.rejected.prefix(3) {
                note(.bad, "rejected \(rejection.id.prefix(12))… \(rejection.reason)")
            }
        }
    }

    // MARK: - Plumbing

    private func apply(_ update: DebugSink.Update) {
        switch update {
        case .ingested(let count, let rejected):
            storedEventCount += count
            if rejected > 0 { note(.bad, "\(rejected) events failed verification") }
        case .endOfStoredEvents(let subscription):
            note(.received, "EOSE \(subscription)")
        }
    }

    private func note(_ level: LogLine.Level, _ text: String) {
        log.append(LogLine(level: level, text: text))
    }

    private func fail(_ message: String) {
        status = .failed(message)
        note(.bad, message)
    }

    /// Accepts either form a person is likely to have to hand.
    static func parseKey(_ input: String) throws -> PrivateKey {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("nsec") {
            return try PrivateKey(nsec: trimmed)
        }
        guard let data = Data(hex: trimmed) else { throw CryptoError.invalidKeyLength(0) }
        return try PrivateKey(data: data)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case RelayError.publishRejected(let reason), RelayError.subscriptionClosed(let reason):
            reason
        case RelayError.authenticationFailed(let reason):
            "authentication failed: \(reason)"
        case RelayError.timedOut:
            "timed out"
        case RelayError.notConnected:
            "not connected"
        case RelayError.filterMissingKinds:
            "filter needs explicit kinds"
        case RelayError.filterRequiresPubkeyScope:
            "filter needs a #p scope"
        default:
            String(describing: error)
        }
    }

    private struct ChannelName: Decodable {
        let name: String?
    }
}

/// Forwards relay events into the store and reports what happened.
private actor DebugSink: EventSink {
    enum Update: Sendable {
        case ingested(count: Int, rejected: Int)
        case endOfStoredEvents(String)
    }

    private let store: EventStore
    private let report: @Sendable (Update) -> Void

    init(store: EventStore, report: @escaping @Sendable (Update) -> Void) {
        self.store = store
        self.report = report
    }

    func ingest(_ events: [NostrEvent], subscription: String) async {
        guard let result = try? await store.ingest(events) else { return }
        report(.ingested(count: result.inserted.count, rejected: result.rejected.count))
    }

    func endOfStoredEvents(subscription: String) async {
        report(.endOfStoredEvents(subscription))
    }
}
