#!/usr/bin/env python3
"""Turn a "List your community" issue into an entry in communities/index.json.

The listing index is the app's only discovery surface, and the app fetches it
straight from `main`, so anything merged here is live on every installed phone
within minutes. That is the reason for the checks below: a bad entry is not a
bad row in a file, it is a broken row on somebody's first screen.

The validation deliberately mirrors `CommunityIndex.Entry.isValid` in CombNet.
An entry the app would refuse to render is worse than no entry at all, because
it looks like the app is broken rather than the listing.

Reads the issue body, writes the updated index, and prints a human explanation
when it refuses. Exit 0 means the entry is ready; exit 1 means it is not, and
whatever was printed is fit to post back to the person who submitted it.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import date, timezone, datetime
from pathlib import Path
from urllib.parse import urlparse

# Matches GitHub's rendering of an issue form: a `### Label` line, then the
# value until the next heading. `_No response_` is what GitHub writes for an
# empty optional field.
SECTION = re.compile(r"^###\s+(?P<label>.+?)\s*$", re.MULTILINE)
NO_RESPONSE = "_no response_"

USER_AGENT = "Comb-listing-check/1.0 (+https://github.com/jedbridges/comb)"


def parse_form(body: str) -> dict[str, str]:
    """Field label to value, as GitHub renders an issue form into markdown."""
    fields: dict[str, str] = {}
    matches = list(SECTION.finditer(body))
    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        value = body[start:end].strip()
        if value.lower() == NO_RESPONSE:
            value = ""
        fields[match.group("label").strip().lower()] = value
    return fields


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return slug or "community"


def is_private_host(host: str) -> bool:
    """The same SSRF guard the app applies before it will use a relay.

    Kept in step with `CommunityIndex.Entry.isPrivateHost`. A listing pointing
    at a private address is either a mistake or an attempt to make other
    people's phones talk to something on their own network.
    """
    host = host.lower()
    if host in {"localhost", "0.0.0.0"} or host.endswith(".local"):
        return True
    parts = host.split(".")
    if len(parts) == 4 and all(part.isdigit() for part in parts):
        octets = [int(part) for part in parts]
        if octets[0] in (10, 127):
            return True
        if octets[0] == 192 and octets[1] == 168:
            return True
        if octets[0] == 172 and 16 <= octets[1] <= 31:
            return True
    return False


def check_relay_answers(host: str, timeout: float) -> str | None:
    """Fetch the relay's NIP-11 document. Returns a reason on failure.

    This is the check a human would otherwise do by opening the address and
    squinting, which is exactly the check a human skips. It only asserts that
    something Nostr-shaped is answering: asserting it is specifically Buzz
    would reject legitimate self-hosted setups for no benefit.
    """
    request = urllib.request.Request(
        f"https://{host}",
        headers={
            "Accept": "application/nostr+json",
            # Identifying the checker is both manners and necessity. Python's
            # default `Python-urllib/3.x` is blocked outright by the CDNs in
            # front of several well-known relays, which read as "this relay is
            # unreachable" and would have rejected working submissions.
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read(64 * 1024)
    except urllib.error.HTTPError as error:
        return f"the relay answered HTTP {error.code} instead of a relay description"
    except urllib.error.URLError as error:
        return f"nothing answered at that address ({error.reason})"
    except OSError as error:
        return f"nothing answered at that address ({error})"

    try:
        document = json.loads(payload)
    except json.JSONDecodeError:
        return "the address answered, but not with a relay description document"
    if not isinstance(document, dict):
        return "the address answered, but not with a relay description document"
    return None


def build_entry(fields: dict[str, str], today: str) -> tuple[dict, list[str]]:
    """The index entry, plus any reasons it cannot be built."""
    problems: list[str] = []

    name = fields.get("community name", "").strip()
    if not name:
        problems.append("The community name is missing.")

    raw_relay = fields.get("relay address", "").strip()
    host = ""
    if not raw_relay:
        problems.append("The relay address is missing.")
    else:
        parsed = urlparse(raw_relay)
        if parsed.scheme.lower() != "wss":
            problems.append(
                f"The relay address must start with `wss://`, but this one is "
                f"`{parsed.scheme or raw_relay}`. Comb refuses anything else, "
                "because an unencrypted relay would expose every message."
            )
        elif not parsed.hostname:
            problems.append(f"`{raw_relay}` does not contain a host name.")
        elif is_private_host(parsed.hostname):
            problems.append(
                f"`{parsed.hostname}` is a private or local address, so nobody "
                "else could reach it."
            )
        else:
            host = parsed.hostname

    description = fields.get("description", "").strip()
    if not description:
        problems.append("The description is missing.")

    tags = [
        tag.strip().lower()
        for tag in fields.get("tags", "").replace("\n", ",").split(",")
        if tag.strip()
    ]

    invite = fields.get("invite link (optional)", "").strip()
    if invite and not invite.lower().startswith("https://"):
        problems.append("The invite link must be an `https://` URL.")
        invite = ""

    entry = {
        "id": slugify(name),
        "name": name,
        "description": description,
        "relay": raw_relay,
        "tags": tags,
        "listed_at": today,
        "join": (
            {"kind": "invite_url", "url": invite}
            if invite
            else {"kind": "request_only", "url": None}
        ),
    }
    return entry, problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--body", required=True, help="file holding the issue body")
    parser.add_argument("--index", default="communities/index.json")
    parser.add_argument("--out", help="where to write the updated index")
    parser.add_argument(
        "--skip-network",
        action="store_true",
        help="skip the NIP-11 reachability check, for tests",
    )
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument(
        "--today",
        default=datetime.now(timezone.utc).date().isoformat(),
        help="the listed_at date, overridable so tests are deterministic",
    )
    args = parser.parse_args()

    body = Path(args.body).read_text(encoding="utf-8")
    fields = parse_form(body)
    if not fields:
        print(
            "This issue does not look like it came from the listing form. "
            "Please open a new one using **List your community** so every "
            "field is present."
        )
        return 1

    entry, problems = build_entry(fields, args.today)

    index = json.loads(Path(args.index).read_text(encoding="utf-8"))
    communities = index.get("communities", [])

    # Duplicates are checked against the relay rather than the name: two
    # communities may reasonably share a name, but one relay is one community.
    existing_relays = {
        (community.get("relay") or "").rstrip("/").lower() for community in communities
    }
    if entry["relay"].rstrip("/").lower() in existing_relays:
        problems.append(
            f"`{entry['relay']}` is already listed, so there is nothing to add."
        )

    if entry["id"] in {community.get("id") for community in communities}:
        # A collision on the derived id only, not the relay: keep both, and
        # make the second one distinguishable rather than rejecting it.
        entry["id"] = f"{entry['id']}-{urlparse(entry['relay']).hostname.split('.')[0]}"

    if not problems and not args.skip_network:
        host = urlparse(entry["relay"]).hostname
        failure = check_relay_answers(host, args.timeout)
        if failure:
            problems.append(
                f"Comb could not confirm the relay is reachable: {failure}. "
                "If it is behind a firewall or not running yet, start it and "
                "edit this issue to try again."
            )

    if problems:
        print("This listing could not be added yet:\n")
        for problem in problems:
            print(f"- {problem}")
        print(
            "\nEdit the issue and the check will run again. Nothing is lost."
        )
        return 1

    communities.append(entry)
    communities.sort(key=lambda community: community.get("id", ""))
    index["communities"] = communities

    rendered = json.dumps(index, indent=2, ensure_ascii=False) + "\n"
    if args.out:
        Path(args.out).write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)

    print(entry["id"], file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
