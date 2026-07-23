import SwiftUI

/// The swarm that leaves a reaction chip when you join a pile.
///
/// Comb already has one piece of motion identity, the bees orbiting the mark on
/// the welcome screen, and this is deliberately the same idea attached to the
/// app's most-tapped control: a handful of copies of the emoji scatter upward,
/// each on its own arc, and fall back out of sight.
///
/// Drawn in a single `Canvas` rather than as a dozen SwiftUI views. Twelve
/// animated views inside a row inside a lazy stack is twelve pieces of layout
/// per frame, in a scroll view that is also doing real work; one canvas is one.
struct ReactionBurst: View {
    let emoji: String
    let particles: [BurstParticle]
    /// When the burst began. Elapsed time is measured from here rather than
    /// from the view appearing, so a burst is not restarted by a redraw.
    let start: Date

    /// How far the swarm can travel. The canvas clips, so this has to cover the
    /// fastest particle's whole flight or the swarm loses its outermost bees to
    /// a hard edge.
    static let size = CGSize(width: 280, height: 260)

    var body: some View {
        TimelineView(.animation(paused: false)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                // Resolved once per frame, not once per particle: resolving
                // text is the expensive part and every clone draws the same
                // glyph.
                let resolved = context.resolve(
                    Text(String(emoji.prefix(2))).font(.system(size: Self.glyphSize))
                )
                let origin = CGPoint(x: size.width / 2, y: size.height / 2)

                for particle in particles {
                    guard let frame = particle.state(at: elapsed) else { continue }

                    context.drawLayer { layer in
                        layer.opacity = frame.opacity
                        layer.translateBy(
                            x: origin.x + frame.offset.width,
                            y: origin.y + frame.offset.height
                        )
                        layer.rotate(by: .degrees(frame.rotation))
                        layer.scaleBy(x: frame.scale, y: frame.scale)
                        layer.draw(resolved, at: .zero, anchor: .center)
                    }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Atmosphere over a control: it must never eat a tap meant for the
        // chip underneath it.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let glyphSize: CGFloat = 22
}

/// One emoji in flight.
///
/// Every value is fixed at spawn and the position is a closed-form function of
/// elapsed time, so the swarm can be drawn at any frame rate, dropped frames
/// included, without integrating a simulation that would then depend on how
/// often it was asked.
struct BurstParticle: Identifiable {
    let id = UUID()
    /// Launch direction in canvas coordinates, where y grows downward, so
    /// upward is negative.
    let angle: Double
    let speed: Double
    /// Degrees per second. Signed, so the swarm tumbles both ways.
    let spin: Double
    let scale: Double
    let lifetime: Double
    /// A few milliseconds of stagger. Without it twelve clones leave in one
    /// rigid sheet, which reads as a graphic rather than as a swarm.
    let delay: Double

    /// Air drag, as an exponential decay on velocity. This is what keeps the
    /// swarm from looking like it was fired out of a cannon: the clones lose
    /// their speed early and the arc settles rather than continuing straight.
    private static let drag: Double = 2.2
    private static let gravity: Double = 780

    struct Frame {
        let offset: CGSize
        let rotation: Double
        let scale: Double
        let opacity: Double
    }

    /// Where this particle is, or nil once it has finished.
    func state(at elapsed: TimeInterval) -> Frame? {
        let t = elapsed - delay
        guard t > 0, t < lifetime else { return nil }

        // Position under drag: the integral of v0 * e^(-kt), plus gravity
        // pulling straight down independent of it.
        let travelled = (1 - exp(-Self.drag * t)) / Self.drag
        let x = cos(angle) * speed * travelled
        let y = sin(angle) * speed * travelled + 0.5 * Self.gravity * t * t

        let progress = t / lifetime

        // Small clones fade first, so the cloud thins from the outside in
        // rather than switching off all at once.
        let fadeStart = 0.3 + 0.3 * scale
        let fade = progress < fadeStart
            ? 1
            : 1 - (progress - fadeStart) / (1 - fadeStart)

        // Scales up out of nothing over the first 90ms, cubic ease-out, so
        // each clone arrives rather than appearing.
        let entry = min(1, t / 0.09)
        let eased = 1 - pow(1 - entry, 3)

        return Frame(
            offset: CGSize(width: x, height: y),
            rotation: spin * t,
            scale: scale * (0.4 + 0.6 * eased),
            opacity: pow(max(0, fade), 1.6)
        )
    }

    /// A swarm: an upward cone, with every clone given its own everything.
    ///
    /// The cone is wide (120 degrees) but never sideways or down, because a
    /// reaction should read as leaving the chip, not spilling off it.
    static func swarm(count: Int = 12) -> [BurstParticle] {
        (0..<count).map { _ in
            BurstParticle(
                angle: .random(in: (-150 * .pi / 180)...(-30 * .pi / 180)),
                speed: .random(in: 160...330),
                spin: .random(in: -260...260),
                scale: .random(in: 0.45...1.0),
                lifetime: .random(in: 0.55...0.85),
                delay: .random(in: 0...0.06)
            )
        }
    }

    /// The longest any swarm can last, for scheduling the teardown.
    static let maxDuration: TimeInterval = 0.95
}
