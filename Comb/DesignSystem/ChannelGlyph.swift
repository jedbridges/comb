import SwiftUI

/// A channel's badge: a rounded comb cell lifted out of the gradient, carrying
/// a symbol chosen from the channel's name.
///
/// Replaces the initial-in-a-cell. An initial says nothing a reader cannot
/// already see in the title beside it, and it collided with the mark's
/// interior. A symbol tells you what the room is for at a glance, which is the
/// job a list icon actually has.
struct ChannelGlyph: View {
    let name: String
    var size: CGFloat = Sizing.channelCell

    var body: some View {
        ZStack {
            let cell = RoundedCombCell(cornerRadius: size * 0.18)
            // Lift, not paint. The cell has no hue of its own, so it reads the
            // same against the olive at the top of a list and the navy at the
            // bottom. The hairline is what stops it disappearing entirely
            // where the gradient happens to match its own value.
            cell.fill(Palette.glyphLift)
            cell.stroke(Palette.glyphHairline, lineWidth: 0.75)
            Image(systemName: ChannelSymbol.forName(name))
                // Derived from the cell, not the type ramp, and deliberately
                // so: this symbol has to stay in proportion to the hexagon
                // around it at every size the caller asks for. A ramp token
                // would scale independently and break the lockup.
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(Palette.glyphMark)
        }
        // Composited as one badge, so the fill and the hairline cannot be
        // blended separately. The shared modifier is what keeps avatars
        // looking like part of the same system.
        .glyphChrome(size: size)
        // The channel's name is right beside it; the glyph is atmosphere.
        .accessibilityHidden(true)
    }
}

/// A hexagon with rounded corners, drawn as straight runs joined by arcs.
///
/// The corner rounding is what makes the shape read as a soft container rather
/// than a hard geometric mark, and keeps it from competing with the logo.
struct RoundedCombCell: Shape {
    var cornerRadius: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        // Pointy-top, matching the mark and the app icon.
        let corners = (0..<6).map { corner -> CGPoint in
            let angle = Double(corner) * .pi / 3 + .pi / 6
            return CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        }

        var path = Path()
        // Start partway along the first edge so the initial arc has somewhere
        // to land.
        path.move(to: midpoint(corners[0], corners[1]))
        for index in 0..<6 {
            let corner = corners[(index + 1) % 6]
            let next = corners[(index + 2) % 6]
            path.addArc(
                tangent1End: corner,
                tangent2End: midpoint(corner, next),
                radius: cornerRadius
            )
        }
        path.closeSubpath()
        return path
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

/// Picks an SF Symbol from a channel's name.
///
/// Keyword matching, not cleverness: a channel called "jobs" gets a briefcase
/// and everything unrecognised gets the hash that has meant "channel" since
/// IRC. The list is ordered so specific words win over general ones.
enum ChannelSymbol {
    /// Ordered: the first keyword found in the name wins, so "design jobs"
    /// resolves to jobs rather than design.
    private static let rules: [(keywords: [String], symbol: String)] = [
        (["welcome", "intro", "lobby"], "hand.wave"),
        (["general", "chat", "main"], "bubble.left.and.bubble.right"),
        (["announce", "news", "updates"], "megaphone"),
        (["random", "watercooler", "offtopic", "off-topic"], "dice"),
        (["job", "hiring", "career"], "briefcase"),
        (["critique", "feedback", "review"], "eye"),
        (["inspiration", "inspo", "showcase"], "sparkles"),
        (["design", "ui", "ux"], "paintbrush.pointed"),
        (["font", "type", "typography"], "textformat"),
        (["bitcoin", "btc", "sats", "lightning", "zap"], "bolt"),
        (["pay", "money", "finance"], "creditcard"),
        (["industry", "business", "company"], "building.2"),
        (["passion", "project", "side"], "hammer"),
        (["test", "sandbox", "staging"], "flask"),
        (["huddle", "call", "voice", "meet"], "person.3"),
        (["dev", "code", "eng", "engineering", "build"], "chevron.left.forwardslash.chevron.right"),
        (["help", "support", "question", "ask"], "questionmark.circle"),
        (["music", "audio", "sound"], "music.note"),
        (["photo", "image", "picture", "art"], "photo"),
        (["food", "lunch", "coffee"], "fork.knife"),
        (["book", "read", "library"], "book"),
        (["game", "play"], "gamecontroller"),
        (["event", "calendar", "schedule"], "calendar"),
        (["link", "resource", "bookmark"], "link"),
        (["bug", "issue", "triage"], "ladybug"),
        (["idea", "brainstorm"], "lightbulb"),
        (["team", "people", "member"], "person.2"),
        (["private", "secret"], "lock"),
    ]

    static func forName(_ name: String) -> String {
        let lowered = name.lowercased()
        for rule in rules where rule.keywords.contains(where: lowered.contains) {
            return rule.symbol
        }
        // The channel sigil since IRC.
        return "number"
    }
}
