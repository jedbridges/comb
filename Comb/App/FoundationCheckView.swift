import CombCore
import SwiftUI

/// Phase 0 placeholder.
///
/// Its one job is to prove the foundations work on a real device rather than
/// only in `swift test`: CombCore links, libsecp256k1 runs on ARM under the app
/// sandbox, an event signs and verifies, and the design tokens render. It gets
/// deleted the moment there is a real first screen.
struct FoundationCheckView: View {
    @State private var result: CheckResult?
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            Palette.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 24) {
                Mark()
                    .frame(width: 72, height: 72)
                    .arrival(hasAppeared)

                Text("Comb")
                    .font(.system(size: 40, weight: .semibold))
                    .kerning(-0.8)
                    .foregroundStyle(Palette.text)
                    .arrival(hasAppeared, delay: 0.06)

                if let result {
                    VStack(spacing: 8) {
                        Label(result.headline, systemImage: result.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(result.isPass ? Palette.success : Palette.danger)

                        Text(result.detail)
                            .font(.system(size: 13).monospaced())
                            .foregroundStyle(Palette.subtext)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .glassEffect(in: .rect(cornerRadius: 10))
                    .arrival(hasAppeared, delay: 0.12)
                }
            }
            .padding(32)
        }
        .task {
            result = CheckResult.run()
            hasAppeared = true
        }
    }
}

/// Comb's mark: nested honeycomb cells, matching the app icon.
///
/// Deliberately not Buzz's bee, which Apache 2.0 section 6 does not license for
/// reuse. Drawn rather than loaded from the asset catalog so it stays crisp at
/// any size and can be tinted per context.
struct Mark: View {
    /// Ring radii as a fraction of the outer cell, and the color each is filled
    /// with. Taken from the icon artwork.
    private static let rings: [(scale: CGFloat, isInk: Bool)] = [
        (1.00, true),
        (0.48, false),
        (0.245, true),
    ]

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2

            for ring in Self.rings {
                let radius = outer * ring.scale
                let color = ring.isInk ? Palette.ink : Palette.chartreuse
                let path = hexagon(center: center, radius: radius * 0.9)

                context.fill(path, with: .color(color))
                // Stroking the same path with a round join rounds the corners
                // and restores the width lost above, which is cheaper than
                // building an arc-jointed path by hand.
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: radius * 0.22, lineJoin: .round)
                )
            }
        }
        .accessibilityLabel("Comb")
    }

    /// A pointy-top hexagon: vertices at top and bottom, vertical side edges.
    /// The 30 degree offset is what distinguishes it from a flat-top cell.
    private func hexagon(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for corner in 0..<6 {
            let angle = Double(corner) * .pi / 3 + .pi / 6
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            corner == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

private struct CheckResult {
    let isPass: Bool
    let headline: String
    let detail: String

    var symbol: String { isPass ? "checkmark.seal.fill" : "xmark.seal.fill" }

    /// Exercises the full signing path end to end and reports what happened.
    static func run() -> CheckResult {
        do {
            let key = try PrivateKey()
            let event = try NostrEvent.signed(
                kind: .groupChatMessage,
                content: "foundation check",
                tags: [["h", "phase-0"]],
                with: key
            )

            guard event.isValid else {
                return CheckResult(
                    isPass: false,
                    headline: "Signature did not verify",
                    detail: "A freshly signed event failed validation."
                )
            }

            return CheckResult(
                isPass: true,
                headline: "Foundations OK",
                detail: "signed + verified kind 9\nevent \(event.id.prefix(16))…"
            )
        } catch {
            return CheckResult(
                isPass: false,
                headline: "Signing failed",
                detail: String(describing: error)
            )
        }
    }
}

#Preview {
    FoundationCheckView()
}
