import SwiftUI
import TipKit

/// Says once that zaps exist.
///
/// This is the whole discoverability fix, and it is deliberately small. The
/// audit that found the gap first framed it as a gesture problem, and that was
/// wrong: reactions sit behind the same long-press, and a long-press context
/// menu on a message is what iMessage, Slack and WhatsApp all do. Nothing was
/// unidiomatic.
///
/// The actual gap is narrower. Nothing in the app ever mentions that zaps are a
/// thing, so the only ways to learn were to be told by a person or to long-press
/// a message and read a menu you had no reason to open. And the one visible
/// affordance, the chip on a message, only appears once somebody has already
/// zapped, so a new community could never bootstrap its way into the feature.
///
/// So: one sentence, once, at the moment it can be acted on, and never again.
/// TipKit rather than a hand-rolled banner because it owns the "shown once,
/// dismissed forever" bookkeeping across launches, and because a native
/// component inherits whatever Apple does with tips in the next OS, which is the
/// same reason the rest of this app prefers system controls.
struct ZapTip: Tip {
    /// Set when a channel is on screen that contains somebody who can actually
    /// be zapped. Without it the tip could fire on a community where nobody has
    /// a Lightning address, which is teaching a feature that does not work here.
    @Parameter static var canZapSomeone: Bool = false

    var title: Text {
        Text("Send a tip")
    }

    var message: Text? {
        // Names the gesture, because the gesture is the part that cannot be
        // guessed. Deliberately does not explain what a sat is: that belongs to
        // the sheet's own explanation, where somebody has shown they are
        // interested, and repeating it here would make a one-line tip a
        // paragraph.
        Text("Press and hold a message to zap its author a few sats.")
    }

    var image: Image? {
        Image(systemName: "bolt.fill")
    }

    var rules: [Rule] {
        #Rule(Self.$canZapSomeone) { $0 == true }
    }

    var options: [any TipOption] {
        // Once, ever. A tip that returns is a tip that gets dismissed without
        // being read, and this one has nothing to add on a second showing.
        [Tips.MaxDisplayCount(1)]
    }
}
