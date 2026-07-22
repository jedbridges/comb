# Comb design system

The single place UI decisions live. Feature views compose tokens and
components from `Comb/DesignSystem/`; a raw size, color, font, or radius
literal inside a feature view is drift and gets moved here.

## Files

| File | Owns |
|---|---|
| `Palette.swift` | Color. Brand pair, surfaces, content, semantic, the gradient. |
| `Typography.swift` | The type ramp and letterspacing. |
| `Layout.swift` | Spacing scale, corner radii, fixed sizes. |
| `Motion.swift` | Durations, easing curves, the arrival entrance. |
| `Components.swift` | Recurring assemblies: cards, fields, buttons, notices, avatars. |

## Where the values come from

The palette, type scale, spacing grid, radii, and motion timings are ported
from the Buzz codebase so Comb reads as part of the same world:
`desktop/src/shared/styles/globals/{theme,motion,components}.css` and
`mobile/lib/shared/theme/`. The bee mark and the Buzz name are not used;
Apache 2.0 withholds trademark rights, and Comb's honeycomb mark is its own.

## Rules

**Native first, always.** System components are the default: `Form`, `List`,
`Section`, `TextField`, standard navigation, context menus, the `.glass`
button styles. Custom chrome exists only where the product IS the chrome: the
message timeline, the compose bar, the mark. If Apple ships a control that
does the job, the system version wins over a hand-drawn one. This is what
makes Comb read as a real iOS app, it is where accessibility comes from, and
it is the future-proofing: when iOS 27 lands, apps built from system
components and semantic styles inherit the new design language by rebuilding
against the new SDK, while hand-drawn chrome stays frozen in the old one.
Hand-built input boxes are specifically forbidden; that mistake has already
been made and removed once.

**Type scales with the user.** Tokens map to Apple's semantic text styles, so
Dynamic Type works everywhere by construction. `Typography.body` is 16pt at
the default setting, Buzz's chat base size, and grows when the user asks.
Never `.system(size:)` in a feature view.

**Spacing comes off the scale.** 2/4/8/12/16/20/24/32/40. An 18 or a 9 in a
view is a bug. A design that genuinely needs a new step adds a named token.

**One primary action per screen.** `PrimaryButton` is chartreuse on ink, and
its authority depends on scarcity. Everything else is `SecondaryButton` or
quieter.

**Chartreuse is the scarcest resource.** The brand yellow marks the single
most important thing on a screen: the primary action, your own reaction, the
send button. If it appears three times on one screen, one of them is wrong.

**Motion means something.** `Motion.arrival` (500ms, blur-and-rise) is for
content appearing for the first time. `Motion.standard` (240ms) for layout
changes. `Motion.instant` (120ms) for state flips. Reduce Motion collapses
movement but keeps fades.

**Components are born on the second use.** A pattern appearing on two screens
becomes a component; a third copy is where drift starts.

## Changing things

Tweak the token, not the call sites. That is the entire point: adjusting
`Radii.card` or `Palette.chartreuse` restyles every screen at once, and a
design review is a diff of one file.
