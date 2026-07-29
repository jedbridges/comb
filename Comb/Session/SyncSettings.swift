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

    private static let readStateSlotKey = "comb.sync.readStateSlot"
    private static let readStateClientKey = "comb.sync.readStateClient"

    /// This installation's slot in NIP-RS, and the name it signs its blobs with.
    ///
    /// Two values rather than one because the spec keeps them apart on purpose.
    /// The slot is the public `d` tag, so a relay operator can count how many
    /// installations an account runs; the client id lives inside the encrypted
    /// body and is the only thing that says which blob is ours, which is how a
    /// device avoids merging its own echo back over itself.
    ///
    /// Per installation, not per community. The addressable coordinate already
    /// includes the pubkey, and Comb holds a different key per community, so one
    /// slot cannot collide across them.
    ///
    /// Created on first use and never rotated here. The spec allows rotation and
    /// asks clients to keep these stable for as long as possible, because every
    /// rotation leaves an orphaned blob behind until it ages out.
    static var readStateSlot: String { stableIdentifier(forKey: readStateSlotKey) }

    static var readStateClientID: String { stableIdentifier(forKey: readStateClientKey) }

    /// 32 hex characters from the system CSPRNG, as the specification suggests.
    private static func stableIdentifier(forKey key: String) -> String {
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(value, forKey: key)
        return value
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
