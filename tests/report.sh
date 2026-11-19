#!/usr/bin/env bash
# Tests for the auto-improve loop (plugins/iris-legacy/scripts/report.sh). Prints PASS/FAIL per
# check. Offline: a gh stand-in (tests/lib/gh-standin.sh) answers searches from the issues and
# pull requests captured from the real trackers (tests/fixtures/issues/), and records every
# `issue create` instead of posting it.
#
#   - Replay: this month's real findings (the 12 ascot issues, from their posted text in
#     tests/fixtures/findings/; the 106 iris-interop-dev issues filed since 2026-10-01; 8 paraphrases of earlier
#     iris-interop-dev findings) are all caught as duplicates or held as possible ones; nothing
#     is filed.
#   - Filing: a new generic finding gives exactly one issue, in the right repo for each mode;
#     filing it again files nothing; a re-capture of it is a duplicate of the first.
#   - Sanitizer: names from the project (the OMS fixture), deny terms, emails, addresses, host
#     names and user paths block filing, and are named; generic ObjectScript does not.
#   - Safety: a failed search, the daily limit, claude-code findings.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
R="$KIT/plugins/iris-legacy/scripts/report.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/iris-legacy-report.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0 passes=0
check() { if eval "$2"; then echo "PASS $1"; passes=$((passes + 1)); else echo "FAIL $1"; fails=$((fails + 1)); fi; }
section() { echo "== $1"; }

mkdir -p "$WORK/bin"
cp "$KIT/tests/lib/gh-standin.sh" "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" GH_FIXTURES="$KIT/tests/fixtures/issues" GH_LOG="$WORK/gh"
export CLAUDE_PLUGIN_DATA="${IRIS_LEGACY_TEST_DATA:-$KIT/.test-data}"
creates() { if [[ -f "$GH_LOG.creates" ]]; then wc -l <"$GH_LOG.creates" | tr -d ' '; else echo 0; fi; }

# project NAME: a fresh copy of the OMS fixture (its routines, classes and globals are the
# "customer" names the sanitizer must refuse), with an empty ledger
project() {
  rm -rf "$WORK/$1"; cp -R "$KIT/tests/fixtures/oms" "$WORK/$1"
  export CLAUDE_PROJECT_DIR="$WORK/$1"
}
last_id() { jq -r .id "$CLAUDE_PROJECT_DIR/.claude/kit-findings.jsonl" | tail -1; }
ascot_url=https://github.com/intersystems-community/ascot/issues
iid_url=https://github.com/intersystems-ib/iris-interop-dev/issues

# replay FILE MODE FINDINGS: add each {tool, title, symptom, expect} and try to file it; print
# "<expect> <rank of expect among DUPLICATE/possible lines> <verdict>" per finding
replay() {
  local line out id exp rank verdict
  while IFS= read -r line; do
    exp=$(jq -r .expect <<<"$line")
    jq -c '{tool, kind: "false-positive", title, symptom}' <<<"$line" | IRIS_LEGACY_REPORT_TO=$2 IRIS_LEGACY_FINDINGS=$3 "$R" add --json >/dev/null
    id=$(last_id)
    out=$(IRIS_LEGACY_REPORT_TO=$2 IRIS_LEGACY_FINDINGS=$3 "$R" file "$id" 2>&1)
    rank=$(grep -E '^  (DUPLICATE|possible ) ' <<<"$out" | awk '{print $NF}' | grep -n -F -x "$exp" | head -1 | cut -d: -f1)
    verdict=$(sed -n 's/^-- verdict: //p' <<<"$out")
    echo "$exp ${rank:-none} $verdict"
    # drop it again, so later replays are compared with the trackers, not with this one
    jq -c --arg id "$id" 'select(.id != $id)' "$CLAUDE_PROJECT_DIR/.claude/kit-findings.jsonl" >"$WORK/l" && mv "$WORK/l" "$CLAUDE_PROJECT_DIR/.claude/kit-findings.jsonl"
  done <"$1"
}

# ---------------------------------------------------------------------------------------------
section "routing"
project p0
check "kit mode: ascot goes to the kit repo" '[[ "$(IRIS_LEGACY_REPORT_TO=kit "$R" route ascot)" == intersystems-ib/iris-legacy-kit ]]'
check "default mode is kit" '[[ "$(env -u IRIS_LEGACY_REPORT_TO "$R" route iris-interop-dev)" == intersystems-ib/iris-legacy-kit ]]'
check "upstream mode: ascot" '[[ "$(IRIS_LEGACY_REPORT_TO=upstream "$R" route ascot)" == intersystems-community/ascot ]]'
check "upstream mode: iris-interop-dev" '[[ "$(IRIS_LEGACY_REPORT_TO=upstream "$R" route iris-interop-dev)" == intersystems-ib/iris-interop-dev ]]'
check "upstream mode: grammar" '[[ "$(IRIS_LEGACY_REPORT_TO=upstream "$R" route tree-sitter-objectscript)" == intersystems/tree-sitter-objectscript ]]'
check "upstream mode: the kit itself" '[[ "$(IRIS_LEGACY_REPORT_TO=upstream "$R" route kit)" == intersystems-ib/iris-legacy-kit ]]'
check "claude-code: /feedback" '[[ "$("$R" route claude-code)" == "claude-code: /feedback" ]]'
check "a wrong mode is refused" '! IRIS_LEGACY_REPORT_TO=public "$R" route ascot >/dev/null 2>&1'

section "capture"
check "unknown tool refused" '! "$R" add --tool vim --kind crash --title t --symptom s >/dev/null 2>&1'
check "unknown kind refused" '! "$R" add --tool ascot --kind annoying --title t --symptom s >/dev/null 2>&1'
check "a title is required" '! "$R" add --tool ascot --kind crash --symptom s >/dev/null 2>&1'
check "a finding is added" '"$R" add --tool ascot --kind crash --title "ascot crashes on an empty routine" --symptom "panic" >/dev/null && [[ $(wc -l <"$CLAUDE_PROJECT_DIR/.claude/kit-findings.jsonl") -eq 1 ]]'
check "its version is read from the installed tool" '[[ "$(jq -r .version "$CLAUDE_PROJECT_DIR/.claude/kit-findings.jsonl")" == "$(jq -r .ascot.version "$KIT/plugins/iris-legacy/versions.json")"* ]]'
check "session-start line names the unfiled finding" '[[ "$("$R" --hook)" == "iris-legacy kit: 1 tool finding(s) not filed yet"* ]]'
check "claude-code findings are not filed" 'id=$("$R" add --tool claude-code --kind hook --title "x" --symptom "y" | awk "NR == 1 {print \$2}" | tr -d :); ! "$R" file "$id" >"$WORK/cc" 2>&1 && grep -q "/feedback" "$WORK/cc"'
project p0b
check "session-start hook is silent without findings" '[[ -z "$("$R" --hook)" ]]'

# ---------------------------------------------------------------------------------------------
section "replay: ascot, this month (12 issues, posted text)"
for d in "$KIT"/tests/fixtures/findings/ascot/1[0-9][0-9]-*; do
  n=$(basename "$d" | cut -d- -f1)
  t=$(grep -E "\[#$n\]" "$KIT/tests/fixtures/findings/LEDGER.md" | awk -F'|' '{ gsub(/^ +| +$/, "", $5); print $5 }')
  s=$(awk '/^## Summary/ { f = 1; next } /^## / { if (f) exit } f' "$d/issue.md" | head -c 600)
  jq -n -c --arg t "$t" --arg s "$s" --arg e "$ascot_url/$n" '{tool: "ascot", title: $t, symptom: $s, expect: $e}'
done >"$WORK/ascot.jsonl"
project p1
replay "$WORK/ascot.jsonl" kit /nonexistent >"$WORK/r1"
check "12 ascot findings replayed" '[[ $(wc -l <"$WORK/r1") -eq 12 ]]'
check "customer site (no kit ledger): every one a duplicate of its own issue" '[[ $(awk "\$2 == 1 && \$3 == \"duplicate\"" "$WORK/r1" | wc -l) -eq 12 ]]'
replay "$WORK/ascot.jsonl" upstream "$KIT/tests/fixtures/findings" >"$WORK/r2"
check "owner (kit ledger, upstream mode): every one a duplicate of its own issue" '[[ $(awk "\$2 == 1 && \$3 == \"duplicate\"" "$WORK/r2" | wc -l) -eq 12 ]]'
check "nothing filed" '[[ $(creates) -eq 0 ]]'
awk '$2 != 1 || $3 != "duplicate"' "$WORK/r1" "$WORK/r2" | sed 's/^/    /'

section "replay: iris-interop-dev, filed since 2026-10-01 (106 issues)"
jq -c --slurpfile mine "$GH_FIXTURES/intersystems-ib__iris-interop-dev.mine-since-2026-10-01.json" '.[]
  | select(.number as $n | $mine[0] | index($n))
  | {tool: "iris-interop-dev", title, expect: .url,
     symptom: (.body | split("\n\n") | map(select(test("^[#>]") | not)) | .[0:2] | join("\n\n") | .[0:500])}' \
  "$GH_FIXTURES/intersystems-ib__iris-interop-dev.issues.json" >"$WORK/iid.jsonl"
project p2
replay "$WORK/iid.jsonl" upstream /nonexistent >"$WORK/r3"
check "106 iris-interop-dev findings replayed" '[[ $(wc -l <"$WORK/r3") -eq 106 ]]'
check "every one a duplicate of its own issue, ranked first" '[[ $(awk "\$2 == 1" "$WORK/r3" | wc -l) -eq 106 ]]'
check "none filed: duplicate, or blocked by the sanitizer" '[[ $(awk "\$3 == \"duplicate\" || \$3 == \"blocked\"" "$WORK/r3" | wc -l) -eq 106 && $(creates) -eq 0 ]]'
# #534 quotes an OMS demo routine name in its public text: in this (OMS) project that is blocked.
check "the one quoting an OMS routine name is blocked" 'grep -q "^$iid_url/534 1 blocked$" "$WORK/r3"'
awk '$2 != 1 || ($3 != "duplicate" && $3 != "blocked")' "$WORK/r3" | sed 's/^/    /'

section "replay: earlier iris-interop-dev findings, reworded"
cat >"$WORK/para.jsonl" <<EOF
{"tool":"iris-interop-dev","title":"iris_debug error_logs returns an empty list although the error log has entries","symptom":"The error_logs action of iris_debug answers success with no logs, while the namespace's application error log holds recent errors.","expect":"$iid_url/533"}
{"tool":"iris-interop-dev","title":"iris_debug map_int cannot resolve a routine frame like LABEL+2^RTN","symptom":"map_int answers ROUTINE_NOT_FOUND for a plain routine frame; it only looks up classes.","expect":"$iid_url/534"}
{"tool":"iris-interop-dev","title":"hook post-edit compiles into IRIS_NAMESPACE instead of the connection file's namespace","symptom":"With a .iris-agentic-dev.toml naming one namespace, the hook uploads and compiles into the namespace from the environment, default USER.","expect":"$iid_url/540"}
{"tool":"iris-interop-dev","title":"An unknown IRIS_TOOLSET value serves every tool instead of refusing","symptom":"A misspelt profile name falls back to the largest profile silently.","expect":"$iid_url/541"}
{"tool":"iris-interop-dev","title":"iris_doc put stores a routine with a [Type=INT] header as .mac","symptom":"Saving ROUTINE X [Type=INT] through iris_doc put creates X.mac rather than X.int.","expect":"$iid_url/537"}
{"tool":"iris-interop-dev","title":"hook post-edit compiles ObjectScript files outside the project","symptom":"Editing a .mac file in another directory makes the hook upload and compile it into IRIS.","expect":"$iid_url/549"}
{"tool":"iris-interop-dev","title":"iris_doc put returns success true for a document that Atelier refused","symptom":"The put reports success, but the document was not stored; Atelier answered with an error.","expect":"$iid_url/566"}
{"tool":"iris-interop-dev","title":"No release binary for Linux arm64","symptom":"On an aarch64 Linux host there is no asset; the x64 binary gets downloaded and fails to exec.","expect":"$iid_url/543"}
EOF
project p3
replay "$WORK/para.jsonl" upstream /nonexistent >"$WORK/r4"
check "each reworded finding finds its issue first" '[[ $(awk "\$2 == 1" "$WORK/r4" | wc -l) -eq 8 ]]'
check "each is a duplicate or held as a possible one; none filed" '[[ $(awk "\$3 == \"duplicate\" || \$3 == \"possible\"" "$WORK/r4" | wc -l) -eq 8 && $(creates) -eq 0 ]]'
sed 's/^/    /' "$WORK/r4"
jq -n -c '{tool: "iris-interop-dev", title: "Routine search finds no label on the last line of a routine without a final line break", symptom: "Searching routines for a label that is on the last line, with no line break after it, returns no match.", expect: "findings/LEDGER.md"}' >"$WORK/cand.jsonl"
replay "$WORK/cand.jsonl" upstream "$KIT/tests/fixtures/findings" >"$WORK/r5"
check "the kit ledger's open candidate holds a re-capture of it (owner decides)" 'grep -Eq "^findings/LEDGER.md 1 (duplicate|possible)$" "$WORK/r5"'

# ---------------------------------------------------------------------------------------------
section "filing a new finding"
mkdir -p "$WORK/scratch/src"
printf 'ROUTINE DEMO\nDEMO ; hover demo\n W $T(LBL^DEMO2),!\n Q\nLBL ; here\n Q\n' >"$WORK/scratch/src/DEMO.mac"
new_ascot() {
  "$R" add --tool ascot --kind wrong-data --title "Hover on a \$TEXT argument shows the comment of a label in another routine" \
    --symptom "Hovering over the label inside \$TEXT(LBL^DEMO2) shows the comment of LBL in the current routine." \
    --expected "The comment of LBL in DEMO2." --repro-text "ascot lsp, hover at line 2, character 8" \
    --repro-file "$WORK/scratch/src/DEMO.mac" >/dev/null
}
project p4
new_ascot; id=$(last_id)
check "check: clean and new" 'IRIS_LEGACY_REPORT_TO=kit "$R" check "$id" >"$WORK/c1" 2>&1 && grep -q "^-- verdict: ok$" "$WORK/c1"'
check "dry run files nothing" 'IRIS_LEGACY_REPORT_TO=kit "$R" file "$id" --dry-run >"$WORK/d1" 2>&1 && [[ $(creates) -eq 0 ]] && grep -q "would file to intersystems-ib/iris-legacy-kit" "$WORK/d1"'
check "kit mode: one issue in the kit repo, tool named in the title" 'IRIS_LEGACY_REPORT_TO=kit "$R" file "$id" >/dev/null 2>&1 && [[ $(creates) -eq 1 ]] && jq -e "select(.repo == \"intersystems-ib/iris-legacy-kit\" and (.title | startswith(\"[ascot] Hover\")))" "$GH_LOG.creates" >/dev/null'
check "the issue carries the repro file and the kit marker" 'tail -1 "$GH_LOG.creates" | jq -r .body | grep -q "^ROUTINE DEMO$" && tail -1 "$GH_LOG.creates" | jq -r .body | grep -q "^Reported with iris-legacy-kit "'
check "the ledger records the URL" '[[ "$(jq -r "select(.id == \"$id\") | .state + \" \" + .url" "$CLAUDE_PROJECT_DIR/.claude/kit-findings.jsonl")" == "filed https://github.com/intersystems-ib/iris-legacy-kit/issues/"* ]]'
check "filing it again files nothing" '! IRIS_LEGACY_REPORT_TO=kit "$R" file "$id" >"$WORK/f2" 2>&1 && grep -q "filed already" "$WORK/f2" && [[ $(creates) -eq 1 ]]'
new_ascot; id2=$(last_id)
check "a re-capture of it is a duplicate of the first" '! IRIS_LEGACY_REPORT_TO=kit "$R" file "$id2" >"$WORK/f3" 2>&1 && grep -q "^  DUPLICATE .*project ledger filed" "$WORK/f3" && [[ $(creates) -eq 1 ]]'
check "session-start line is silent once nothing is new" '[[ -z "$("$R" --hook)" ]]'
project p5
new_ascot; id=$(last_id)
check "upstream mode: one issue in the tool's repo, no prefix" 'IRIS_LEGACY_REPORT_TO=upstream "$R" file "$id" >/dev/null 2>&1 && [[ $(creates) -eq 2 ]] && tail -1 "$GH_LOG.creates" | jq -e "select(.repo == \"intersystems-community/ascot\" and (.title | startswith(\"Hover\")))" >/dev/null'
check "a possible duplicate needs --new" '"$R" add --tool iris-interop-dev --kind wrong-data --title "iris_debug error_logs returns an empty list although the error log has entries" --symptom "No logs, while the error log has entries." >/dev/null; p=$(last_id); ! IRIS_LEGACY_REPORT_TO=upstream "$R" file "$p" >"$WORK/pd1" 2>&1 && grep -q "possible duplicate" "$WORK/pd1" && [[ $(creates) -eq 2 ]]'
check "after reading it: --new files it and names the match" 'IRIS_LEGACY_REPORT_TO=upstream "$R" file "$p" --new >/dev/null 2>&1 && [[ $(creates) -eq 3 ]] && tail -1 "$GH_LOG.creates" | jq -r .body | grep -q "^- $iid_url/533 "'
check "mark: a duplicate is recorded, not filed" '"$R" add --tool ascot --kind crash --title "Another one" --symptom "x" >/dev/null; m=$(last_id); "$R" mark "$m" duplicate "$ascot_url/137" >/dev/null && ! "$R" file "$m" >/dev/null 2>&1 && [[ $(creates) -eq 3 ]]'

# ---------------------------------------------------------------------------------------------
section "sanitizer"
project p6
printf 'ROUTINE OMORDL\nOMORDL ; planted\n S ^SORDX("D",1)=""\n Q\n' >"$WORK/scratch/src/BAD.mac"
"$R" add --tool ascot --kind false-positive --title "A6851 on a label that exists" --symptom "ascot reports A6851." --repro-file "$WORK/scratch/src/BAD.mac" >/dev/null
id=$(last_id)
IRIS_LEGACY_REPORT_TO=kit "$R" check "$id" >"$WORK/s1" 2>&1
check "a planted routine name is blocked and named" 'grep -Eq "^    routine +OMORDL +in file BAD.mac" "$WORK/s1"'
check "a planted global is blocked and named" 'grep -Eq "^    global +SORDX +in file BAD.mac" "$WORK/s1"'
check "verdict blocked, nothing filed, ledger says blocked" '! IRIS_LEGACY_REPORT_TO=kit "$R" file "$id" >/dev/null 2>&1 && [[ $(creates) -eq 3 && "$(jq -r "select(.id == \"$id\") | .state" "$CLAUDE_PROJECT_DIR/.claude/kit-findings.jsonl")" == blocked ]]'
check "the block lists the terms in the ledger" '[[ "$(jq -r "select(.id == \"$id\") | [.blocked[].term] | sort | join(\",\")" "$CLAUDE_PROJECT_DIR/.claude/kit-findings.jsonl")" == *OMORDL*SORDX* ]]'
check "a blocked draft is not sent to GitHub search" '"$R" add --tool ascot --kind other --title "OMORDL gets A6851" --symptom "x" >/dev/null; IRIS_LEGACY_REPORT_TO=kit "$R" check "$(last_id)" >/dev/null 2>&1; ! grep -q OMORDL "$GH_LOG.calls"'
check "a missing repro file adds nothing and keeps the ledger" 'n=$(wc -l <"$CLAUDE_PROJECT_DIR/.claude/kit-findings.jsonl"); ! "$R" add --tool ascot --kind crash --title t --symptom s --repro-file "$WORK/nope.mac" >/dev/null 2>&1 && [[ $(wc -l <"$CLAUDE_PROJECT_DIR/.claude/kit-findings.jsonl") -eq $n ]]'
printf 'ROUTINE DEMO\nDEMO ; generic\n S ^X("D",1)=""\n Q\n' >"$WORK/scratch/src/BAD.mac"
check "rewritten generically: back to new, then clean" '"$R" update "$id" --repro-file "$WORK/scratch/src/BAD.mac" >/dev/null && IRIS_LEGACY_REPORT_TO=kit "$R" check "$id" >"$WORK/s2" 2>&1; grep -q "^  clean" "$WORK/s2"'

blocked_by() {  # blocked_by TEXT: the categories the sanitizer names for a symptom
  "$R" add --tool ascot --kind other --title "Generic title" --symptom "$1" >/dev/null
  IRIS_LEGACY_REPORT_TO=kit "$R" check "$(last_id)" 2>&1 | awk '/^-- sanitizer/ { f = 1; next } /^-- / { f = 0 } f && /^    / { print $1 }' | sort -u | tr '\n' ' '
}
jq '.report.denyTerms = ["Acme"]' "$CLAUDE_PROJECT_DIR/.claude/iris-legacy.json" >"$WORK/c" && mv "$WORK/c" "$CLAUDE_PROJECT_DIR/.claude/iris-legacy.json"
check "deny term, any case" '[[ "$(blocked_by "seen at ACME first")" == "deny " ]]'
check "the project namespace" '[[ "$(blocked_by "in namespace OMS")" == "namespace " ]]'
check "a class and its package" '[[ "$(blocked_by "OM.API.Order and OM.REST")" == "class package " ]]'
check "email" '[[ "$(blocked_by "mail jdoe@bigco.net")" == "email " ]]'
check "private address" '[[ "$(blocked_by "server 10.1.2.3")" == "ip " ]]'
check "site host name" '[[ "$(blocked_by "on iris01.corp.internal")" == "host " ]]'
check "user path" '[[ "$(blocked_by "in /Users/jdoe/work")" == "user " ]]'
check "generic ObjectScript and public hosts pass" '[[ -z "$(blocked_by "\$ORDER, \$\$\$OK, ^%ETN, %Status, ^X(1), D LBL^DEMO, 127.0.0.1, IRIS 2026.2.0.227.0, https://github.com/a/b, noreply@anthropic.com, ghcr.io")" ]]'

# ---------------------------------------------------------------------------------------------
section "safety"
project p7
new_ascot; id=$(last_id)
check "a failed search blocks filing" '! GH_STANDIN_FAIL=1 IRIS_LEGACY_REPORT_TO=kit "$R" file "$id" >"$WORK/x1" 2>&1 && grep -q "INCOMPLETE" "$WORK/x1" && [[ $(creates) -eq 3 ]]'
jq '.report.maxPerDay = 1' "$CLAUDE_PROJECT_DIR/.claude/iris-legacy.json" >"$WORK/c" && mv "$WORK/c" "$CLAUDE_PROJECT_DIR/.claude/iris-legacy.json"
"$R" file "$id" >/dev/null 2>&1
"$R" add --tool kit --kind hook --title "lint.sh --hook reports the same smell twice when a routine is edited twice in one turn" --symptom "Two edits give the message twice." >/dev/null
check "the daily limit holds the next one" '! "$R" file "$(last_id)" >"$WORK/x2" 2>&1 && grep -q "filed today already" "$WORK/x2" && [[ $(creates) -eq 4 ]]'
check "no unexpected gh calls" '! grep -vE "^(issue|pr) list |^issue create " "$GH_LOG.calls"'

echo "TESTS: $passes passed, $fails failed"
exit $((fails > 0))
