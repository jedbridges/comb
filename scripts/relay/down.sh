#!/usr/bin/env bash
#
# Stops the contract relay and takes its data with it. The database is on tmpfs
# and there is no volume, so this is already the case; `-v` is here so that
# stays true if someone adds one.
set -euo pipefail

cd "$(dirname "$0")"

# Compose interpolates the file on the way down too. While the key was a `:?`
# guard, tearing the stack down from a shell that no longer had it exported
# failed with "set it, or the suite silently proves nothing" and left the relay
# running, which is an unhelpful thing to be told while trying to stop it.
docker compose -f docker-compose.test.yml down -v
