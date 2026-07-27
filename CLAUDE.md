# Comb

An iOS client for Nostr NIP-29 group chat, built for Buzz communities.

## Guiding ethos

Every decision is weighed against the Nostr protocol's values. The full
framework lives in `ETHOS.md`; the short version:

1. **You own your identity.** The keypair is the identity. It lives in the
   Keychain with `ThisDeviceOnly`. Never sync, transmit, or copy it without
   explicit opt-in. There is no Comb account and no Comb server.

2. **You choose who you trust.** No relay is hardcoded or privileged. Every
   relay is treated as potentially hostile: events are verified at a single
   choke point (id recomputed, signature checked) before storage.

3. **The protocol is the common ground.** Standard NIP-29 first, Buzz
   extensions as progressive enhancement with graceful fallbacks. A client
   that depends on one vendor's extensions is that vendor's client.

4. **Privacy is structural, not promissory.** No analytics, no crash
   reporting, no push server, no Comb backend. Data that can stay on-device
   stays on-device. A request to an unexpected host is a bug.

5. **Honesty over comfort.** Every limitation is stated in the UI. Do not
   write copy that implies a guarantee the code cannot keep.

6. **Freedom is structural too.** No algorithmic feed. No lock-in. No
   features gated behind a Comb service. If Comb disappeared, the user's
   identity and data would still work with any NIP-29 client.

7. **Simplicity protects decentralization.** Complexity concentrates the
   ecosystem. Prefer doing less, correctly.

When a shortcut would compromise these, the shortcut loses.

## Key files

| Path | What |
|---|---|
| `ETHOS.md` | Full decision-making framework (Nostr values) |
| `DESIGN.md` | Design system reference (tokens, layers, patterns) |
| `.impeccable.md` | Design context (users, brand, aesthetic) |
| `PRIVACY.md` | Privacy policy |
| `SECURITY.md` | Threat model and trust boundaries |
| `CONTRIBUTING.md` | Contribution guidelines |
| `Comb/DesignSystem/` | All design tokens and components |

## Building and testing

Always go through the Makefile. `make test` is the fast loop (all three Swift
packages, no simulator, seconds); `make build-app` builds for the simulator.

Both filter their output down to diagnostics (with their source context),
failures, and the result line. The full untouched log is at
`.logs/<target>.log`, with the previous run kept at `.logs/<target>.log.prev`:
read it when the filtered output is not enough, and only the part you need.
Set `V=1` to stream everything unfiltered. Never call `xcodebuild` or
`swift test` directly, since raw build output runs to hundreds of kilobytes
of compile invocations.

## Architecture

- **Append-only event log.** The `event` table is the source of truth.
  Projections (timelines, profiles, read state) are derived and rebuildable.
- **Single verification choke point.** `EventStore.ingest()` is the only way
  events enter storage. Every event has its id recomputed and signature
  verified.
- **Read-time authorization.** Edits and deletions are stored but authorized
  at read time, where the original author is known.
- **Progressive enhancement.** Buzz-specific kinds (`isBuzzExtension`) have
  graceful fallbacks so the client works against plain NIP-29 relays.

## Conventions

- Dark only. Never propose light mode or a theme picker.
- Native iOS first. System components over custom chrome.
- Design tokens over raw literals. A size, color, or font in a feature view
  is drift.
- Every `Form` section gets `.combRows()`, every `Form` gets `.combForm()`.
- Never grey on colour. Use luminance lifts (`Palette.liftOnGradient`).
- User-facing text is plain and human. No jargon, no em dashes.
