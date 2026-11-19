#!/usr/bin/env bash
# Start the development stack (IRIS + Web Gateway), load the source directories into namespace
# __NS__, and check that everything answers. Written by /iris-legacy:bootstrap.
#
#   scripts/up.sh             edition from .env (Community by default)
#   scripts/up.sh community   IRIS Community for this start, no license key needed
#   scripts/up.sh licensed    licensed IRIS for this start (needs ./iris.key)
#
# Switching edition recreates the IRIS container, which discards what only IRIS held.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then cp .env.example .env; echo "Created .env from .env.example"; fi
set -a; . ./.env; set +a

case "${1:-}" in
  community)
    export COMPOSE_FILE=docker-compose.yml
    export IRIS_IMAGE=containers.intersystems.com/intersystems/iris-community:__IRIS_TAG__ ;;
  licensed)
    export COMPOSE_FILE=docker-compose.yml:docker-compose.licensed.yml
    export IRIS_IMAGE=containers.intersystems.com/intersystems/iris:__IRIS_TAG__ ;;
  "") ;;
  *) echo "usage: $0 [licensed|community]" >&2; exit 2 ;;
esac

if [[ "$COMPOSE_FILE" == *licensed* ]]; then
  key="${IRIS_KEY_PATH:-./iris.key}"
  [[ -f "$key" ]] || { echo "The licensed edition needs a license key at $key (gitignored), or run: $0 community" >&2; exit 1; }
fi

echo "Edition image: $IRIS_IMAGE"
# The gateway writes its runtime state under docker/webgateway/durable; the container user must be able to.
mkdir -p docker/webgateway/durable && chmod -R a+rwX docker/webgateway 2>/dev/null || true

docker compose up -d --build --wait --wait-timeout 300
scripts/check.sh --wait
scripts/load.sh
# Seed data, if the project has a seed script: a new container has none.
[[ -x scripts/seed.sh ]] && scripts/seed.sh
scripts/check.sh

cat <<EOS

__NAME__ is up.
  Management Portal: http://localhost:${WEBGATEWAY_HTTP_PORT}/csp/sys/UtilHome.csp
  Atelier REST:      http://localhost:${WEBGATEWAY_HTTP_PORT}/api/atelier/
  Namespace:         ${IRIS_NAMESPACE}
  Credentials:       _SYSTEM / SYS (dev only)
  Terminal:          scripts/iris.sh
EOS
