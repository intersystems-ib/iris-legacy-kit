#!/usr/bin/env bash
# Stop and remove the development stack. There is no durable %SYS, so this discards everything
# IRIS held; scripts/up.sh rebuilds the code from the repo.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && { set -a; . ./.env; set +a; }
docker compose down --remove-orphans
