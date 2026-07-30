# Release notes

Newest first. Each entry carries the App Store / TestFlight blurb, the internal
detail behind it, and what was deliberately left undone.

## Version 0.2.0 (Build 12) — 2026-07-30

### What's New (App Store Connect blurb)

You can tip people now. Press and hold a message to send its author a few sats,
and see what a message has been tipped on the message itself. Connect a Lightning
wallet and tips are paid without leaving Comb, so it can tell you the payment
actually went through. You can also give an agent an allowance to tip on your
behalf, capped per tip and per day, and stop it at any time.

### TestFlight tester notes

**This is the first build of Comb that can move real money.** Please read this
before connecting anything.

- Zaps work without a wallet connection: Comb hands an invoice to a Lightning
  wallet app on your iPhone and never learns whether you paid it.
- If you connect a wallet in Settings, Comb pays invoices **in place, with no
  second confirmation step**. Choosing an amount and tapping the button is the
  whole flow. That is deliberate, and it is also the thing to know before you
  try it.
- **Use a throwaway wallet connection with a small cap** (a few hundred sats).
  Most wallets let you create an app connection with its own budget. Do not
  connect your main wallet to a TestFlight build.
- Start with 1 sat. The amounts on offer start at 21.
- Agent allowances are untested by any real agent. Nothing in the app can publish
  a spend request yet, so this path has only ever been exercised by unit tests.

If something takes money and does not say so, that is the most important bug you
can report.

### Internal notes

**Zaps, end to end.** The receive half had been stranded on an unmerged branch
since before 0.1.0; it is now on main along with everything built on top of it.

- `CombCore/Zap.swift` — receipt verification split into `decodeReceipt` (offline,
  runs in the projector) and `verifyReceipt` (needs the issuer key, runs at read
  time). Same shape as edits and deletions: record the claim, judge it where the
  evidence is.
- `CombStore/Zaps.swift`, `Schema.swift` — a `zap` projection with a unique index
  on bolt11 as the replay defence, plus `zap_attempt` and `lnurl_issuer` as
  local-only tables. Projection version 7 → 9.
- `Comb/Features/Timeline/Zap*.swift` — the sheet, the presenter, the zappers
  list, and the chips on a message row.

**Sender-attested zaps (kind 40004).** Standard NIP-57 cannot work on a
membership-gated Buzz relay: an LNURL provider is not a member, so its receipt is
refused and the tally stays empty forever. The payer now publishes the proof
instead. A BOLT-11 invoice commits to a payment hash and the preimage is revealed
only on settlement, so `sha256(preimage) == payment_hash` is settlement, checkable
by anyone offline with no third party. `CombCore/Bolt11.swift` decodes exactly two
facts and skips everything else; it is tested against BOLT-11's own published
vectors rather than invoices this repo made.

**Nostr Wallet Connect (NIP-47).** `CombNet/NWCSession.swift` is modelled on
`PairingSession`, not `RelaySession`: every call on the latter waits for a NIP-42
challenge that a wallet relay never sends, so each would hang for thirty seconds
and throw. NIP-44 only — NIP-47 says a wallet advertising no `encryption` tag
supports only NIP-04, and NIP-04 is AES-CBC with no authentication, which is not
something to carry spend authorisation over. The credential lives in its own
Keychain service so "forget my wallet" and "forget my identity" cannot delete each
other.

**Agent spending allowances (kind 40005).** An agent is a pubkey in the roster and
holds no credential: it publishes a request, and the funder's device decides
against a grant the agent cannot read or forge. Two dials, a rolling-window
allowance and a per-tip ceiling, and deliberately no approve-each-spend prompt,
because a stream of approvals is one people learn to wave through. Six safety
rails are unit-tested and the replay guard is mutation-tested. `spend_grant` and
`spend_ledger` are local-only and outside the projection tables, so a rebuild
cannot invent permission to spend.

**Privacy fix carried in.** `LNURLClient` was using `URLSession.shared`, which
accepts cookies into the shared store and caches by ETag, so a wallet provider
could have linked one zap to the next across launches and communities. Now an
ephemeral session that keeps nothing, matching what third-party images already
got in `a4e81a0`.

**Version bump**: 0.1.2 → 0.2.0, build 11 → 12.

### Release checklist

- [ ] `make export DEVELOPMENT_TEAM=…` and upload via Transporter or Organizer
- [ ] Export compliance auto-clears (`ITSAppUsesNonExemptEncryption = NO`)
- [ ] Paste the tester notes above into TestFlight "What to Test"
- [ ] Run `docs/ZAP-TESTING.md` once against a real wallet before inviting testers
- [ ] Tag pushed: `git push origin v0.2.0`

### Known gaps

- **No real money has moved through any of this.** Every test is against a fake
  wallet. `docs/ZAP-TESTING.md` is the run that would change that and has not been
  done.
- **Agent allowances have never been exercised by a real agent.** Nothing can
  publish a kind 40005 yet.
- **Kinds 40004 and 40005 are unconfirmed against a real Buzz relay.** The fake
  models no kind allowlist and Comb already ships kind 40003, so the risk is low
  but it is not measured.
- **The deep-link path mostly cannot attest.** Sampled against real providers,
  neither `opensats@vlt.ge` nor `damus@sendsats.lol` implements LUD-21 `verify`,
  so a zap handed to a wallet app cannot learn its own preimage and stays a
  pending marker until it expires. Tallies lean on NIP-47 in practice.
- **A refused agent is told nothing.** Publishing a refusal would publish the
  reader's budget to the room. An encrypted reply to the agent alone is the
  obvious improvement and is not built.
- **`design/text-roles-and-contrast` is still unmerged**, holding the typography
  overhaul and channel create/join/leave. Its zap commits now conflict with main.
- Contrast has still never been measured on device, and VoiceOver has still never
  been run end to end. Both predate this release.
