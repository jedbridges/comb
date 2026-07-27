import CombCore
import Foundation
import Observation
import SwiftUI

/// Who is online in a community, right now.
///
/// Kind 20001 is ephemeral: never stored, because a presence heartbeat is
/// false 90 seconds later. This mirrors Buzz's 30-second heartbeat with a
/// 45-second window (one missed heartbeat plus half a cycle of grace).
@MainActor
@Observable
final class PresenceMonitor {
    /// How often the local user publishes a heartbeat.
    static let heartbeatInterval: TimeInterval = 30
    /// How long a remote heartbeat stays live before expiry.
    static let liveWindow: TimeInterval = 45

    /// Public keys of everyone currently online, excluding the viewer.
    private(set) var onlinePubkeys: Set<String> = []

    private var lastSeen: [String: Date] = [:]
    private var pruneTask: Task<Void, Never>?

    private let me: String

    init(me: String) {
        self.me = me
    }

    func received(_ event: NostrEvent) {
        guard event.kind == .buzzPresence, event.pubkey != me else { return }

        lastSeen[event.pubkey] = Date()
        refresh()
        startPruning()
    }

    func isOnline(_ pubkey: String) -> Bool {
        onlinePubkeys.contains(pubkey)
    }

    private func startPruning() {
        guard pruneTask == nil else { return }
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if self.prune() { return }
            }
        }
    }

    private func prune() -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.liveWindow)
        let before = lastSeen.count
        lastSeen = lastSeen.filter { $0.value > cutoff }

        if lastSeen.count != before { refresh() }
        if lastSeen.isEmpty {
            pruneTask = nil
            return true
        }
        return false
    }

    private func refresh() {
        onlinePubkeys = Set(lastSeen.keys)
    }
}

// MARK: - Environment

extension EnvironmentValues {
    @Entry var presenceMonitor: PresenceMonitor?
}
