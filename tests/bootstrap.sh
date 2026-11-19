#!/usr/bin/env bash
# K3 bootstrap tests: detect, convert, write (both modes), refusals, idempotence and the baseline
# on clean copies of the OMS fixture's src/, in throwaway git repos. `prove` runs against the
# OMS demo's IRIS only when its Atelier REST answers (localhost:46080, namespace OMS); its probe
# routine is deleted again. Prints PASS/FAIL per check.
#
# Needs the tools kept in .test-data (see tests/hooks.sh); never downloads anything.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$KIT/plugins/iris-legacy"
B="$PLUGIN/scripts/bootstrap.sh"
export CLAUDE_PLUGIN_DATA="${IRIS_LEGACY_TEST_DATA:-$KIT/.test-data}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/iris-legacy-bootstrap.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0 skips=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
skip() { echo "SKIP $1"; skips=$((skips + 1)); }

"$PLUGIN/scripts/setup.sh" --check >/dev/null 2>&1 || {
  echo "FAIL tools missing in $CLAUDE_PLUGIN_DATA. Install them once with:"
  echo "  CLAUDE_PLUGIN_DATA=\"$CLAUDE_PLUGIN_DATA\" $PLUGIN/scripts/setup.sh"; exit 1; }

# fresh NAME: a git repo with a clean copy of the fixture's src/, as CLAUDE_PROJECT_DIR
fresh() {
  P="$WORK/$1"; mkdir -p "$P" && cp -R "$KIT/tests/fixtures/oms/src" "$P/" && git -C "$P" init -q
  export CLAUDE_PROJECT_DIR="$P"
}
left_tokens() { grep -rlE '__[A-Z_]+__' "$P" --exclude-dir=.git | xargs grep -lE '__(NAME|NS|WEB_PORT|SS_PORT|IRIS_TAG|HOST|TEST_PACKAGE|ERROR_TRAP|SRC_DIRS|WHERE|U_NOTE)__' 2>/dev/null; }

echo "== detect"
fresh detect
"$B" detect >"$WORK/d.json" 2>"$WORK/d.err"
check "detect prints JSON" 'jq -e . "$WORK/d.json" >/dev/null'
check "source dir: src" '[[ $(jq -c .sourceDirs "$WORK/d.json") == "[\"src\"]" ]]'
check "15 routines, 7 classes" '[[ $(jq -c "[.files.routines, .files.classes]" "$WORK/d.json") == "[15,7]" ]]'
check "test package OM.Test" '[[ $(jq -r .tests.package "$WORK/d.json") == OM.Test ]]'
check "error trap ERR^OMUTL, %ETN log" '[[ $(jq -c "[.errors.trap, .errors.etn]" "$WORK/d.json") == "[\"ERR^OMUTL\",true]" ]]'
check "U=\"^\" convention found" '[[ $(jq -r .uCaret "$WORK/d.json") == true ]]'
check "nothing to convert, nothing existing" '[[ $(jq -c "[.convert[] | length] + [.existing | length]" "$WORK/d.json") == "[0,0,0,0]" ]]'
check "free docker ports proposed" 'jq -e ".dockerPorts.web > 0 and .dockerPorts.superserver > 0" "$WORK/d.json" >/dev/null'
check "detect wrote nothing" '[[ -z "$(git -C "$P" status --porcelain | grep -v "^?? src/")" ]]'

echo "== convert"
fresh convert
mkdir -p "$P/legacy"
printf ' ; old routine, no header\nOLDRTN ;\n s U="^" w $P(^G(1),U,1),!\n q\n' >"$P/legacy/OLDRTN.rtn"
cat >"$P/legacy/export.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Export generator="IRIS" version="26">
<Routine name="XMLRTN" type="MAC" languagemode="0"><![CDATA[
XMLRTN ; from an XML export
 write "hi",!
 quit
]]></Routine>
<Routine name="XMLINC" type="INC"><![CDATA[
#define ONE 1
]]></Routine>
<Class name="Demo.FromXml">
<Super>%RegisteredObject</Super>
</Class>
</Export>
EOF
"$B" convert >"$WORK/c1" 2>&1
check "dry run lists the header and the XML routines" 'grep -q "would add a ROUTINE OLDRTN header" "$WORK/c1" && grep -q "(2 routines)" "$WORK/c1"'
check "dry run changes nothing" '[[ -f "$P/legacy/OLDRTN.rtn" && ! -e "$P/legacy/OLDRTN.mac" && ! -d "$P/legacy/export" ]]'
check "XML classes reported as needing IRIS" 'grep -q "needs IRIS: legacy/export.xml has 1 classes" "$WORK/c1"'
"$B" convert --apply >"$WORK/c2" 2>&1
check "headerless .rtn becomes .mac with a header" '[[ ! -e "$P/legacy/OLDRTN.rtn" && "$(head -1 "$P/legacy/OLDRTN.mac")" == "ROUTINE OLDRTN" ]] && sed -n 2p "$P/legacy/OLDRTN.mac" | grep -q "old routine"'
check "XML routine extracted, header then code" '[[ "$(sed -n "1p;2p" "$P/legacy/export/XMLRTN.mac" | tr "\n" "|")" == "ROUTINE XMLRTN|XMLRTN ; from an XML export|" ]]'
check "XML include extracted with its type" '[[ "$(head -1 "$P/legacy/export/XMLINC.inc")" == "ROUTINE XMLINC [Type=INC]" ]]'
check "detect now finds legacy/ as a source dir" '[[ $("$B" detect | jq -c ".sourceDirs") == "[\"legacy\",\"src\"]" ]]'

echo "== write, docker"
fresh docker
mkdir -p "$P/.claude" && echo '{"model": "keep-me", "permissions": {"allow": ["Bash(make:*)"]}}' >"$P/.claude/settings.json"
"$B" write --mode docker --name kit-test --publish ui=scripts/ui.sh >"$WORK/w1" 2>&1; rc=$?
check "write succeeds" '[[ $rc == 0 ]]'
check "no template token left" '[[ -z "$(left_tokens)" ]]'
check "toml: dev credentials and container" 'grep -q "^password = \"SYS\"" "$P/.iris-agentic-dev.toml" && grep -q "^container = \"kit-test-iris\"" "$P/.iris-agentic-dev.toml"'
check "toml: a free web port" 'grep -qE "^web_port = [0-9]+$" "$P/.iris-agentic-dev.toml"'
check "kit config" '[[ $(jq -c "[.sourceDirs, .environment, .tests.package, .errors.trap, .errors.log, .container]" "$P/.claude/iris-legacy.json") == "[[\"src\"],\"docker\",\"OM.Test\",\"ERR^OMUTL\",\"^ERRORS\",\"kit-test-iris\"]" ]]'
check "kit config: publish entry" '[[ $(jq -c .publish "$P/.claude/iris-legacy.json") == "[{\"dir\":\"ui\",\"command\":\"scripts/ui.sh\"}]" ]]'
check "settings: marketplace and plugin" 'jq -e ".extraKnownMarketplaces[\"iris-legacy-kit\"].source == {source: \"github\", repo: \"intersystems-ib/iris-legacy-kit\"} and .enabledPlugins[\"iris-legacy@iris-legacy-kit\"] == true" "$P/.claude/settings.json" >/dev/null'
check "settings: existing keys and rules kept" 'jq -e ".model == \"keep-me\" and (.permissions.allow | index(\"Bash(make:*)\"))" "$P/.claude/settings.json" >/dev/null'
check "settings: read-only MCP tools allowed, iris_execute not" 'jq -e "(.permissions.allow | index(\"mcp__plugin_iris-legacy_iris__iris_search\")) and ((.permissions.allow | index(\"mcp__plugin_iris-legacy_iris__iris_execute\")) | not)" "$P/.claude/settings.json" >/dev/null'
check "settings: credentials file unreadable" 'jq -e ".permissions.deny | index(\"Read(./.claude/settings.local.json)\")" "$P/.claude/settings.json" >/dev/null'
check "gitignore: local settings, findings, .env, key" 'for l in .claude/settings.local.json .claude/kit-findings.jsonl .claude/kit-findings/ .env iris.key; do grep -qxF "$l" "$P/.gitignore" || exit 1; done'
check "stack files written" 'for f in docker-compose.yml docker-compose.licensed.yml .env.example docker/iris/Dockerfile docker/iris/iris.script docker/webgateway/CSP.ini scripts/up.sh scripts/load.sh scripts/test.sh; do [[ -f "$P/$f" ]] || exit 1; done'
check "scripts executable and parse" 'for f in "$P"/scripts/*.sh; do [[ -x "$f" ]] && bash -n "$f" || exit 1; done'
check "CLAUDE.md: docker sections only" 'grep -q "scripts/test.sh \[class or package\]" "$P/CLAUDE.md" && ! grep -q "shared development instance" "$P/CLAUDE.md" && ! grep -q "<!--docker-->" "$P/CLAUDE.md"'
check "CLAUDE.md: error log section (ETN found)" 'grep -q "Code that traps errors with \`ERR^OMUTL\`" "$P/CLAUDE.md"'
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  check "compose file validates" '(cd "$P" && cp .env.example .env && docker compose config -q)'
else
  skip "compose file validates (no docker compose)"
fi

echo "== write again: nothing changes"
for f in CLAUDE.md .claude/settings.json .gitignore .iris-agentic-dev.toml .claude/iris-legacy.json; do cp "$P/$f" "$WORK/before.$(basename "$f")"; done
"$B" write --mode docker --name kit-test --publish ui=scripts/ui.sh >"$WORK/w2" 2>&1
check "second write identical" 'for f in CLAUDE.md .claude/settings.json .gitignore .iris-agentic-dev.toml .claude/iris-legacy.json; do cmp -s "$P/$f" "$WORK/before.$(basename "$f")" || exit 1; done'
check "second write keeps the stack files" 'grep -q "Kept" "$WORK/w2" && grep -q "scripts/up.sh" "$WORK/w2"'
sed -i.bak 's/^The ObjectScript in/EDITED The ObjectScript in/' "$P/CLAUDE.md" && rm -f "$P/CLAUDE.md.bak" && echo "project note" >>"$P/CLAUDE.md"
"$B" write --mode docker --name kit-test --publish ui=scripts/ui.sh >/dev/null 2>&1
sed -i.bak '/^\.claude\/kit-findings\/$/d' "$P/.gitignore" && rm -f "$P/.gitignore.bak"
"$B" write --mode docker --name kit-test --publish ui=scripts/ui.sh >/dev/null 2>&1
check "a missing kit line comes back under the one kit heading" '[[ $(grep -cxF "# iris-legacy kit" "$P/.gitignore") == 1 ]] && grep -qxF ".claude/kit-findings/" "$P/.gitignore"'
check "the kit block is regenerated, notes outside it kept" '! grep -q "^EDITED" "$P/CLAUDE.md" && grep -q "^project note$" "$P/CLAUDE.md" && [[ $(grep -c "iris-legacy:begin" "$P/CLAUDE.md") == 1 ]]'

echo "== write, existing instance"
fresh existing
printf '# Our app\n\nKeep me.\n' >"$P/CLAUDE.md"
"$B" write --mode existing --host iris-dev.example --web-port 443 --scheme https --web-prefix iris --namespace APPDEV >"$WORK/w3" 2>&1; rc=$?
check "write succeeds" '[[ $rc == 0 ]]'
check "toml: no credentials" '! grep -qE "^(username|password)" "$P/.iris-agentic-dev.toml"'
check "toml: host, https, prefix, namespace" 'grep -q "^host = \"iris-dev.example\"" "$P/.iris-agentic-dev.toml" && grep -q "^scheme = \"https\"" "$P/.iris-agentic-dev.toml" && grep -q "^web_prefix = \"iris\"" "$P/.iris-agentic-dev.toml" && grep -q "^namespace = \"APPDEV\"" "$P/.iris-agentic-dev.toml"'
check "no stack files" '[[ ! -e "$P/docker-compose.yml" && ! -e "$P/scripts" ]]'
check "CLAUDE.md: block appended, own text kept" '[[ "$(head -3 "$P/CLAUDE.md" | tr "\n" "|")" == "# Our app||Keep me.|" ]] && grep -q "iris-legacy:begin" "$P/CLAUDE.md"'
check "CLAUDE.md: existing-instance sections only" 'grep -q "shared development instance at \`iris-dev.example\`" "$P/CLAUDE.md" && grep -q "iris_test" "$P/CLAUDE.md" && ! grep -q "scripts/up.sh" "$P/CLAUDE.md"'
check "says how to set the credentials" 'grep -q "IRIS_PASSWORD" "$WORK/w3"'
env -u IRIS_USERNAME -u IRIS_PASSWORD "$B" prove >"$WORK/p0" 2>&1; rc=$?
check "prove refuses without credentials" '[[ $rc != 0 ]] && grep -q "FAIL credentials" "$WORK/p0"'

echo "== refusals"
mkdir -p "$WORK/nogit/src" && cp "$KIT/tests/fixtures/oms/src/rtn/OMUTL.mac" "$WORK/nogit/src/"
CLAUDE_PROJECT_DIR="$WORK/nogit" "$B" write --mode docker >"$WORK/r1" 2>&1; rc=$?
check "not a git repo: refused" '[[ $rc != 0 ]] && grep -q "not a git repository" "$WORK/r1" && [[ ! -e "$WORK/nogit/.iris-agentic-dev.toml" ]]'
fresh prod
for args in "--namespace OMSPROD --host localhost" "--namespace %SYS --host localhost" "--namespace APP --host prd-iris.example" "--namespace LIVE --host localhost"; do
  # shellcheck disable=SC2086
  "$B" write --mode existing --web-port 80 $args >"$WORK/r2" 2>&1; rc=$?
  check "refused: $args" '[[ $rc != 0 ]] && grep -q "looks like production" "$WORK/r2" && [[ ! -e "$P/.iris-agentic-dev.toml" && ! -e "$P/CLAUDE.md" ]]'
done
"$B" write --mode existing --web-port 80 --namespace PRODUCTS --host localhost --not-production >"$WORK/r3" 2>&1; rc=$?
check "--not-production lets PRODUCTS through" '[[ $rc == 0 ]] && grep -q "^namespace = \"PRODUCTS\"" "$P/.iris-agentic-dev.toml"'
fresh badsrc
"$B" write --mode docker --source-dir ../elsewhere >"$WORK/r4" 2>&1; rc=$?
check "source dir outside the project: refused" '[[ $rc != 0 ]] && grep -q "not a folder inside the project" "$WORK/r4"'

echo "== baseline"
fresh base
"$B" write --mode docker --name kit-base >/dev/null 2>&1
if command -v uv >/dev/null; then
  "$B" baseline >"$WORK/b1" 2>&1; rc=$?
  check "baseline written" '[[ $rc == 0 ]] && jq -e . "$P/.claude/iris-legacy-baseline.json" >/dev/null'
  check "no ascot finding on the unchanged code" '[[ $(jq -c .ascot "$P/.claude/iris-legacy-baseline.json") == "{}" ]]'
  check "smells counted by rule (11)" '[[ $(jq "[.smells[]] | add" "$P/.claude/iris-legacy-baseline.json") == 11 ]]'
  check "global references counted (212 in 22 files)" '[[ $(jq -c "[.globalMap.files, .globalMap.references]" "$P/.claude/iris-legacy-baseline.json") == "[22,212]" ]]'
else
  skip "baseline (no uv)"
fi

echo "== prove (live IRIS)"
if [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -K - http://localhost:46080/api/atelier/ <<<'user = "_SYSTEM:SYS"') == 200 ]]; then
  fresh live
  "$B" write --mode existing --host localhost --web-port 46080 --namespace OMS >/dev/null 2>&1
  IRIS_USERNAME=_SYSTEM IRIS_PASSWORD=SYS "$B" prove >"$WORK/p1" 2>&1; rc=$?
  sed 's/^/    prove: /' "$WORK/p1"
  check "prove passes" '[[ $rc == 0 ]] && grep -q "TESTS: 0 failed" "$WORK/p1"'
  check "no probe file left" '[[ -z "$(ls "$P/src/rtn" | grep ZZKIT)" ]]'
  left=$(curl -s --max-time 10 -K - "http://localhost:46080/api/atelier/v1/OMS/docnames/*" <<<'user = "_SYSTEM:SYS"' | jq '[.result.content[].name | select(startswith("ZZKITPROBE"))] | length')
  check "no probe left in IRIS" '[[ "$left" == 0 ]]'
  IRIS_USERNAME=_SYSTEM IRIS_PASSWORD=wrong-password "$B" prove >"$WORK/p2" 2>&1; rc=$?
  check "a wrong password is reported, not hidden" '[[ $rc != 0 ]] && grep -q "401" "$WORK/p2"'
else
  skip "prove (the OMS demo's Atelier REST does not answer on localhost:46080)"
fi

echo "TESTS: $fails failed, $skips skipped"
exit $((fails > 0))
