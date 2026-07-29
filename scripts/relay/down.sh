#!/usr/bin/env bash
#
# Stops the contract relay and takes its data with it. The database is on tmpfs
# and there is no volume, so this is already the case; `-v` is here so that
# stays true if someone adds one.
set -euo pipefail

cd "$(dirname "$0")"
docker compose -f docker-compose.test.yml down -v
