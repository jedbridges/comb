# Shipping Comb to TestFlight

Everything the code and repo can carry is already in place: bundle id, version,
the privacy manifest, export-compliance flag, icon, and `make archive` /
`make export`. What remains needs your Apple Developer account, and only you can
do it. This is the whole path, in order.

## One time: the account and the app record

1. **Apple Developer Program.** You need a paid membership
   ([developer.apple.com/programs](https://developer.apple.com/programs), $99/yr).
   TestFlight is not available on a free account.
2. **Find your Team ID.** developer.apple.com → Account → Membership. It is a
   ten-character string like `ABCDE12345`. You pass it to `make archive`.
3. **Create the App Store Connect record.**
   [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Apps → **+**
   → New App.
   - Platform: iOS
   - Name: `Comb` (must be unique across the App Store; have a fallback like
     `Comb for Buzz` ready in case it is taken)
   - Primary language: English
   - Bundle ID: `dev.jedbridges.comb` — if it is not in the dropdown, register
     it first at Certificates, Identifiers & Profiles → Identifiers → **+** →
     App IDs → App, description "Comb", bundle id `dev.jedbridges.comb`,
     explicit. No special capabilities need enabling: background modes and
     notifications work without an entitlement toggle here.
   - SKU: anything, e.g. `comb-001`.

## Every build

From the repo root, with your team id:

```bash
make export DEVELOPMENT_TEAM=ABCDE12345
```

That regenerates the project, archives a signed Release build, and writes a
`.ipa` to `build/export/`. The first run will prompt in your login keychain to
create a distribution certificate; allow it.

Then upload one of three ways:

- **Transporter** (simplest): free on the Mac App Store. Open it, drag in the
  `.ipa`, Deliver.
- **Xcode Organizer**: run `make archive DEVELOPMENT_TEAM=…`, then Xcode →
  Window → Organizer → select the archive → Distribute App → App Store Connect.
  This skips the separate export step.
- **Command line**: `xcrun altool --upload-app` or `notarytool`, if you prefer.

Processing on Apple's side takes 5-30 minutes. You will get an email when the
build is ready in App Store Connect under TestFlight.

## Turning on TestFlight

1. App Store Connect → your app → **TestFlight** tab.
2. **Export compliance**: it will ask once. Comb declares
   `ITSAppUsesNonExemptEncryption = NO` in Info.plist (only TLS and the
   secp256k1 signature library, both exempt), so this should auto-clear. If
   asked, the answer is: uses encryption limited to exempt categories.
3. **Internal testing** (you and up to 100 people on your team, no review):
   add testers under Internal Group, they install the TestFlight app and get
   the build immediately.
4. **External testing** (up to 10,000, needs a one-time Beta App Review, usually
   a day): fill in the Test Information — the "what to test" and a contact
   email — then submit. External review is lighter than App Store review but
   real.

## What to put in the tester notes

Be honest about the two things testers will notice first, or you will field the
same questions repeatedly:

> Comb is an unofficial, open-source iOS client for Buzz communities. It is not
> affiliated with Block.
>
> - **Notifications are not instant.** Comb has no push server, so it checks for
>   mentions in the background on iOS's own schedule. A mention can arrive a
>   while after it was sent. Turn it on in Settings.
> - **You need an invite.** Communities are invite-only. Paste an invite a member
>   sent you, or sign in with an existing key from Buzz on desktop.
>
> Found a bug? Settings → Report a problem attaches a local log you can send.

## Before the first external submission

- [ ] Walk the join flow on a clean install with a real, unexpired invite, and
      time it. Under ~45 seconds to first message is the bar.
- [ ] Confirm QR pairing works against Buzz on a desktop you control.
- [ ] Force one background-refresh wake with the Xcode debugger to see a mention
      notification actually fire (Simulator will not do this on its own):
      pause in the debugger and run
      `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"dev.jedbridges.comb.refresh"]`
- [ ] Set a privacy policy URL in App Store Connect (required even for
      TestFlight external). A short page stating Comb collects nothing and keys
      stay on device is enough; the repo README can be that page.
- [ ] Add real, unexpired invite links to `communities/index.json` so Browse
      does not dead-end.
