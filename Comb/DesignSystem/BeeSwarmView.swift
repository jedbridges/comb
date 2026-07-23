import SwiftUI

/// A few points of chartreuse light wandering like bees, rendered by the
/// `beeSwarm` Metal shader.
///
/// Atmosphere, not information: it sits behind the welcome content at low
/// intensity, adds light to the gradient rather than drawing on top of it,
/// and disappears entirely under Reduce Motion, because a swarm that never
/// stops moving is exactly what that setting exists to switch off.
struct BeeSwarmView: View {
    /// 0...1. The default is deliberately faint; the swarm should be noticed
    /// on the second look, not the first.
    var intensity: Double = 0.5
    /// Where the swarm gathers, in unit coordinates. Passed in rather than
    /// assumed, so the bees orbit whatever the screen actually centres on
    /// instead of a hardcoded guess that drifts when the layout changes.
    var hive: UnitPoint = .center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            GeometryReader { proxy in
                TimelineView(.animation) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 3600)

                    Rectangle()
                        .colorEffect(
                            ShaderLibrary.beeSwarm(
                                .float2(proxy.size),
                                .float(time),
                                .float(intensity),
                                .float2(hive.x, hive.y)
                            )
                        )
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
