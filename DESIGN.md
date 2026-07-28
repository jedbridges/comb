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

**Type scales with the user.** Roles map to Apple's semantic text styles, so
Dynamic Type works everywhere by construction. `.body` is 16pt at the default
setting, Buzz's chat base size, and grows when the user asks. Never
`.system(size:)` in a feature view.

**One decision per piece of text.** Set type with `.textRole(_:)`, which
carries the colour with it. A `.font()` beside a `.foregroundStyle()` in a
feature view is drift: it is two dials where there should be one, and a role
whose colour is chosen separately on each screen is not a role.

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

**Never grey on colour.** A grey fill or grey text over the gradient reads
washed out, because the grey fights the hue behind it. Use a luminance shift
(`Palette.liftOnGradient`, white at low opacity) which preserves hue, or a
shade of the background itself. Chrome riding on the gradient uses
`.luminousChrome()`, which blends with `plusLighter` in dark and `plusDarker`
in light.

**Components are born on the second use.** A pattern appearing on two screens
becomes a component; a third copy is where drift starts.

## Visual layers

Every screen in Comb is built from the same stack of layers, bottom to top.
Getting the layers right is what keeps screens feeling like one app instead
of a collection of views taped together.

### 1. Gradient backdrop

The full-screen olive-to-blue wash, edge to edge, behind everything.

- Dark: `#2B280C` (olive) to `#0A1423` (navy), eased with smoothstep
- Built from 17 stops, mixed in linear light to avoid the muddy mid-band
  that two-stop sRGB blending produces
- Applied via `Palette.backgroundGradient.ignoresSafeArea()` on raw
  `ZStack` screens, or automatically by `.combForm()` on Form screens

### 2. Luminance lifts (surfaces on the gradient)

Surfaces sitting on the gradient never use an opaque grey fill. Grey
fights the hue behind it and reads washed out. Instead, surfaces use a
pure lightness shift: white at low opacity. The surface stays olive at
the top and blue at the bottom, exactly like the gradient it sits on.

| Token | Value | Use |
|---|---|---|
| `Palette.liftOnGradient` | `Color.white.opacity(0.07)` | Row fills, card fills, chip backgrounds |
| `Palette.hairlineOnGradient` | `Color.white.opacity(0.10)` | Borders on lifted surfaces, dividers |
| `Palette.controlFill` | black 0.08 / white 0.12 (adaptive) | Quiet control fills, media wells |
| `Palette.glyphLift` | black 0.07 / white 0.10 (adaptive) | Channel badges, avatar stand-ins |
| `Palette.glyphHairline` | black 0.12 / white 0.14 (adaptive) | Badge and avatar edges |

### 3. Text on the gradient

Fixed values, no blend. Text colour must not depend on what happens to be
scrolled behind it.

There used to be a `.luminousChrome()` modifier here that blended text with
`plusLighter` in dark and `plusDarker` in light, on the theory that chrome
should sit *in* the gradient rather than on top of it. It was removed. In a
scrolling view the blend makes one element render as several: a timestamp came
out brighter than the name beside it under the navigation bar and dim by the
bottom of the same screen, and a single date pill read as three different
components going down one timeline. `Palette.chrome` had already been fixed
for exactly this reason on toolbar glyphs; the rest of the app now follows.

What actually reconciles cool text with a warm backdrop is the text colour
itself, which is why `text` and `subtext` are warm near-neutrals rather than
Catppuccin's blues. See the note on those tokens in `Palette.swift`.

### 4. Glass (Liquid Glass controls)

Buttons and interactive controls use the system `.glass` and
`.glassProminent` button styles. `PrimaryButton` tints glass with
chartreuse; everything else uses plain glass.

### 5. Content (text and images)

| Token | Hex (dark) | Use |
|---|---|---|
| `Palette.text` | `#DEDCD2` | Primary reading text |
| `Palette.subtext` | `#B8B5A8` | Secondary, timestamps, hints |
| `Palette.faint` | `#B1AD9F` | Receding: quiet channels, tombstones, standing context |
| `Palette.chartreuse` | `#D7D700` | The brand accent, used sparingly |
| `Palette.ink` | `#231E1E` | Text on chartreuse fills |
| `Palette.chrome` | `#F1EDDB` (dark) | Toolbar glyphs, fixed warm off-white |

### Contrast, measured

Worst case across the whole gradient, including over a `liftOnGradient` row
and a `controlFill` control, in dark mode. Measured rather than estimated,
because the ethos asks for AA verified rather than assumed.

| Token | Worst ratio | AA body (4.5) |
|---|---|---|
| `chrome` | 8.69 | pass |
| `text` | 7.42 | pass |
| `warning` | 7.07 | pass |
| `chartreuse` | 6.62 | pass |
| `success` | 6.36 | pass |
| `glyphMark` | 5.19 | pass |
| `danger` | 5.17 | pass |
| `subtext` | 4.96 | pass |
| `faint` | 4.54 | pass |
| `ink` on chartreuse | 10.67 | pass |

**Every text token clears WCAG AA for body text.** Two changes bought that,
and both were structural rather than cosmetic.

The olive end of the gradient went from `#4A4616` to `#2B280C`. A backdrop's
luminance sets the ceiling on how many readable text tiers can sit on it, and
at 0.059 there was room for two where the design wanted three: `subtext` sat
at 3.32:1 and the accent itself at 4.43:1 with nowhere to go. Every ratio in
the app is measured against this wash, so darkening it was the one change
that moved all of them at once.

`danger` went from `#ED8796` to `#F2A3AE`. At 2.77:1 it was the lowest ratio
in the app, on the copy that matters most at the moment it appears.

`faint` has the least room, at 4.54. It is about a tenth of a luminance step
under `subtext` rather than the half-step the eye would prefer. That is the
honest limit of a third tier on this backdrop, and it is why the tier means
*receding* and not *hidden*.

### 6. Semantic color

| Token | Hex (dark) | Use |
|---|---|---|
| `Palette.danger` | `#F2A3AE` | Destructive actions, errors |
| `Palette.success` | `#A6DA95` | Confirmations, checkmarks |
| `Palette.warning` | `#EED49F` | Caution states |

## Token reference

### Spacing (`Space`)

| Token | Value | Use |
|---|---|---|
| `.hairline` | 2pt | Hairline separations |
| `.xxs` | 4pt | Between a label and its value |
| `.xs` | 8pt | Within a control |
| `.sm` | 12pt | Between related elements |
| `.md` | 16pt | Between groups, default card padding |
| `.lg` | 20pt | Screen edge insets |
| `.xl` | 24pt | Between sections |
| `.xxl` | 32pt | Major vertical rhythm |
| `.xxxl` | 40pt | Hero breathing room |

### Corner radii (`Radii`)

| Token | Value | Use |
|---|---|---|
| `.chip` | 6pt | Chips and small tags |
| `.control` | 8pt | Fields and inline controls |
| `.bubble` | 10pt | Message-adjacent surfaces, form rows |
| `.card` | 16pt | Cards and grouped lists |
| `.sheet` | 24pt | Sheets, dialogs, compose bar shell |
| `.composeField` | 16pt | Compose field (concentric with `.sheet`) |

### Stroke widths (`Stroke`)

| Token | Value | Use |
|---|---|---|
| `.fine` | 0.5pt | Dividers on raised surfaces |
| `.hairline` | 0.75pt | Edges on glyphs sitting directly on the gradient |

### Fixed sizes (`Sizing`)

| Token | Value | Use |
|---|---|---|
| `.avatar` | 34pt | Avatars in message timelines |
| `.channelCell` | 38pt | Channel cells in lists |
| `.heroMark` | 80pt | The mark on cold-start and empty states |
| `.inlineMark` | 48pt | The mark as an accent |
| `.thumbnail` | 64pt | Pending attachment thumbnails |
| `.hitTarget` | 44pt | Minimum hit target, per Apple HIG |
| `.compactControl` | 32pt | Small controls inside full-size targets |

### Text roles (`TextRole`)

**Use `.textRole(_:)`, not `.font()` plus `.foregroundStyle()`.** The role
sets size, weight, letterspacing and colour together, so a call site makes
one decision instead of three. That is the whole mechanism: hierarchy is
expressed by role, once, rather than by size in one view and colour in
another.

| Role | Size | Colour | Use |
|---|---|---|---|
| `.display` | 34 semibold | text | App name on cold-start screens |
| `.title` | 22 semibold | text | Screen titles in content |
| `.action` | 17 semibold | text | The screen's primary action |
| `.body` | 16 | text | Chat messages, primary reading text |
| `.bodyStrong` | 16 semibold | text | Emphasis, author names, row titles |
| `.bodyItalic` | 16 italic | faint | Tombstones |
| `.control` | 16 medium | text | Inline and secondary controls |
| `.support` | 13 | subtext | Previews, explanations, empty states |
| `.supportStrong` | 13 medium | subtext | Notices, hints, link-outs |
| `.meta` | 11 | subtext | Timestamps, counts, metadata |
| `.metaStrong` | 11 medium | text | Metadata picked out of a line of it |
| `.count` | 11 mono digits | subtext | Numbers that change in place |
| `.eyebrow` | 11 semibold | subtext | Section labels |
| `.mono` | 16 mono | text | Relay URLs, keys |
| `.monoSupport` | 13 mono | subtext | Log entries, identifiers |

Six sizes: 34 / 22 / 17 / 16 / 13 / 11. No two are a point apart. The ramp
this replaced had eight sizes and twenty tokens, twelve of them crowded into
the 16/15 and 13/12 bands, where the choice between two tokens rendering a
point apart at the same weight could only ever be a coin flip. It came up
differently on every screen.

An author's name is `.bodyStrong`: the same size as the message it
introduces, distinguished by weight. It used to be a size *below* the
message, which is a header in name only.

### Tones (`TextTone`)

The second argument to `.textRole(_:_:)`, for when the same role means
something different here. A closed set, so a screen cannot invent a shade.

| Tone | Use |
|---|---|
| `.primary` | Reading text |
| `.muted` | Demoted text |
| `.faint` | Present but receding: a quiet channel, a tombstone |
| `.brand` | The accent. One per screen |
| `.onBrand` | A label on a chartreuse fill |
| `.chrome` | Toolbar and bar-button glyphs |
| `.danger` / `.success` / `.warning` | Semantic state |

`Typography` still holds the fonts themselves, for the few places that need
a `Font` rather than a view modifier (`AttributedString`, mostly).

### Letterspacing (`Kerning`)

| Token | Value | Use |
|---|---|---|
| `.display` | -0.8 | Large display text tightens |
| `.title` | -0.4 | Title text |
| `.eyebrow` | 0.6 | Small semibold labels open up |

### Motion (`Motion`)

| Token | Duration | Use |
|---|---|---|
| `.instant` | 120ms | State flips: toggles, selection |
| `.fast` | 180ms | Small movements: row expanding, badge appearing |
| `.standard` | 240ms | Default for layout changes |
| `.arrival` | 500ms | Content appearing for the first time (blur + rise) |

All use the same timing curve `(0.25, 1, 0.5, 1)` except `.arrival`
which uses `(0.16, 1, 0.3, 1)` for a slower settle.

### Haptics (`Haptics`)

| Token | Feedback | Use |
|---|---|---|
| `.send` | light impact, 0.5 | Message sent |
| `.reaction` | solid impact, 0.75 | Adding a reaction |
| `.reactionSettles` | soft impact, 0.4 | Swarm settling, a beat after reaction |
| `.failure` | `.error` | Something the reader asked for did not happen |
| `.milestone` | `.success` | Community joined, device paired, code recognised |

Haptics fire only for actions the reader took, never for events that
merely arrive. A busy channel must never vibrate in a pocket.

## Component patterns

### Form screens

Every `Form`-based screen follows this pattern:

```swift
Form {
    Section {
        // rows
    }
    .combRows()    // luminance-lift row background

    Section("Header") {
        // rows
    }
    .combRows()    // every section needs this
}
.combForm()        // gradient backdrop + hidden scroll background + soft edges
```

`.combForm()` hides the default opaque Form background, paints the
gradient, and adds soft scroll edges. `.combRows()` replaces each
section's default grey row fill with the luminance lift. Both are
required on every Form screen, and every Section in it.

### Scroll screens (non-Form)

```swift
ZStack {
    Palette.backgroundGradient.ignoresSafeArea()
    ScrollView {
        // content
    }
    .softScrollEdges()
}
```

### Chips and tags

`.combChip()` gives any view the capsule-pill treatment: luminance lift,
hairline border, luminous chrome blend. Used for date breaks, small
floating labels, and metadata tags.

### Cards

`GlassCard` wraps content in glass with `Radii.card` corners and
`Space.md` padding. For grouped content that needs a container on the
gradient.

### Glyphs (channel badges and avatars)

Channel badges and avatar stand-ins share the same visual treatment:
lift fill, hairline edge, chartreuse mark. The shape is the only
difference (comb cell vs. circle). Use `Palette.glyphLift`,
`Palette.glyphHairline`, `Palette.glyphMark`.

## Context

`ETHOS.md` carries the Nostr values that every decision is weighed against:
user-owned identity, structural privacy, protocol-first design, honesty in
UI copy. Read it before proposing a feature; it is the north star.

`.impeccable.md` carries the design context: who uses Comb, the brand's
voice, the anti-references, and the calls on density, motion, and the
accessibility bar. Read it before a design pass; this file is the how,
that one is the why.

## Changing things

Tweak the token, not the call sites. That is the entire point: adjusting
`Radii.card` or `Palette.chartreuse` restyles every screen at once, and a
design review is a diff of one file.
