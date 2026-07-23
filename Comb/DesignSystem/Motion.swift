import SwiftUI

/// Comb's motion tokens, ported from Buzz's `motion.css`.
///
/// Using the same durations and curves is most of what makes a different
/// codebase feel like the same product. The named steps exist so animation
/// choices are picked from a scale rather than invented per call site.
enum Motion {
    /// 120ms. State that should feel immediate: toggles, selection.
    static let instant = Animation.timingCurve(0.25, 1, 0.5, 1, duration: 0.12)

    /// 180ms. Small movements: a row expanding, a badge appearing.
    static let fast = Animation.timingCurve(0.25, 1, 0.5, 1, duration: 0.18)

    /// 240ms. The default for anything that changes layout.
    static let standard = Animation.timingCurve(0.25, 1, 0.5, 1, duration: 0.24)

    /// 500ms on a slower-settling curve. For content arriving on screen for the
    /// first time, where the extra time reads as considered rather than sluggish.
    static let arrival = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.5)

    /// Distance content travels on arrival.
    static let arrivalOffset: CGFloat = 12

    /// Blur content resolves from on arrival.
    static let arrivalBlur: CGFloat = 2
}

/// Buzz's signature entrance: content resolves from blurred, transparent, and
/// slightly low, over 500ms.
struct ArrivalModifier: ViewModifier {
    let isPresent: Bool
    var delay: Double = 0
    /// The scale content grows from. 1 means no scale change, which is the
    /// right default: scaling a paragraph reads as a zoom, not an arrival.
    /// Marks and icons are the exception, and they pass something just under 1.
    var from: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isPresent ? 1 : 0)
            // Motion is the part that causes trouble for people sensitive to it.
            // Fading still reads as an arrival, so the opacity change is kept.
            .blur(radius: isPresent || reduceMotion ? 0 : Motion.arrivalBlur)
            .scaleEffect(isPresent || reduceMotion ? 1 : from)
            .offset(y: isPresent || reduceMotion ? 0 : Motion.arrivalOffset)
            .animation(
                reduceMotion ? .easeOut(duration: 0.2) : Motion.arrival.delay(delay),
                value: isPresent
            )
    }
}

extension View {
    /// Applies the arrival entrance. `delay` staggers items in a list, and
    /// `from` lets a mark grow into place rather than only fading.
    func arrival(_ isPresent: Bool, delay: Double = 0, from scale: CGFloat = 1) -> some View {
        modifier(ArrivalModifier(isPresent: isPresent, delay: delay, from: scale))
    }
}
