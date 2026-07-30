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
- **Zapping contacts the recipient's wallet provider.** Opening the zap sheet
  asks their provider what amounts it accepts, and choosing one asks it for an
  invoice, so that provider learns your IP address and that somebody is
  interested in paying this person. It happens because you tapped Zap, never
  because you scrolled. The requests carry no cookies and are not cached, so
  the provider cannot link one zap to the next. Comb never sees the money and
  never holds a key to it.
- **A connected wallet is a second relay, and you chose it.** If you connect a
  Lightning wallet, Comb talks to the relay that wallet named, and only that
  one. It opens the connection when you pay and closes it after, so there is no
  standing socket announcing this phone. The requests are encrypted end to end
  with the wallet, so the relay carrying them sees neither the invoice nor the
  amount. The key Comb signs them with is the one your wallet issued, not your
  community identity, so a zap paid this way is not linkable to the account
  posting in a channel. You can revoke it in your wallet at any time, and
  disconnecting deletes it here.
- **Confirming a zap asks the same provider, and nobody else.** Where the
  provider supports it, Comb asks whether the invoice was paid so the zap can be
  counted. It polls only that provider's own host, for under a minute, and only
  after you sent a zap. A confirmation URL pointing anywhere else is ignored.

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
