# Testing zaps with real money

Everything in the zap feature is covered by tests, and none of those tests move
money. This is the run that does.

Do it once. It is the only way to know that Comb's idea of NIP-47 matches a real
wallet's, and that a preimage really does come back and turn into an attestation
the channel can verify.

## The one rule

**Never put a wallet connection string anywhere but the app.**

`nostr+walletconnect://…` is a spend credential. It signs every request and it is
the whole of the permission. Type it into Settings on the device and nowhere
else: not into a shell, not into a commit, not into a chat with an assistant, not
into a note. Comb puts it straight into the Keychain under its own service,
`ThisDeviceOnly` and never synchronised.

A Lightning **address** is the opposite: `you@example.com` is public by design,
like an email, and is safe to pass on a command line. That asymmetry is why
`--zap-to` exists and there is no `--wallet` to match it.

## Before you start

Make a throwaway connection rather than using your main one. In Alby Hub or
similar, create a new app connection capped at a few hundred sats. If anything
here is wrong, that cap is what limits the cost.

## 1. Build and launch with a payable recipient

The demo cast normally gets invented `@getalby.com` addresses, most of which do
not exist, so nothing in it can be paid. `--zap-to` points the whole cast at one
real address.

```bash
make build-app
```

```bash
xcrun simctl launch booted dev.jedbridges.comb --demo --zap-to opensats@vlt.ge
```

Verified payable and Nostr-zap capable on 2026-07-29, minimum 1 sat:

| Address | Who |
|---|---|
| `opensats@vlt.ge` | OpenSats, which funds Nostr work |
| `damus@sendsats.lol` | Damus |
| `hrf@btcpay.hrf.org` | Human Rights Foundation |

These are donation addresses, so a test sat is a small donation rather than money
sent to a stranger. Use your own address instead if you would rather pay
yourself.

## 2. Connect the wallet

Settings (gear, top right) → **Lightning wallet** → paste into the field → **Connect
wallet**.

Comb checks the wallet before saving, so this can fail for a reason worth reading:

| What it says | What it means |
|---|---|
| does not look like a wallet connection string | wrong string, or only part of it |
| only supports an older encryption | the wallet speaks NIP-04 only, and Comb will not use it for payments |
| Nothing answered on that wallet's relay | the connection was revoked, or the relay is down |
| relay is not encrypted | the URI names a `ws://` relay, which a credential must not travel over |

Success looks like the field being replaced by **Agent spending** and
**Disconnect wallet**.

## 3. Pay one sat

Open **General**, long-press any message, tap **Zap**, choose **Other**, enter
`1`, tap **Zap 1 sat**.

What should happen, in order:

1. The button reads **Paying…**
2. Then a chartreuse bolt and **Paid 1 sat to Ray**
3. Back in the timeline, a zap chip appears on that message showing `1`

Step 3 is the one that proves the most. It means the preimage came back, the
attestation was built, `verifyAttestation` accepted it, and the projector counted
it. That is the whole sender-attested design working, and it is the half that
cannot work at all through a `lightning:` handoff.

Long-press the chip to see who zapped. The footer should say every zap here came
with proof that it was paid.

## 4. What to report back

- Whether the connection succeeded, and the exact message if not
- Whether **Paid** appeared, or which state it stopped at
- Whether the chip appeared on the message
- Anything the wallet said that Comb rendered oddly

## Known gaps this run does not cover

**Agent allowances still cannot be tested this way.** They need an agent
publishing a kind 40005 into a channel, and the demo has no agent. The decision
logic has 17 unit tests and the six safety rails are covered, but no real process
has ever asked Comb for money.

**The deep-link path mostly cannot attest.** Sampled on 2026-07-29, neither
`opensats@vlt.ge` nor `damus@sendsats.lol` returns a LUD-21 `verify` URL, so a
zap handed to a wallet app cannot learn its own preimage and stays a pending
marker until it expires. Attestation leans on NIP-47 in practice. This is honest
behaviour, not a bug, but it does mean a connected wallet is what makes tallies
work rather than a nice-to-have.

**Kinds 40004 and 40005 are unconfirmed against a real Buzz relay.** The fake
models no kind allowlist and Comb already ships kind 40003, so the risk is low.
`make relay-up` would settle it and needs a container runtime installed.
