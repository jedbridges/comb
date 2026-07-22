# Community index

The discovery list shown in Comb's browse screen. Buzz deliberately prevents
community discovery at the protocol level, so this file is the index: plain
JSON, added to by pull request, fetched by the app over TLS.

## Listing a community

Open a pull request adding an entry to `index.json`:

```json
{
  "id": "your-community",
  "name": "Your Community",
  "description": "One sentence, under 100 characters.",
  "relay": "wss://your-community.example.com",
  "tags": ["topic", "another"],
  "join": {
    "kind": "invite_url",
    "url": "https://your-community.example.com/invite/<code>"
  }
}
```

Rules, enforced by the app at load time:

- `relay` must be `wss://` on a public host. Private and local addresses are
  dropped.
- `join.kind` must be honest: `invite_url` (the URL joins directly), `open`
  (a join request works without an invite), or `request_only` (joining needs
  someone inside). The app shows different buttons for each; a wrong kind just
  makes your community look broken.
- Note that Buzz invite links expire (30 days at most). A listed `invite_url`
  needs re-minting before it lapses, or the entry should be `request_only`.

Listing here is voluntary and public. Do not list a community that considers
its existence private: this repository is world-readable and its history is
permanent.

## Trust

This index is not signed. Comb fetches it over TLS from this repository, and
anyone can point their app at a different index URL instead. The security
model is the pull request review plus the public audit trail, stated plainly
rather than implied to be more.
