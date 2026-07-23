import CombCore
import CombStore
import Foundation
import Observation

/// Who is typing in a channel, right now.
///
/// Kind 20002 is ephemeral: it is never stored, because writing it would
/// grow the log forever with facts that are false ten seconds later. So this
/// holds it in memory, expiring on a timer.
///
/// Every constant matches Buzz's own client
/// (`desktop/src/features/messages/useChannelTyping.ts` and
/// `useTypingBroadcast.ts`), so the two clients agree about when someone
/// stopped typing rather than one showing a stale indicator the other has
/// already dropped.
@MainActor
@Observable
final class TypingMonitor {
    /// How long a received indicator stays live.
    static let liveWindow: TimeInterval = 8
    /// How often our own typing is republished while the user keeps typing.
    static let sendInterval: TimeInterval = 3
    /// After sending a message, ignore our own trailing indicators: the
    /// message itself already said what the indicator was promising.
    static let suppressAfterSend: TimeInterval = 2

    /// Display names of everyone currently typing, excluding the viewer.
    private(set) var typingNames: [String] = []

    private var lastSeen: [String: Date] = [:]
    private var lastSentAt: Date?
    private var suppressUntil: Date?
    private var pruneTask: Task<Void, Never>?

    private let store: EventStore
    private let channelID: String
    private let me: String

    init(store: EventStore, channelID: String, me: String) {
        self.store = store
        self.channelID = channelID
        self.me = me
    }

    deinit { pruneTask?.cancel() }

    /// Records an indicator from the relay.
    func received(_ event: NostrEvent) {
        guard event.kind == .buzzTyping,
              event.groupID == channelID,
              event.pubkey != me
        else { return }

        lastSeen[event.pubkey] = Date()
        refresh()
        startPruning()
    }

    /// Whether our own typing should be published now, given the throttle.
    ///
    /// Returns false while suppressed after a send, so the indicator does not
    /// reappear for the two seconds after the message it was announcing.
    func shouldPublish(now: Date = Date()) -> Bool {
        if let suppressUntil, now < suppressUntil { return false }
        guard let lastSentAt else { return true }
        return now.timeIntervalSince(lastSentAt) >= Self.sendInterval
    }

    func didPublish(at date: Date = Date()) {
        lastSentAt = date
    }

    /// Called when the user sends: suppresses our indicator briefly, and
    /// forgets the sender's own so it cannot linger behind their message.
    func didSendMessage(at date: Date = Date()) {
        suppressUntil = date.addingTimeInterval(Self.suppressAfterSend)
        lastSentAt = nil
    }

    /// Drops the sender's indicator the moment their message lands, rather
    /// than leaving "Mat is typing" under the message Mat just sent.
    func messageArrived(from pubkey: String) {
        guard lastSeen.removeValue(forKey: pubkey) != nil else { return }
        refresh()
    }

    private func startPruning() {
        guard pruneTask == nil else { return }
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.prune() { return }   // nothing left to watch
            }
        }
    }

    /// Returns true once nothing is left, so the timer can stop instead of
    /// ticking forever in a quiet channel.
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
        // Resolved through the store so the strip shows names, not keys, and
        // falls back the same way every other surface does.
        typingNames = lastSeen.keys.compactMap { pubkey in
            (try? store.profile(pubkey: pubkey))?.name
        }
        .sorted()
    }

    /// "Mat is typing", "Mat and Rico are typing", "Several people are typing".
    var summary: String? {
        switch typingNames.count {
        case 0: nil
        case 1: "\(typingNames[0]) is typing"
        case 2: "\(typingNames[0]) and \(typingNames[1]) are typing"
        default: "Several people are typing"
        }
    }
}
