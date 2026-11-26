#!/usr/bin/env bash
# K2 tests: the plugin's compile and lint hooks and its MCP server entry point, on a copy of the
# OMS demo code (tests/fixtures/oms). The lint cases are the scripted agent mistakes from the
# OMS evaluation: each one must be reported, and the unmodified code must stay silent.
#
#   tests/hooks.sh
#
# The tools are downloaded once into .test-data/ (gitignored) and kept; this test only checks
# that they are there and never downloads or installs anything:
#   CLAUDE_PLUGIN_DATA="$PWD/.test-data" plugins/iris-legacy/scripts/setup.sh     # once
# The live compile case runs only when the OMS demo stack answers on localhost:46080; it uploads
# a scratch routine and deletes it.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
P="$KIT/plugins/iris-legacy"
export CLAUDE_PLUGIN_DATA="${IRIS_LEGACY_TEST_DATA:-$KIT/.test-data}"
if ! "$P/scripts/setup.sh" --check >/dev/null 2>&1; then
  echo "FAIL tools missing in $CLAUDE_PLUGIN_DATA. Install them once with:"
  echo "  CLAUDE_PLUGIN_DATA=\"$CLAUDE_PLUGIN_DATA\" $P/scripts/setup.sh"
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/iris-legacy-hooks.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
PROJ="$WORK/proj"
cp -R "$KIT/tests/fixtures/oms" "$PROJ"
(cd "$PROJ" && git init -q && git add -A && git -c user.name=test -c user.email=test@example.com commit -qm fixture)
PROJ="$(cd "$PROJ" && pwd -P)"
export CLAUDE_PROJECT_DIR="$PROJ"

fails=0
payload() { jq -nc --arg f "$1" '{tool_name: "Edit", tool_input: {file_path: $f}}'; }
# HOME is a scratch directory: ascot keeps what it downloads in ~/.ascot, so an empty one at the
# end shows that it read the pinned declarations and fetched nothing.
mkdir -p "$WORK/home"
run() {  # run SCRIPT FILE [ARG]: sets RC, OUT, ERR
  payload "$1" >/dev/null
  payload "$2" | HOME="$WORK/home" "$P/scripts/$1" ${3:+"$3"} >"$WORK/out" 2>"$WORK/err"
  RC=$?; OUT=$(cat "$WORK/out"); ERR=$(cat "$WORK/err")
}
lint() { run lint.sh "$PROJ/$1" --hook; }
post() { run post-edit.sh "$PROJ/$1"; }
reset() { (cd "$PROJ" && git checkout -q -- . && git clean -qfd); }
expect() {  # expect NAME RC [REGEX...]: every REGEX must match stdout+stderr
  local name=$1 want=$2 ok=1; shift 2
  [[ "$RC" == "$want" ]] || ok=0
  for re in "$@"; do grep -qE -- "$re" <<<"$OUT"$'\n'"$ERR" || ok=0; done
  if ((ok)); then echo "PASS $name"; else
    echo "FAIL $name (exit $RC, wanted $want)"; printf '%s\n%s\n' "$OUT" "$ERR" | sed 's/^/    /' | head -15
    fails=$((fails + 1))
  fi
}
edit() { (cd "$PROJ" && perl -pi -e "$2" "$1"); }

echo "== lint hook"
lint src/rtn/OMORDL.mac;                 expect "unmodified code is silent" 0
edit src/rtn/OMORDL.mac 's/^PRT ;/PRTHDR ;/'
lint src/rtn/OMORDL.mac;                 expect "renamed label: caller in the same routine" 2 'OMORDL\.mac:16:.*A6851'; reset
edit src/rtn/OMORDL.mac 's/^BYDATE ;/BYDAY ;/'
lint src/rtn/OMORDL.mac;                 expect "renamed label: callers in other files" 2 'OMORDL\.mac:16:.*A6851' 'OMRPT\.mac:21:.*A6851' 'Order\.cls:34:.*A6851'; reset
edit src/rtn/OMCUST.mac 's/^ D AUD\^OMUTL\("CUST-DEL",CID\)/ D AUDD^OMUTL("CUST-DEL",CID)/'
lint src/rtn/OMCUST.mac;                 expect "misspelt label in another routine" 2 'OMCUST\.mac:.*A6851'; reset
# Unreported until ascot 0.5.0 fixed intersystems-community/ascot#136 (nothing after a stand-alone
# ELSE was checked).
edit src/rtn/OMCUST.mac 's/^ D UNIDX\(CID\)/ D UNIDXX(CID)/'
lint src/rtn/OMCUST.mac;                 expect "misspelt label after a stand-alone ELSE (ascot#136)" 2 'OMCUST\.mac:62:.*A6851'; reset
edit src/rtn/OMCUST.mac 's/^ D AUD\^OMUTL\("CUST-DEL",CID\)/ D AUD^OMUTLX("CUST-DEL",CID)/'
lint src/rtn/OMCUST.mac;                 expect "call to a missing routine" 2 "OMCUST\\.mac:.*routine 'OMUTLX'.*A4439"; reset
edit src/rtn/OMCUST.mac 's/^ D AUD\^OMUTL\("CUST-DEL",CID\)/ D AUD^%ZSITE("CUST-DEL",CID)/'
lint src/rtn/OMCUST.mac;                 expect "a % routine (site code in %SYS) is not reported" 0; reset
edit src/rtn/OMCUST.mac 's/^ K \^CUST\(CID\)$/ K ^CUST(CID/'
lint src/rtn/OMCUST.mac;                 expect "unbalanced parenthesis" 2 'A1727'; reset
edit src/rtn/OMCUST.mac 's/^ K \^CUST\(CID\)$/ K ^CUST(\$TRX(CID))/'
lint src/rtn/OMCUST.mac;                 expect "unknown function" 2 'A3850'; reset
edit src/rtn/OMPRICE.mac 's/\$\$DISC\(qty\)/\$\$DISC(qty, cid)/'
lint src/rtn/OMPRICE.mac;                expect "too many arguments" 2 'A5523'; reset
edit src/cls/OM/API/Order.cls 's/do SHIP\^OMORD/do SHIPP^OMORD/'
lint src/cls/OM/API/Order.cls;           expect "missing label called from a class" 2 'Order\.cls:.*A6851'; reset
edit src/cls/OM/API/Order.cls 's/quit \.\.Collect\(\)/quit ..Colect()/ if $. == 35'
lint src/cls/OM/API/Order.cls;           expect "misspelt class method" 2 'A3139'; reset
edit src/rtn/OMSTOCK.mac "s/^    else  quit 0\$/    if '\\\$test { trollback 1  quit 0 }/; s/qoh - qty/qoh - qtty/"
lint src/rtn/OMSTOCK.mac;                expect "undefined variable after the ELSE rewrite" 2 'qtty.*A7095'; reset
edit src/rtn/OMSTOCK.mac "s/^    else  quit 0\$/    if '\\\$test { trollback 1  quit 0 }/"
lint src/rtn/OMSTOCK.mac;                expect "removing a smell is silent" 0; reset
edit src/rtn/OMORD.mac 'print " S \$P(^(ORD),U,5)=\"\"\n L +^SORD(ORD)\n" if $. == 13'
lint src/rtn/OMORD.mac;                  expect "added smells are reported" 2 'Legacy smells added to src/rtn/OMORD\.mac' 'line 13: naked-global-reference' 'line 14: lock-without-timeout'
[[ $(grep -c '^line ' <<<"$ERR") -eq 2 ]] && echo "PASS only the two added smells" || { echo "FAIL only the two added smells"; fails=$((fails + 1)); }
reset
edit src/rtn/OMORDL.mac 's/^PRT ;/PRTHDR ;/'
run lint.sh "$PROJ/README.md" --hook;    expect "non-ObjectScript file is ignored" 0
mkdir -p "$PROJ/tools"; printf 'ROUTINE ZZOUT\nZZOUT Q\n' >"$PROJ/tools/ZZOUT.mac"
run lint.sh "$PROJ/tools/ZZOUT.mac" --hook; expect "file outside the source dirs is ignored" 0
mv "$PROJ/.claude/iris-legacy.json" "$WORK/conf.json"
lint src/rtn/OMORDL.mac;                 expect "no kit config: hooks stay out of the way" 0
mv "$WORK/conf.json" "$PROJ/.claude/iris-legacy.json"
CLAUDE_PLUGIN_DATA="$WORK/empty" lint src/rtn/OMORDL.mac; expect "tools missing: lint stays silent" 0
jq '.lint = {"ascot": false}' "$PROJ/.claude/iris-legacy.json" >"$WORK/c" && cp "$WORK/c" "$PROJ/.claude/iris-legacy.json"
lint src/rtn/OMORDL.mac;                 expect "lint.ascot false switches ascot off" 0
reset
jq '.lint.ascotIris = ["missing.d.json"]' "$PROJ/.claude/iris-legacy.json" >"$WORK/c" && cp "$WORK/c" "$PROJ/.claude/iris-legacy.json"
lint src/rtn/OMORDL.mac;                 expect "ascot failing is a note, not a block" 0 'Static check incomplete: ascot did not run: .*missing\.d\.json'
RC=0; (cd "$PROJ" && HOME="$WORK/home" "$P/scripts/lint.sh" >"$WORK/out" 2>"$WORK/err") || RC=$?; OUT=$(cat "$WORK/out"); ERR=$(cat "$WORK/err")
expect "lint.sh exits 2 when ascot did not run" 2 'ascot did not run'
reset

echo "== SARIF"
sarif() { RC=0; (cd "$PROJ" && HOME="$WORK/home" "$P/scripts/lint.sh" --sarif >"$WORK/out" 2>"$WORK/err") || RC=$?; OUT=$(cat "$WORK/out"); ERR=$(cat "$WORK/err"); }
sarif;                                   expect "unmodified code: SARIF with no results" 0
jq -e '.version == "2.1.0" and ([.runs[].results[]] | length) == 0' "$WORK/out" >/dev/null && echo "PASS SARIF 2.1.0, empty" || { echo "FAIL SARIF 2.1.0, empty"; fails=$((fails + 1)); }
edit src/rtn/OMORDL.mac 's/^BYDATE ;/BYDAY ;/'
sarif;                                   expect "renamed label: SARIF exits 1" 1
jq -e '[.runs[].results[] | select(.ruleId == "A6851")] | length == 3' "$WORK/out" >/dev/null && echo "PASS SARIF holds the three broken callers" || { echo "FAIL SARIF holds the three broken callers"; fails=$((fails + 1)); }
reset
[[ ! -e "$WORK/home/.ascot" ]] && echo "PASS ascot downloaded nothing (no ~/.ascot)" || { echo "FAIL ascot downloaded into ~/.ascot"; fails=$((fails + 1)); }

echo "== compile hook (routing)"
post README.md;                          expect "non-ObjectScript file is ignored" 0
post ui/index.html;                      expect "publish dir runs its command" 0 'ui published'
touch "$PROJ/ui/FAIL"
post ui/index.html;                      expect "failed publish is reported" 2 'NOT published'
reset
mkdir -p "$PROJ/tools"; printf 'ROUTINE ZZOUT\nZZOUT Q\n' >"$PROJ/tools/ZZOUT.mac"
post tools/ZZOUT.mac;                    expect "outside the source dirs: not uploaded" 0 'NOT uploaded'
reset
CLAUDE_PLUGIN_DATA="$WORK/empty" post src/rtn/OMORDL.mac; expect "tools missing: says not compile-checked" 2 'NOT compile-checked.*setup'
mv "$PROJ/.iris-agentic-dev.toml" "$WORK/toml"
post src/rtn/OMORDL.mac;                 expect "no connection file: says not compile-checked" 2 'NOT compile-checked.*iris-agentic-dev\.toml'
mv "$WORK/toml" "$PROJ/.iris-agentic-dev.toml"
post src/rtn/OMORDL.mac;                 expect "IRIS unreachable: reported to the agent" 2
mv "$PROJ/.claude/iris-legacy.json" "$WORK/conf.json"
post src/rtn/OMORDL.mac;                 expect "no kit config: hooks stay out of the way" 0
mv "$WORK/conf.json" "$PROJ/.claude/iris-legacy.json"

echo "== compile hook (live IRIS)"
# Atelier REST with the demo's dev credentials, read by curl from stdin (-K -) so that no
# password appears on a command line, where endpoint protection and `ps` can see it.
atelier() { curl -s -o /dev/null -w '%{http_code}' -K - "$@" <<<'user = "_SYSTEM:SYS"'; }
if [[ "$(atelier http://localhost:46080/api/atelier/)" == 200 ]]; then
  sed -i '' 's/^web_port = 1$/web_port = 46080/' "$PROJ/.iris-agentic-dev.toml"
  printf 'ROUTINE ZZKITPROBE\nZZKITPROBE ; kit hook test, deleted by the test\n Q 1\n' >"$PROJ/src/rtn/ZZKITPROBE.mac"
  post src/rtn/ZZKITPROBE.mac;           expect "clean compile" 0
  printf 'ROUTINE ZZKITPROBE\nZZKITPROBE ; kit hook test, deleted by the test\n Q 1+\n' >"$PROJ/src/rtn/ZZKITPROBE.mac"
  post src/rtn/ZZKITPROBE.mac;           expect "compile error reaches the agent" 2 'ZZKITPROBE'
  atelier -X DELETE http://localhost:46080/api/atelier/v1/OMS/doc/ZZKITPROBE.mac >/dev/null
  reset
else
  echo "SKIP live compile: nothing answers on localhost:46080 (start the OMS demo stack to run it)"
fi

echo "== MCP server entry point"
mcp_tools() {  # the tool names the server lists for the fixture project
  (printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"kit-test","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; sleep 3) \
    | "$P/scripts/mcp.sh" "$PROJ" 2>"$WORK/mcp.err" | jq -r 'select(.id == 2) | .result.tools[].name' 2>/dev/null
}
lacks() {  # lacks NAME REGEX: no line of OUT matches REGEX
  if grep -qE -- "$2" <<<"$OUT"; then echo "FAIL $1"; fails=$((fails + 1)); else echo "PASS $1"; fi
}
toolset() { jq --arg t "$1" '.toolset = $t' "$PROJ/.claude/iris-legacy.json" >"$WORK/conf" && cp "$WORK/conf" "$PROJ/.claude/iris-legacy.json"; }
# IRIS_TOOLSET as a user-scope server would have it: the kit's server must not take it.
RC=0; OUT=$(IRIS_TOOLSET=interop mcp_tools); ERR=""
expect "routines profile by default: language and global tools" 0 '^iris_execute$' '^iris_doc$' '^iris_test$' '^iris_global$'
lacks "no interoperability tools, though IRIS_TOOLSET=interop is inherited" '^iris_production'
toolset interop
RC=0; OUT=$(mcp_tools); ERR=""
expect "toolset from the kit config: interop serves the production tools" 0 '^iris_production$' '^iris_doc$'
lacks "toolset from the kit config: interop has no global tools" '^iris_global$'
toolset routnes
RC=0; OUT=$("$P/scripts/mcp.sh" "$PROJ" </dev/null 2>&1); RC=$?
expect "a toolset the binary lacks: refuses to start, naming the profiles" 1 'routnes' 'Valid profiles: .*routines'
reset
RC=0; OUT=$("$P/scripts/mcp.sh" "$WORK/nowhere" </dev/null 2>&1); RC=$?
expect "no connection file: refuses to start" 1 'no \.iris-agentic-dev\.toml'

echo "== smell rules"
cfg=$(source "$P/scripts/common.sh" && sg_config)
RC=0; OUT=$("$CLAUDE_PLUGIN_DATA/bin/ast-grep" test -c "$cfg" --custom-languages allow --skip-snapshot-tests 2>&1); RC=$?
expect "rule tests pass" 0

echo "TESTS: $fails failed"
exit $((fails > 0))
