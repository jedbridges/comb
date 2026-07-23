import SwiftUI

/// The welcome-screen logo. Uses the bundled `WelcomeSymbol` artwork when it is
/// present, and falls back to the drawn mark so the build is never blocked on an
/// asset the designer has not dropped in yet.
struct WelcomeSymbol: View {
    var body: some View {
        if UIImage(named: "WelcomeSymbol") != nil {
            Image("WelcomeSymbol")
                .resizable()
                .scaledToFit()
        } else {
            Mark()
        }
    }
}

/// A single honeycomb cell, as a `Shape`.
///
/// For anything that needs the brand's silhouette as a container: channel
/// avatars, badges, placeholders. Distinct from `Mark`, which is the logo and
/// has its own interior detail. Putting content on top of `Mark` collides with
/// that detail; that mistake was made in the channel list and removed.
struct CombCell: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        var path = Path()
        for corner in 0..<6 {
            // Pointy-top, matching the mark and the icon.
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
