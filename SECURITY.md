# Security Policy

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Report it privately through GitHub's
[security advisory form](https://github.com/jedbridges/comb/security/advisories/new).
That creates a private thread visible only to maintainers.

Please include what you found, how to reproduce it, and what an attacker could
do with it. If you have a suggested fix, even better.

You will get an acknowledgement within a few days. Comb is a small project
maintained by one person, so please be patient with the timeline, and do not
disclose publicly until a fix is available.

## What is in scope

Comb holds a private key and talks to relays it does not control. The
interesting attack surface is roughly:

- **Key handling.** Anything that could exfiltrate a key, leak it into a log,
  write it somewhere synced, or sign with the wrong one.
- **Event verification.** Comb recomputes an event id from its contents *and*
  verifies the signature at a single ingest choke point. A way to get an
  unverified or tampered event past that is a serious bug.
- **Read-time authorisation.** Edits and deletions are authorised when read: a
  kind 5 may only erase its own author's events, and a kind 40003 may only
  rewrite its author's own. A way to rewrite or erase somebody else's message is
  a serious bug.
- **Media.** Blossom auth is scoped to the community's own host, and images are
  re-encoded and stripped of metadata before upload. A path that leaks EXIF, or
  that signs an authorization for a third-party host, is in scope.
- **Injection through message content.** Message bodies are written by strangers
  and rendered. Comb deliberately does not interpret arbitrary Markdown. A way
  to get styling, a link, or code to execute from message content is in scope.
- **Anything that sends data somewhere Comb did not promise.** The app has no
  backend; a request to an unexpected host is a bug by definition.

## What is not in scope

- The relay's own behaviour. Comb assumes a relay may be hostile and verifies
  what it says, but the relay software itself belongs to whoever runs it.
- Buzz's hosted services. Report those to
  [block/buzz](https://github.com/block/buzz).
- Crash reports collected by Apple from TestFlight or App Store builds. That is
  a property of Apple's distribution and cannot be disabled by an app. It is
  documented in [PRIVACY.md](PRIVACY.md).
- Physical access to an unlocked device.

## Known limitations, stated plainly

These are design choices, not vulnerabilities, but you should know them:

- **Blocking is local.** It hides someone on your device. Nothing is published,
  and it cannot stop them posting to a community.
- **A key is device-only.** It is stored `ThisDeviceOnly`, so losing the phone
  loses the identity. That is deliberate, and it is the reason to keep a
  recovery code.
- **The community index is unsigned.** See
  [CONTRIBUTING.md](CONTRIBUTING.md#listing-a-community) for why.
