#!/usr/bin/env bash
# Open an interactive IRIS terminal in namespace __NS__ (for a person: it is interactive).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && { set -a; . ./.env; set +a; }
exec docker exec -it "${IRIS_CONTAINER:-__NAME__-iris}" iris session IRIS -U "${IRIS_NAMESPACE:-__NS__}"
