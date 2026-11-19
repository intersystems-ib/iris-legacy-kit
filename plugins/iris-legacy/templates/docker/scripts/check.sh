#!/usr/bin/env bash
# Check that the stack answers the way the MCP server and the edit hook need it to: Management
# Portal and Atelier REST through the Web Gateway, and namespace __NS__ present.
#
#   scripts/check.sh          check once
#   scripts/check.sh --wait   retry for up to 2 minutes (the gateway needs a few seconds after IRIS)
set -uo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && { set -a; . ./.env; set +a; }
PORT="${WEBGATEWAY_HTTP_PORT:-__WEB_PORT__}"; NS="${IRIS_NAMESPACE:-__NS__}"
BASE="http://localhost:${PORT}"
# Dev-only credentials, passed on stdin so they stay off the command line.
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 -K - "$@" <<<'user = "_SYSTEM:SYS"'; }

attempts=1; [[ "${1:-}" == "--wait" ]] && attempts=24
for ((i = 1; i <= attempts; i++)); do
  portal=$(code "$BASE/csp/sys/UtilHome.csp")
  atelier=$(code "$BASE/api/atelier/")
  nsdocs=$(code "$BASE/api/atelier/v1/${NS}/docnames/CLS")
  if [[ "$portal" == 200 && "$atelier" == 200 && "$nsdocs" == 200 ]]; then
    echo "check: OK  portal=200 atelier=200 namespace ${NS}=200"
    exit 0
  fi
  ((i < attempts)) && sleep 5
done
echo "check: FAILED  portal=${portal} atelier=${atelier} namespace ${NS}=${nsdocs}" >&2
echo "  000 = gateway not answering; 404 on /api = CSP.ini [APP_PATH_INDEX]; 401 = credentials; 404 on the namespace = ${NS} missing" >&2
exit 1
