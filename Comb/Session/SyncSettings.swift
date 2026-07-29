import Foundation

/// Whether this device publishes its read markers for its other devices.
///
/// Local-only, in UserDefaults, like every other preference: what a device
/// chooses to publish is not itself something to publish.
///
/// Off until asked for. Read state is the one thing in this app that can stay
/// entirely on-device and currently does, and turning that off is a decision
/// with a cost: the markers are encrypted to your own key, so a relay learns
/// nothing about which rooms you read, but it does learn the timing of when you
/// read something, because a publish is a packet with a clock on it. That is a
/// small leak next to the presence heartbeats a connected client already sends,
/// and it is still a leak, and it buys a convenience nobody asked for until
/// they own a second device.
@MainActor
enum SyncSettings {
    private static let readStateKey = "comb.sync.readState"

    static var syncsReadState: Bool {
        get { UserDefaults.standard.bool(forKey: readStateKey) }
        set { UserDefaults.standard.set(newValue, forKey: readStateKey) }
    }

    private static let remoteImagesKey = "comb.privacy.remoteImages"

    /// Whether to load pictures from hosts other than the community's own.
    ///
    /// Off by default, which is the unusual choice and the deliberate one. A
    /// profile picture or a custom emoji is a URL its owner chose, fetched as
    /// the row scrolls past, so one hostile profile is a tracking pixel that
    /// reports every reader who ever sees it. ETHOS point 4 asks for privacy
    /// that is structural rather than promised, and a default of off is the
    /// structural version.
    ///
    /// The cost is small and was measured rather than assumed. On a live
    /// community of 263 profiles, 182 pictures were already on the community's
    /// own host, 31 had none, and 19 were inert `data:` URIs. Around 8% lose
    /// their picture and fall back to initials, which the app already draws.
    static var loadsRemoteImages: Bool {
        get { UserDefaults.standard.bool(forKey: remoteImagesKey) }
        set { UserDefaults.standard.set(newValue, forKey: remoteImagesKey) }
    }
}
