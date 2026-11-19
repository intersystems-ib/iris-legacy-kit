#!/usr/bin/env bash
# Smoke test: manifests validate, setup installs every pinned tool into an empty data directory,
# a second run downloads nothing, --check and --hook report correctly, and a wrong checksum is
# refused. Prints PASS/FAIL per check.
#
# No network: the install starts from the downloads kept in .test-data/dl (made once by
# `CLAUDE_PLUGIN_DATA="$PWD/.test-data" plugins/iris-legacy/scripts/setup.sh`), and a curl
# stand-in on PATH refuses anything but file:// URLs, so a download attempt fails the test.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$KIT/plugins/iris-legacy"
CACHE="${IRIS_LEGACY_TEST_DATA:-$KIT/.test-data}/dl"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/iris-legacy-smoke.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
# The versions come from versions.json, so a pin bump needs no change here.
want() { jq -r --arg t "$1" '.[$t] | (.reports // (.version | ltrimstr("v")))' "$PLUGIN/versions.json"; }
runs() { [[ "$("$CLAUDE_PLUGIN_DATA/bin/$1" --version 2>/dev/null | awk 'NR == 1 {print $2}')" == "$(want "$1")" ]]; }
listing() { ls -l "$CLAUDE_PLUGIN_DATA/dl" | if command -v md5sum >/dev/null; then md5sum; else md5; fi; }

if [[ $(find "$CACHE" -maxdepth 1 -type f ! -name '*.part' 2>/dev/null | wc -l) -lt 4 ]]; then
  echo "FAIL no kept downloads in $CACHE. Make them once with:"
  echo "  CLAUDE_PLUGIN_DATA=\"${CACHE%/dl}\" $PLUGIN/scripts/setup.sh"
  exit 1
fi
REAL_CURL=$(command -v curl)
mkdir -p "$WORK/nonet"
cat >"$WORK/nonet/curl" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in file://*) exec "$REAL_CURL" "\$@" ;; esac; done
echo "smoke.sh: blocked a network download: \$*" >&2
exit 99
EOF
chmod +x "$WORK/nonet/curl"
export PATH="$WORK/nonet:$PATH"

if command -v claude >/dev/null; then
  check "marketplace validates (strict)" 'claude plugin validate --strict "$KIT" >"$WORK/v1" 2>&1'
  check "plugin validates (strict)" 'claude plugin validate --strict "$PLUGIN" >"$WORK/v2" 2>&1'
  [[ $fails -eq 0 ]] || cat "$WORK/v1" "$WORK/v2"
else
  echo "SKIP manifest validation: the claude CLI is not installed (CI)"
fi

export CLAUDE_PLUGIN_DATA="$WORK/data"
check "--check on an empty data dir exits 1" '! "$PLUGIN/scripts/setup.sh" --check >"$WORK/c0" 2>&1'
mkdir -p "$CLAUDE_PLUGIN_DATA/dl" && find "$CACHE" -maxdepth 1 -type f ! -name '*.part' -exec cp {} "$CLAUDE_PLUGIN_DATA/dl/" \;
check "install succeeds" '"$PLUGIN/scripts/setup.sh" >"$WORK/i1" 2>&1'
cat "$WORK/i1"
check "every tool installed" '[[ $(grep -c "^installed" "$WORK/i1") -eq 4 ]]'
check "no network download attempted" '! grep -q "blocked a network download" "$WORK/i1"'
check "no sg alias installed" '[[ ! -e "$CLAUDE_PLUGIN_DATA/bin/sg" ]]'
check "iris-interop-dev runs, at the pinned version" 'runs iris-interop-dev'
check "ascot runs, at the pinned version" 'runs ascot'
check "ast-grep runs, at the pinned version" 'runs ast-grep'
check "ascot declarations installed, from the pinned package" '[[ -s "$CLAUDE_PLUGIN_DATA/ascot/declarations.d.json.gz" && "$(cat "$CLAUDE_PLUGIN_DATA/ascot/declarations.sha512")" == "$(jq -r .ascot.declarations.sha512 "$PLUGIN/versions.json")" ]]'
check "grammar unpacked" '[[ -f "$CLAUDE_PLUGIN_DATA/grammars/tree-sitter-objectscript-$(want tree-sitter-objectscript)/tree_sitter_objectscript_routine/_binding.abi3.so" ]]'

before=$(listing)
check "second run reports ok for all" '"$PLUGIN/scripts/setup.sh" >"$WORK/i2" 2>&1 && [[ $(grep -c "^ok" "$WORK/i2") -eq 4 ]]'
check "second run downloaded nothing" '[[ "$(listing)" == "$before" ]]'
check "--check exits 0 when installed" '"$PLUGIN/scripts/setup.sh" --check >/dev/null 2>&1'
check "--hook prints one ready line" '[[ "$("$PLUGIN/scripts/setup.sh" --hook)" == "iris-legacy kit: tools ready in "* ]]'

# A wrong pinned checksum must be refused, and the hook must still exit 0. The "download" is a
# file:// copy of the kept archive, so the checksum check runs on real bytes without network.
cp -R "$PLUGIN" "$WORK/tampered"
jq --arg c "$CACHE" '.ascot.url = "file://\($c)/{asset}" | .ascot.assets |= with_entries(.value.sha256 = ("0" * 64))' \
  "$PLUGIN/versions.json" >"$WORK/tampered/versions.json"
export CLAUDE_PLUGIN_DATA="$WORK/data2"
mkdir -p "$CLAUDE_PLUGIN_DATA/dl" && find "$CACHE" -maxdepth 1 -type f ! -name '*.part' -exec cp {} "$CLAUDE_PLUGIN_DATA/dl/" \;
check "wrong checksum refused" '! "$WORK/tampered/scripts/setup.sh" >"$WORK/t1" 2>&1 && grep -q "checksum mismatch" "$WORK/t1"'
check "wrong checksum leaves no ascot" '[[ ! -e "$CLAUDE_PLUGIN_DATA/bin/ascot" ]]'
check "--hook exits 0 and says not ready" 'out=$("$WORK/tampered/scripts/setup.sh" --hook); [[ $? -eq 0 && "$out" == *"tools not ready"* ]]'

# The same for the declarations: a wrong sha512 is refused, and ascot does not count as installed.
jq --arg c "$CACHE" '.ascot.url = "file://\($c)/{asset}" | .ascot.declarations.url = "file://\($c)/ascot-{version}.tgz"
  | .ascot.declarations.sha512 = ("0" * 128)' "$PLUGIN/versions.json" >"$WORK/tampered/versions.json"
export CLAUDE_PLUGIN_DATA="$WORK/data3"
mkdir -p "$CLAUDE_PLUGIN_DATA/dl" && find "$CACHE" -maxdepth 1 -type f ! -name '*.part' -exec cp {} "$CLAUDE_PLUGIN_DATA/dl/" \;
check "wrong declarations checksum refused" '! "$WORK/tampered/scripts/setup.sh" >"$WORK/t2" 2>&1 && grep -q "checksum mismatch: file://.*ascot-.*\.tgz" "$WORK/t2"'
check "no declarations installed" '[[ ! -e "$CLAUDE_PLUGIN_DATA/ascot/declarations.d.json.gz" ]]'

echo "TESTS: $fails failed"
exit $((fails > 0))
