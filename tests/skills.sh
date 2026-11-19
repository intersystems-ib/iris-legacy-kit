#!/usr/bin/env bash
# K4 skill tests. The global map behind map-globals: its summary of the OMS fixture matches the
# golden output, one global can be selected, JSON parses. The characterize template: it compiles,
# and its Capture and Drive helpers work, in the OMS demo's IRIS when its Atelier REST answers
# (as throwaway ZZ* probes, deleted again). Prints PASS/FAIL per check.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$KIT/plugins/iris-legacy"
export CLAUDE_PLUGIN_DATA="${IRIS_LEGACY_TEST_DATA:-$KIT/.test-data}" CLAUDE_PROJECT_DIR="$KIT/tests/fixtures/oms"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/iris-legacy-skills.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0 skips=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
skip() { echo "SKIP $1"; skips=$((skips + 1)); }
GM="$PLUGIN/scripts/globalmap.sh"

echo "== global map (map-globals)"
if command -v uv >/dev/null; then
  "$GM" --summary >"$WORK/s.md" 2>"$WORK/s.err"
  # The grammar version in the header line is checked on its own below, so a pin bump does not
  # need a new golden file unless the map itself changes.
  nover() { sed -E '3s/tree-sitter-objectscript [0-9.]+/tree-sitter-objectscript N/' "$1"; }
  check "summary matches the golden output" 'diff -u <(nover "$KIT/tests/fixtures/globalmap-summary.md") <(nover "$WORK/s.md") >"$WORK/s.diff"' || head -20 "$WORK/s.diff"
  check "the grammar version comes from the installed wheel" 'grep -q "tree-sitter-objectscript $(jq -r ".[\"tree-sitter-objectscript\"].version" "$PLUGIN/versions.json")" "$WORK/s.md"'
  "$GM" --json --global SORD >"$WORK/g.json" 2>&1
  check "--global SORD: ^SORD, plus indirect references that name it" 'jq -e "([.references[] | select(.shape != \"@\") | .glob] | unique == [\"SORD\"]) and ([.references[] | select(.shape == \"@\")] | length > 0)" "$WORK/g.json" >/dev/null'
  check "a path argument is relative to the project" '"$GM" --json src/rtn/OMORDL.mac | jq -e ".files == [\"src/rtn/OMORDL.mac\"]" >/dev/null'
  check "a missing path is an error" '! "$GM" src/nope >/dev/null 2>&1'
else
  skip "global map (no uv)"
fi
CLAUDE_PLUGIN_DATA="$WORK/empty" "$GM" --summary >"$WORK/e.out" 2>&1; rc=$?
check "no grammar installed: says to run setup" '[[ $rc != 0 ]] && grep -q "iris-legacy:setup" "$WORK/e.out"'

echo "== characterize template (live IRIS)"
if [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -K - http://localhost:46080/api/atelier/ <<<'user = "_SYSTEM:SYS"') != 200 ]] ||
   ! docker exec oms-iris true 2>/dev/null; then
  skip "template (the OMS demo's IRIS does not answer)"
else
  T="$PLUGIN/skills/characterize/Template.cls"
  sed 's/^Class App.Test.Legacy.RtnCharacterization Extends/Class ZZKit.CharTemplate Extends/' "$T" >"$WORK/ZZKit.CharTemplate.cls"
  awk '/^\/\/\/ Example job entry for Drive/ { exit } { print }' "$T" |
    sed 's/^Class App.Test.Legacy.RtnCharacterization Extends/Class ZZKit.CharProbe Extends/' >"$WORK/ZZKit.CharProbe.cls"
  printf 'ClassMethod DriveProbe()\n{\n    set U = "^"\n    do ^ZZKITCAP\n}\n\n}\n' >>"$WORK/ZZKit.CharProbe.cls"
  printf 'ROUTINE ZZKITCAP\nZZKITCAP ; kit probe, deleted again by tests/skills.sh\n write "header",!\n read x write "got:",x,!\n read y write "got:",y,!\n quit\nOUT write "line1",!,"line2" quit\nERR write "before",! set x=1/0 quit\n' >"$WORK/ZZKITCAP.mac"
  for f in ZZKit.CharTemplate.cls ZZKit.CharProbe.cls ZZKITCAP.mac; do docker cp -q "$WORK/$f" "oms-iris:/tmp/$f"; done
  docker exec -i oms-iris iris session IRIS -U OMS >"$WORK/t.out" 2>&1 <<'EOS'
set sc=$system.OBJ.Load("/tmp/ZZKITCAP.mac","ck-d") write "R:",$system.Status.IsOK(sc),!
set sc=$system.OBJ.Load("/tmp/ZZKit.CharTemplate.cls","ck-d") write "T:",$system.Status.IsOK(sc),!
set sc=$system.OBJ.Load("/tmp/ZZKit.CharProbe.cls","ck-d") write "P:",$system.Status.IsOK(sc),!
write "CAPTURE:",##class(ZZKit.CharProbe).Capture("OUT^ZZKITCAP"),"#",!
write "CAPERR:",##class(ZZKit.CharProbe).Capture("ERR^ZZKITCAP"),"#",!
write "DRIVE:",##class(ZZKit.CharProbe).Drive("DriveProbe",$lb("alpha","beta")),"#",!
write "SHORT:",##class(ZZKit.CharProbe).Drive("DriveProbe",$lb("alpha"),3),"#",!
do $system.OBJ.Delete("ZZKit.CharTemplate","-d"),$system.OBJ.Delete("ZZKit.CharProbe","-d") do ##class(%Routine).Delete("ZZKITCAP.MAC")
write "GONE:",'##class(%Dictionary.ClassDefinition).%ExistsId("ZZKit.CharTemplate"),'##class(%Dictionary.ClassDefinition).%ExistsId("ZZKit.CharProbe"),'##class(%Routine).Exists("ZZKITCAP.MAC"),!
halt
EOS
  docker exec -u root oms-iris rm -f /tmp/ZZKit.CharTemplate.cls /tmp/ZZKit.CharProbe.cls /tmp/ZZKITCAP.mac
  check "the template compiles" 'grep -q "^T:1" "$WORK/t.out" && grep -q "^R:1" "$WORK/t.out" && grep -q "^P:1" "$WORK/t.out"'
  check "Capture returns the printed lines" 'grep -qxF "CAPTURE:line1|line2#" "$WORK/t.out"'
  check "Capture reports an error in the label" 'grep -qF "CAPERR:before|<<DIVIDE> ERR^ZZKITCAP>#" "$WORK/t.out"'
  check "Drive answers the prompts and returns the output" 'grep -qxF "DRIVE:header|got:alpha|got:beta|#" "$WORK/t.out"'
  check "Drive with too few answers ends, with <ENDOFFILE>" 'grep "^SHORT:" "$WORK/t.out" | grep -q "<ENDOFFILE>"'
  check "probes deleted from OMS" 'grep -qxF "GONE:111" "$WORK/t.out"'
  [[ $fails == 0 ]] || cat "$WORK/t.out"
fi

echo "TESTS: $fails failed, $skips skipped"
exit $((fails > 0))
