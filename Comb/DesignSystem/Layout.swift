import SwiftUI

/// The spacing scale, from Buzz's grid (2/4/8/12/16/20/24/32/40).
///
/// Padding and gaps in feature views come from here; an odd literal like 18 or
/// 9 in a view is drift. When a design genuinely needs a new step, it gets a
/// named token, not an inline number.
enum Space {
    /// 2pt. Hairline separations.
    static let hairline: CGFloat = 2
    /// 4pt. Between a label and its value.
    static let xxs: CGFloat = 4
    /// 8pt. Within a control.
    static let xs: CGFloat = 8
    /// 12pt. Between related elements.
    static let sm: CGFloat = 12
    /// 16pt. Between groups; default card padding.
    static let md: CGFloat = 16
    /// 20pt. Screen edge insets.
    static let lg: CGFloat = 20
    /// 24pt. Between sections.
    static let xl: CGFloat = 24
    /// 32pt. Major vertical rhythm.
    static let xxl: CGFloat = 32
    /// 40pt. Hero breathing room.
    static let xxxl: CGFloat = 40
}

/// Corner radii, from Buzz's 6/8/10 scale plus the card and sheet steps.
enum Radii {
    /// 6pt. Chips and small tags.
    static let chip: CGFloat = 6
    /// 8pt. Fields and inline controls.
    static let control: CGFloat = 8
    /// 10pt. Message-adjacent surfaces.
    static let bubble: CGFloat = 10
    /// 16pt. Cards and grouped lists.
    static let card: CGFloat = 16
    /// 24pt. Sheets, dialogs, and the compose bar shell.
    static let sheet: CGFloat = 24
    /// 16pt. The compose field inside the compose shell.
    ///
    /// Concentric by construction: `sheet` minus the shell's own padding
    /// (`Space.xs`). A corner that is not derived this way leaves the gap
    /// between the two curves visibly uneven, which is the tell that a bar
    /// was assembled rather than drawn.
    static let composeField: CGFloat = 16
}

/// Fixed element sizes that recur across screens.
enum Sizing {
    /// Avatars in message timelines.
    static let avatar: CGFloat = 34
    /// Channel cells in lists.
    static let channelCell: CGFloat = 38
    /// The mark on cold-start and empty states.
    static let heroMark: CGFloat = 80
    /// The mark as an accent.
    static let inlineMark: CGFloat = 48
    /// Minimum hit target, per Apple.
    static let hitTarget: CGFloat = 44
}
