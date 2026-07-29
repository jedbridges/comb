import SwiftUI

/// Names for the elements the UI tests drive.
///
/// This file is compiled into both the app and the UI test bundle, which is the
/// point: a UI test runs in a separate process and cannot import the app, so
/// the alternative is the same string literal written twice and silently
/// drifting apart. A rename that breaks a test then reads as a broken feature.
///
/// Identifiers rather than labels. `accessibilityLabel` is user-facing copy and
/// should stay free to change: "Send message" becoming "Send" is a copy edit,
/// not a contract, and a test anchored to it would make the copy load-bearing.
///
/// Deliberately small. Every entry here is a promise to keep a name stable, so
/// they are added when a flow needs one rather than sprinkled everywhere.
enum A11y {
    /// The list of channels, and one row within it.
    static let channelList = "channels.list"
    static func channelRow(_ id: String) -> String { "channels.row.\(id)" }
    static let anyChannelRow = "channels.row."

    /// Getting to settings, and getting back out.
    static let settingsButton = "channels.settings"
    static let settingsScreen = "settings.screen"
    static let settingsDone = "settings.done"

    /// The compose bar.
    static let composeField = "compose.field"
    static let sendButton = "compose.send"

    /// A message in the timeline, by the text it carries, so a test can assert
    /// that the thing it typed is the thing that appeared.
    static let timeline = "timeline.list"
}

extension View {
    /// Reads better at the call site than the raw modifier, and makes the
    /// identifiers grep-able as one thing.
    func a11y(_ identifier: String) -> some View {
        accessibilityIdentifier(identifier)
    }
}
