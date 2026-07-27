# Comb ethos

The Nostr protocol's values are Comb's values. Every feature, every design
decision, every line of copy is weighed against them. When two options are
otherwise equal, the one that better serves these principles wins. When a
shortcut would compromise one, the shortcut loses.

This is not a mission statement. It is a decision-making framework.

## The principles

### 1. You own your identity

Your identity is a keypair you generated. No company issued it, no server
hosts it, no authority can revoke it. Comb stores it in the Keychain with
`ThisDeviceOnly` and never copies it anywhere, because the README promises
"your keys never leave your phone" and the code must keep that promise.

What this means for decisions:

- Never sync, backup, or transmit the private key without explicit,
  informed, opt-in consent. Silent iCloud Keychain sync is a betrayal,
  not a convenience feature.
- Never tie identity to an email, phone number, or external account.
  The keypair is the identity, full stop.
- Never build a "Comb account." There is no Comb server and there must
  never be one.
- When the key is lost, the identity is lost. Say so honestly. Do not
  pretend recovery is easy, and do not build custodial shortcuts that
  undermine the sovereignty they claim to protect.

### 2. You choose who you trust

Nostr's relay model means you decide which servers hold your data and
whose data you read. No relay is privileged, bundled, or hardcoded. The
protocol does not decide what speech is acceptable; individual relays do,
transparently, and you choose which to connect to.

What this means for decisions:

- Never hardcode a relay URL. The community index is a discovery aid,
  not a dependency. The app must work against any NIP-29 relay.
- Never phone home. No analytics endpoint, no crash reporter, no push
  notification server operated by Comb. If data leaves the device, the
  user chose to send it to a relay they chose.
- Treat every relay as potentially hostile. Verify every event's id
  (recomputed from contents) and signature (checked against the claimed
  pubkey) at a single choke point before it enters storage.
- Authorize edits and deletions at read time, where the original
  author is known, not at write time where the relay's claim is the
  only evidence.

### 3. The protocol is the common ground

Nostr's power comes from being an open protocol anyone can implement.
Comb must be a good protocol citizen: standard NIP-29 first, Buzz
extensions as progressive enhancement. A client that structurally
depends on one vendor's extensions is that vendor's client.

What this means for decisions:

- Every Buzz-specific event kind must have a graceful fallback. The app
  must be usable against a plain NIP-29 relay that has never heard of
  Buzz.
- Interoperability with other Nostr clients is a feature, not a bug.
  Do not build walls.
- Prefer the simplest protocol-level solution. Every feature that
  raises the implementation bar for other clients concentrates the
  ecosystem into fewer applications, which is a centralizing force.
- When a NIP exists for something, use it. When it does not, think
  twice before inventing a proprietary alternative.

### 4. Privacy is structural, not promissory

Privacy in Comb is not a policy you publish and hope people believe. It
is a structural property of the architecture. If there is no server,
there is nothing to send data to. If the key never leaves the Keychain,
it cannot be exfiltrated from a server that does not exist.

What this means for decisions:

- Data that can stay on-device must stay on-device. The block list,
  read state, diagnostic log, sync cursors, and outbox queue are local.
  They are never published as events.
- Media is re-encoded before upload (pixel-level redraw, not a format
  conversion) because a photo from the library carries EXIF that
  routinely includes GPS coordinates.
- Background checks for mentions run on-device and produce local
  notifications. No push notification service is involved.
- HTTP requests go only to the relay the user chose and the community's
  own Blossom media host. A request to an unexpected host is a bug by
  definition.
- User-facing privacy claims are exact or absent. "Comb keeps this log
  on your iPhone and sends it nowhere" is a verifiable statement. "We
  care about your privacy" is not. Write the first kind.

### 5. Honesty over comfort

The app tells people the truth about what it can and cannot do. When a
feature has a limitation, the UI says so. This is not pessimism; it is
respect.

What this means for decisions:

- Blocking is local, and the UI says so: "People you have hidden on
  this iPhone. Blocking is never published, and they are not told."
- Notifications can be late, and the UI says so: "Comb has no
  notification server, so it checks in the background every so often."
- The key is device-only, and the UI says so: "Your account stays on
  this iPhone: it is never copied to iCloud or included in a backup."
- Do not write copy that implies a guarantee the code cannot keep.
  If you cannot promise it, do not suggest it.

### 6. Freedom is structural too

Freedom in Nostr is not a slogan. It is an architectural property.
You are free to exist (generate a key), free to speak (publish to
relays), free to leave (your identity is portable), free to choose
your experience (no algorithmic feed imposed), and free to build (the
protocol is open). Comb must never be the bottleneck in any of these.

What this means for decisions:

- Never impose an algorithmic feed. Content appears in the order it
  was sent. The reader decides what to read.
- Never gate features behind a Comb-specific service. If Comb
  disappeared tomorrow, a user's keys, identity, messages, and
  community membership would still work with any other NIP-29 client.
- Never build lock-in. The user's data is signed events on relays they
  chose. Comb is a window into that data, not a container for it.
- Support the value-for-value model. Zaps (Lightning micropayments
  tied to events) let creators receive support directly, without a
  middleman taking a cut. This is a rejection of the attention
  economy, and Comb should treat it as first-class.

### 7. Simplicity protects decentralization

Every feature added to a protocol raises the bar for implementing a
client. Complexity concentrates the ecosystem into fewer, larger
applications. Simplicity preserves diversity, and diversity is what
makes censorship resistance real rather than theoretical.

What this means for decisions:

- Do not add features that require every other client to implement
  them or display broken content. Features that are "optional" but
  break the experience when absent are not optional.
- Prefer doing less, correctly. A small app that honors the protocol
  is more valuable to the ecosystem than a large app that extends it
  in proprietary ways.
- The append-only event log with rebuildable projections is the
  architecture. Do not introduce server-side state that cannot be
  derived from the signed event stream.

## The tensions, named honestly

Nostr's creator, fiatjaf, is unusually direct about the tensions in
the protocol's values. Comb should be equally direct:

- **Keys are sovereign but meaningless without reach.** Owning a
  keypair means nothing if you cannot distribute your messages to an
  audience. The relay network must actually deliver.
- **The protocol is pro-censorship, not anti-censorship.** Censorship
  is inevitable. The question is whether it is global and hidden
  (centralized platforms) or local and transparent (independent relays
  with stated policies).
- **Technical decentralization does not guarantee practical
  decentralization.** If all users cluster on the same three relays,
  the protocol's decentralization is theoretical. Client behavior and
  relay discovery must actively support distribution.
- **Chaos is a feature, not a bug.** The network is messy, sometimes
  unreliable, and occasionally frustrating. That is the cost of
  genuine openness. Do not paper over it with centralized shortcuts.

## Applying this in practice

When evaluating a feature, a design, or a dependency, ask:

1. Does this keep the user's keys on their device?
2. Does this work without a Comb-operated server?
3. Does this work against any NIP-29 relay, not just Buzz?
4. Does this send data only where the user chose to send it?
5. Does the UI honestly describe what this does and does not do?
6. Could this feature survive Comb disappearing?
7. Does this make the protocol ecosystem more diverse or less?

If the answer to any of these is no, that does not automatically kill
the idea, but it means the idea is in tension with the ethos and needs
to justify itself explicitly.
