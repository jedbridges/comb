import Foundation

/// What the user wants to be told about, and the bookkeeping that stops the
/// same mention notifying twice.
///
/// Local-only, in UserDefaults: these are preferences and timestamps, not
/// something the relay has any business knowing.
@MainActor
enum NotificationSettings {
    private static let enabledKey = "comb.notifications.enabled"
    private static let mutedPrefix = "comb.notifications.muted."
    private static let lastNotifiedPrefix = "comb.notifications.lastNotified."

    /// The master switch. Off until the user turns it on, because scheduling
    /// background work and asking for the notification permission should both
    /// be things they chose, not defaults sprung on them.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Per-community mute. Defaults to unmuted, so enabling the master switch
    /// covers every community a person is in without a second step each time
    /// they join one.
    static func isMuted(host: String) -> Bool {
        UserDefaults.standard.bool(forKey: mutedPrefix + host)
    }

    static func setMuted(_ muted: Bool, host: String) {
        UserDefaults.standard.set(muted, forKey: mutedPrefix + host)
    }

    /// The newest mention already delivered for a community, so a wake never
    /// re-notifies what a previous wake, or the foreground app, already showed.
    static func lastNotified(host: String) -> Int64 {
        Int64(UserDefaults.standard.integer(forKey: lastNotifiedPrefix + host))
    }

    static func setLastNotified(_ timestamp: Int64, host: String) {
        UserDefaults.standard.set(Int(timestamp), forKey: lastNotifiedPrefix + host)
    }

    /// Whether a community should produce notifications right now.
    static func shouldNotify(host: String) -> Bool {
        isEnabled && !isMuted(host: host)
    }
}
