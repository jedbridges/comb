import SwiftUI

/// Comb's haptic vocabulary.
///
/// Touch is scarce the way chartreuse is scarce. A phone that taps back at
/// every gesture stops meaning anything and starts feeling cheap, so this is a
/// short list on purpose: something you sent left the device, something you did
/// landed, something failed, or something happened once and mattered. Scrolling,
/// opening a sheet, and tapping a row are deliberately silent, and the ones iOS
/// already provides for menus and pickers are left to iOS.
///
/// The rule that keeps it honest: a haptic fires only for an action the reader
/// took. Nothing that merely *arrives* is allowed to buzz, or a busy channel
/// would vibrate in a pocket all afternoon.
///
/// Expressed as `SensoryFeedback` rather than UIKit generators so the system
/// owns the details, including honouring the person's own haptics setting,
/// which a hand-rolled `UIImpactFeedbackGenerator` does not.
enum Haptics {
    /// A message left this device. The most repeated deliberate action in the
    /// app, so it is the lightest thing here: felt when you are looking for it,
    /// unnoticed on the fiftieth message of a conversation.
    static let send: SensoryFeedback = .impact(weight: .light, intensity: 0.5)

    /// Joining a reaction pile. Firmer than a send because it is rarer, and
    /// because the bee-swarm animation is landing at the same moment.
    static let reaction: SensoryFeedback = .impact(flexibility: .solid, intensity: 0.75)

    /// The swarm settling, a beat after `reaction`. Softer, so the pair reads
    /// as one gesture with a tail rather than two taps.
    static let reactionSettles: SensoryFeedback = .impact(flexibility: .soft, intensity: 0.4)

    /// Something the reader asked for did not happen. Paired with a message
    /// that says what, never on its own: a buzz with no words is just anxiety.
    static let failure: SensoryFeedback = .error

    /// Once and it mattered: a community joined, a device paired, a code
    /// recognised. Deliberately the same feeling for all three, because they
    /// are the same moment from the person's side.
    static let milestone: SensoryFeedback = .success
}
