# Privacy Policy

Comb collects no data.

## What Comb stores

- Your account key, in the iOS Keychain on your device. It is never copied to
  iCloud, included in backups, or transmitted anywhere.
- Message history, profiles, and media from communities you join, in a local
  database on your device.
- Preferences (notification settings, recent emoji), on your device.

## What Comb transmits

To the relay of the community you joined, which is operated by that community
and not by Comb:

- Messages, reactions, edits, profile updates, and media you choose to send.
  Photo metadata (location, camera details) is stripped before upload.
- Everything you read. A relay necessarily sees which channels you are in and
  when you are connected.
- Images and files attached to messages, and community avatars, are fetched
  from that same relay, with a request signed by your account key. Comb refuses
  to sign such a request for any other host.

To other places, which is the part worth reading closely:

- **Browsing communities asks GitHub.** The list of communities you can join is
  a file in Comb's public repository, fetched from `raw.githubusercontent.com`
  when you open the Browse screen. GitHub sees your IP address. A copy ships
  inside the app, so this still works offline, and nothing about you is sent
  beyond the request itself. There is no way to publish a list of communities
  without somebody hosting it.
- **Profile pictures and custom emoji can live anywhere.** Whoever set them
  chose the address, and Comb loads them as you scroll. That host sees your IP
  address. Nothing is signed and nothing identifies you beyond the request.
- **Sending a zap contacts the recipient's wallet provider.** Paying a Lightning
  address means asking their provider for an invoice, so that provider learns
  your IP address and that somebody is paying this person. Comb never sees the
  money and never holds a key to it.

## What Comb does not do

- No analytics, telemetry, or crash reporting services.
- No servers operated by Comb. There is nothing to send data to.
- No tracking, no advertising, no third-party SDKs beyond a local database
  library.

## Notifications

Background mention checks run on your device and produce local notifications.
No push service is involved.

## Contact

Open an issue at https://github.com/jedbridges/comb/issues
