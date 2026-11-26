#!/usr/bin/env bash
# K1 install test: add this checkout as a marketplace and install the plugin, both at project
# scope in a throwaway project, check that Claude Code sees the plugin and its components, then
# remove both. The user's own settings are not touched.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ=$(mktemp -d "${TMPDIR:-/tmp}/iris-legacy-install.XXXXXX")
cleanup() {
  (cd "$PROJ" && claude plugin uninstall iris-legacy@iris-legacy-kit --scope project >/dev/null 2>&1
   claude plugin marketplace remove iris-legacy-kit --scope project >/dev/null 2>&1)
  rm -rf "$PROJ"
}
trap cleanup EXIT
fails=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

cd "$PROJ" && git init -q
# Untouched means unchanged by this test: a user who added the marketplace for themselves already
# has its name in their settings, and that is not what this test is about.
user_settings() { cat "$HOME/.claude/settings.json" 2>/dev/null | cksum; }
before=$(user_settings)
check "marketplace added at project scope" 'claude plugin marketplace add "$KIT" --scope project >"$PROJ/m.out" 2>&1'
check "plugin installed at project scope" 'claude plugin install iris-legacy@iris-legacy-kit --scope project >"$PROJ/i.out" 2>&1'
cat "$PROJ/m.out" "$PROJ/i.out"
check "project settings enable the plugin" 'jq -e ".enabledPlugins[\"iris-legacy@iris-legacy-kit\"] == true" .claude/settings.json >/dev/null'
check "user settings untouched" '[[ "$(user_settings)" == "$before" ]]'
claude plugin details iris-legacy >"$PROJ/d.out" 2>&1
cat "$PROJ/d.out"
check "details list the skills" 'for s in legacy-routines-globals setup lint bootstrap map-globals characterize report-upstream; do grep -q "$s" "$PROJ/d.out" || exit 1; done'
check "details list the SessionStart hook" 'grep -qi "SessionStart" "$PROJ/d.out"'
check "details list the MCP server" 'grep -qE "MCP servers \(1\)" "$PROJ/d.out"'
check "details list the PostToolUse hooks" 'grep -q "PostToolUse" "$PROJ/d.out"'

echo "TESTS: $fails failed"
exit $((fails > 0))
