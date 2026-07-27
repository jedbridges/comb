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
}
