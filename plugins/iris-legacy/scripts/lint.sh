#!/usr/bin/env bash
# Static checks for a kit project's ObjectScript (tools from setup.sh).
#
#   lint.sh            filtered ascot diagnostics for every source dir, then every legacy-smell
#                      hit (ast-grep). Exit 1 if ascot found anything, 2 if it could not run.
#   lint.sh --smells [PATH...]   legacy-smell hits only, for the source dirs or the given paths
#   lint.sh --sarif    the filtered ascot diagnostics as SARIF 2.1.0 on stdout, for code scanning
#                      in CI. Exit 0 clean, 1 findings, 2 ascot could not run.
#   lint.sh --hook     Claude Code PostToolUse hook (hook JSON on stdin). Reports through exit 2
#                      and stderr: filtered ascot errors anywhere in the source dirs (so callers
#                      broken by the edit show up), and legacy smells the edit ADDED to the edited
#                      routine compared with its committed version. Silent otherwise, and silent
#                      when the tools are not installed or this is not a kit project. When ascot
#                      itself fails, a note says so without blaming the edit.
#
# ascot resolves IRIS's own classes, routines and include files from the pinned declarations
# setup.sh installs (IRIS Community, %SYS), never from the network; the project can put its own
# sources first with lint.ascotIris (a declarations file from `ascot declare`, for classes such as
# Ens.* and HS.* that %SYS lacks). ascot's own filter (-d) keeps the codes that were accurate on
# legacy code and silent on an unchanged tree (OMS demo evaluation, re-checked on ascot 0.7.0);
# lint.ascotCodes replaces the list. A missing % routine (A4439) is dropped: site routines such
# as ^%ZSTART live in %SYS on the instance, not in the declarations.
set -uo pipefail
source "$(dirname "$0")/common.sh"

DEFAULT_CODES="A1727 A8073 A6851 A4439 A7831 A2797 A3850 A9399 A5523 A1073 A3139 A8061 A7095"
ASCOT="$BIN/ascot"
DECL="${CLAUDE_PLUGIN_DATA:-/nonexistent}/ascot/declarations.d.json.gz"
SG="$BIN/ast-grep"

# lint_on ascot|smells: on unless the kit config says false (read directly: jq's // treats
# false as missing, so conf() cannot return it)
lint_on() { [[ "$(jq -r ".lint.$1" "$CONF" 2>/dev/null)" != false ]]; }

ascot_ready() { [[ -x "$ASCOT" && -f "$DECL" ]] && lint_on ascot; }

# A4439 for a % routine is not reported (see above); the same test for --format lsp and sarif.
JQ_KEEP='def keep($code; $msg): ($code != "A4439" and $code != "A3303") or ($msg | test("routine .%") | not);'

# ascot_run FORMAT: ascot on the source dirs with the code filter. Its stdout goes to $WORK/out,
# its stderr to $WORK/err; returns 3 when there is nothing to check, else ascot's status.
ascot_run() {
  local codes d dirs=() iris=()
  codes=$(conf '.lint.ascotCodes | join(" ")'); codes=${codes:-$DEFAULT_CODES}
  while IFS= read -r d; do [[ -n "$d" && -d "$ROOT/$d" ]] && dirs+=("$d"); done <<<"$(source_dirs)"
  [[ ${#dirs[@]} -gt 0 ]] || return 3
  while IFS= read -r d; do [[ -n "$d" ]] && iris+=(--iris "$d"); done <<<"$(conf '.lint.ascotIris[]?')"
  (cd "$ROOT" && "$ASCOT" analyze "${iris[@]+"${iris[@]}"}" --iris "$DECL" -d off:all -d "on:${codes// /,}" \
     --format "$1" "${dirs[@]}" >"$WORK/out" 2>"$WORK/err")
}

# ascot_filtered: one line per kept diagnostic, "error: path:line:col - message [CODE]"; nothing
# when ascot is off or not installed. When ascot did not run, returns 2 and says why on stderr.
ascot_filtered() {
  ascot_ready || return 0
  ascot_run lsp; [[ $? == 3 ]] && return 0
  if ! jq -e '.files | type == "array"' "$WORK/out" >/dev/null 2>&1; then
    echo "ascot did not run: $(head -3 "$WORK/err" | tr '\n' ' ')" >&2
    return 2
  fi
  jq -r "$JQ_KEEP"' .files[] | .uri as $u | .diagnostics[] | select(keep(.code; .message))
    | "\(.severity | ascii_downcase): \($u):\(.range.start.line + 1):\(.range.start.character + 1) - \(.message) [\(.code)]"' "$WORK/out"
}

sg_json() { "$SG" scan -c "$CFG" --custom-languages allow --json=compact "$1" 2>/dev/null \
  | jq -r '.[] | [.ruleId, .text, (.lines|gsub("^\\s+|\\s+$";"")), (.range.start.line+1|tostring), .message] | @tsv'; }

smells_ready() { [[ -x "$SG" && -d "$(grammar_dir)" ]] && lint_on smells; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/iris-legacy-lint.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

case "${1:-}" in
  --hook) ;;
  --sarif)
    [[ -f "$CONF" ]] || { echo "lint.sh: $ROOT has no .claude/iris-legacy.json" >&2; exit 2; }
    lint_on ascot || { echo "lint.sh: ascot is switched off in the kit config" >&2; exit 2; }
    ascot_ready || { echo "lint.sh: ascot or its declarations are not installed; run /iris-legacy:setup" >&2; exit 2; }
    ascot_run sarif; [[ $? == 3 ]] && { echo "lint.sh: no source dir to check" >&2; exit 2; }
    jq -e '.runs | type == "array"' "$WORK/out" >/dev/null 2>&1 \
      || { echo "lint.sh: ascot did not run: $(head -3 "$WORK/err" | tr '\n' ' ')" >&2; exit 2; }
    jq "$JQ_KEEP"' .runs |= map(.results |= map(select(keep(.ruleId; .message.text))))' "$WORK/out" >"$WORK/sarif" || exit 2
    cat "$WORK/sarif"
    [[ $(jq '[.runs[].results[]] | length' "$WORK/sarif") == 0 ]]; exit $? ;;
  --smells)
    shift
    [[ -f "$CONF" ]] || { echo "lint.sh: $ROOT has no .claude/iris-legacy.json" >&2; exit 2; }
    smells_ready || { echo "lint.sh: ast-grep or the grammars are not installed; run /iris-legacy:setup" >&2; exit 2; }
    CFG=$(sg_config)
    if [[ $# -eq 0 ]]; then while IFS= read -r d; do [[ -n "$d" ]] && set -- "$@" "$d"; done <<<"$(source_dirs)"; fi
    rm -rf "$WORK"
    cd "$ROOT" && exec "$SG" scan -c "$CFG" --custom-languages allow --report-style short "$@" ;;
  "")
    [[ -f "$CONF" ]] || { echo "lint.sh: $ROOT has no .claude/iris-legacy.json" >&2; exit 2; }
    out=$(ascot_filtered); rc=$?
    [[ -n "$out" ]] && echo "$out"
    if smells_ready; then
      CFG=$(sg_config)
      dirs=(); while IFS= read -r d; do [[ -n "$d" ]] && dirs+=("$d"); done <<<"$(source_dirs)"
      (cd "$ROOT" && "$SG" scan -c "$CFG" --custom-languages allow --report-style short "${dirs[@]}" 2>/dev/null)
    fi
    [[ $rc == 0 ]] || exit 2
    [[ -z "$out" ]]; exit $? ;;
  *) echo "usage: $0 [--hook | --sarif | --smells [PATH...]]" >&2; exit 64 ;;
esac

# Hook mode.
[[ -f "$CONF" ]] || exit 0
file=$(jq -r '.tool_input.file_path // empty' 2>/dev/null)
case "$file" in *.cls|*.mac|*.int|*.inc) ;; *) exit 0 ;; esac
dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd -P) || exit 0
in_dirs "$dir" "$(source_dirs)" || exit 0
file="$dir/$(basename "$file")"
msg=""
a=$(ascot_filtered 2>"$WORK/fail")
[[ -n "$a" ]] && msg+="ascot (static check of the source dirs after this edit):"$'\n'"$a"$'\n'
case "$file" in
  *.mac|*.int|*.inc)
    if smells_ready && [[ -f "$file" ]]; then
      CFG=$(sg_config)
      rel=${file#"$ROOT"/}; base="$WORK/$(basename "$file")"
      git -C "$ROOT" show "HEAD:$rel" >"$base" 2>/dev/null || : >"$base"
      sg_json "$base" | cut -f1-3 >"$WORK/before"
      # FILENAME, not NR==FNR: the "before" list is empty for a new or previously clean routine.
      s=$(sg_json "$file" | awk -F'\t' 'FILENAME==ARGV[1]{seen[$1"\t"$2"\t"$3]++; next}
             (seen[$1"\t"$2"\t"$3]-- > 0){next} {print "line "$4": "$1": "$5}' "$WORK/before" -)
      [[ -n "$s" ]] && msg+="Legacy smells added to $rel by this edit:"$'\n'"$s"$'\n'
    fi ;;
esac
fail=$(cat "$WORK/fail")
if [[ -z "$msg" ]]; then
  # ascot failing is a tool problem, not the edit's: say so as context, without blocking.
  [[ -n "$fail" ]] && jq -nc --arg m "Static check incomplete: $fail Run /iris-legacy:setup, or the iris-legacy:report-upstream skill if it persists." \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
  exit 0
fi
[[ -n "$fail" ]] && msg+="(Static check incomplete: $fail)"$'\n'
printf '%s' "$msg" >&2
exit 2
