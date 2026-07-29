#!/usr/bin/env bash
#
# Starts a real Buzz relay for the contract suite, and refuses to hand it over
# until it has proved it can be a subject.
#
# The assertion is the point of this script. Without BUZZ_RELAY_PRIVATE_KEY the
# relay still starts, still accepts events, and still answers queries. What it
# does not do is advertise a `self` pubkey in its NIP-11 document, and the
# client's provenance check on relay-signed group state takes its skipped
# branch when there is nobody to check against. The suite would go green
# against a relay it was not really testing, which is the failure mode this
# whole stage exists to avoid.
#
# So: no key, no run. And no `self`, no run either, because the key being set
# is not the same as the relay having used it.
set -euo pipefail

cd "$(dirname "$0")"
compose="docker-compose.test.yml"
url="http://localhost:3030"

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is not installed. The fake half of the suite still runs:"
    echo "  make test-net"
    exit 1
fi

if [ -z "${BUZZ_RELAY_PRIVATE_KEY:-}" ]; then
    cat <<'MESSAGE'
error: BUZZ_RELAY_PRIVATE_KEY is not set.

A relay without its own key advertises no `self` in NIP-11, and the check that
group state was signed by the relay quietly skips. Every contract case would
pass without testing the thing they exist to test.

Generate one (any 32-byte hex secret) and export it:

    export BUZZ_RELAY_PRIVATE_KEY=$(openssl rand -hex 32)
MESSAGE
    exit 1
fi

docker compose -f "$compose" up -d --wait

# Belt and braces: `--wait` honours the healthcheck, which only proves the
# relay answers. What matters here is *what* it answers.
document=""
for _ in $(seq 1 60); do
    document="$(curl -sf -H 'Accept: application/nostr+json' "$url" || true)"
    [ -n "$document" ] && break
    sleep 1
done

if [ -z "$document" ]; then
    echo "error: the relay never served a NIP-11 document at $url"
    docker compose -f "$compose" logs --tail 40 relay
    exit 1
fi

# Top-level `self`, as in the document a hosted Buzz relay actually serves.
# That shape is not guessed: it is what
# CombNet/Tests/CombNetTests/Fixtures-buzz-relay-nip11.json captured verbatim.
self="$(printf '%s' "$document" | ruby -rjson -e '
document = JSON.parse(STDIN.read) rescue {}
print document.is_a?(Hash) ? document["self"].to_s : ""
')"

if [ -z "$self" ]; then
    echo "error: the relay advertises no \`self\` pubkey."
    echo "       BUZZ_RELAY_PRIVATE_KEY is set here but the relay did not use it,"
    echo "       so the provenance check on 39000/39002 would silently skip and"
    echo "       the contract suite would prove nothing."
    echo
    echo "NIP-11 document as served:"
    printf '%s\n' "$document"
    exit 1
fi

# When the operator knows the public half, hold the relay to it. Deriving it
# from the secret would mean a secp256k1 dependency in a shell script, and the
# check that actually matters is the one above.
if [ -n "${BUZZ_RELAY_PUBLIC_KEY:-}" ] && [ "$self" != "$BUZZ_RELAY_PUBLIC_KEY" ]; then
    echo "error: the relay advertises $self, expected $BUZZ_RELAY_PUBLIC_KEY"
    exit 1
fi

echo "relay is up at $url, signing as $self"
echo
echo "Run the contract suite against it with:"
echo "  COMB_LIVE_RELAY=ws://localhost:3030 make test-net"
echo "Stop it with:"
echo "  scripts/relay/down.sh"
