# TestFlight notes — 0.2.0 (build 12)

Paste the block below into App Store Connect → TestFlight → **What to Test**.
Everything under the rule is the tester-facing text; nothing above it goes in.

---

**This is the first build of Comb that can move real money. Please read this before connecting anything.**

**New: tipping (zaps)**
Press and hold any message to send its author a few sats. The tip appears on the message itself, so you can see what a message has been tipped. You can also tip someone from their profile, or from the top of a one-to-one conversation.

Without a wallet connected, Comb hands an invoice to a Lightning wallet app on your iPhone and never learns whether you paid it. That is why a tip sits as "Waiting" rather than showing a number.

**New: connecting a Lightning wallet (optional)**
Settings → Lightning wallet → paste the connection string your wallet gives you. Tips are then paid inside Comb, and Comb can tell you the payment actually went through.

Two things to know before you try it:

- There is **no second confirmation**. Choosing an amount and tapping the button pays it. That is deliberate, and it is the thing to know first.
- **Use a throwaway connection with a small cap**, a few hundred sats. Most wallets let you create an app connection with its own budget. Please do not connect your main wallet to a test build.

Start with 1 sat. Tap "Other" to enter it; the buttons start at 21.

**New: allowances for agents**
You can give another member an allowance to tip on your behalf, capped per tip and per day, from the member list of a channel. Settings → Agent spending shows what has been spent and what was refused, and stops any allowance in one tap.

Nothing can actually use an allowance yet, so there is nothing to test here beyond the screens. It is in the build because the safety rules around it are worth reviewing.

**What we most want to hear about**

1. Anything that takes money without clearly saying so. This is the most important bug you can report.
2. A tip that says it was paid when it was not, or the reverse.
3. Anything confusing about what a tip total means.
4. Wallets that will not connect, and the exact message you saw.

**Known, please do not report**

- Tips usually stay on "Waiting" unless you have connected a wallet. Most Lightning providers do not support the check Comb would need to confirm payment on its own.
- Tip totals can read lower than what was really sent. Comb counts only what it has been told about.
- The demo cast in this build points at real addresses that may refuse small amounts.

Comb never holds your balance, and the wallet connection stays on this iPhone. You can revoke it in your wallet at any time, and disconnecting removes it here.

---

## Not for testers

Internal reminders while filling in App Store Connect:

- Export compliance should auto-clear: `ITSAppUsesNonExemptEncryption = NO` is declared, and the only crypto is TLS plus secp256k1 for signatures.
- Beta App Review is only needed for external testers. Internal testers get the build as soon as processing finishes.
- The "what we most want to hear about" list is deliberately ordered by blast radius, not by likelihood.
- If a tester reports money moving without a prompt, that is expected behaviour with a wallet connected, not a bug. It is called out above so nobody is surprised, but be ready to answer it more than once.
