#!/usr/bin/env bash
# The kit's auto-improve loop: capture tool defects in the project's findings ledger, check each
# one (sanitize and dedupe), and file it as a GitHub issue where it belongs.
#
#   report.sh add --tool T --kind K --title "..." --symptom "..." [--expected "..."]
#                 [--repro-text "..."] [--repro-file PATH]... [--version V]
#   report.sh add --json < finding.json      the same fields as a JSON object (repro files as
#                                            "reproFiles": [paths], repro text as "repro": {"text"})
#   report.sh update ID [the add flags]      change a finding; a blocked one goes back to new
#   report.sh list [--all]                   unfiled findings (--all: every finding)
#   report.sh show ID                        the finding as JSON
#   report.sh route TOOL                     the repo a finding for TOOL is filed to, this mode
#   report.sh check ID                       sanitize + dedupe, print the verdict; changes nothing
#   report.sh file ID [--new] [--dry-run]    check again, then file; --dry-run prints the issue.
#                                            --new: a possible duplicate was read and is not one
#   report.sh mark ID duplicate URL | dropped    record a decision: not filed
#   report.sh --hook                         SessionStart: one line when findings are unfiled
#
# Ledger: $PROJECT/.claude/kit-findings.jsonl, one finding per line, and its repro files under
# $PROJECT/.claude/kit-findings/<id>/. Both stay out of git.
#
# Where findings go: IRIS_LEGACY_REPORT_TO=kit (the default) files everything to the kit's own
# repo, with the tool named in the title; that is the mode for customer sites, where gh is logged
# in as the customer's developer. IRIS_LEGACY_REPORT_TO=upstream files to the tool's own repo
# (versions.json "issues"); that is the kit owner's mode.
#
# Tools: iris-interop-dev, ascot, ast-grep, tree-sitter-objectscript, kit (the kit's hooks,
# skills, smell rules, ascot filter, setup). claude-code findings go to /feedback, not here.
#
# Dedupe scores (0 to 1, from the title words, the body words and shared distinctive tokens such
# as diagnostic codes and tool names): a match at STRONG or above is a duplicate and blocks the
# finding; one at POSSIBLE or above holds it until someone reads the match and either marks the
# finding a duplicate or files it with --new. Calibrated on this month's findings: re-filed text
# scored 0.72 to 1, paraphrases of known issues 0.45 to 0.89, new findings 0.23 at most.
#
# Exit status: 0 ok, 1 refused or blocked (the reason is printed), 2 usage.
set -uo pipefail
source "$(dirname "$0")/common.sh"

LEDGER="$ROOT/.claude/kit-findings.jsonl"
FILES_DIR="$ROOT/.claude/kit-findings"
VERSIONS="$KIT/versions.json"
KINDS="false-positive wrong-data hook crash missing other"
MODE="${IRIS_LEGACY_REPORT_TO:-kit}"
STRONG=0.55     # a dedupe score at or above this is a duplicate
POSSIBLE=0.40   # at or above this, filing needs --new; named in the issue as possibly related

die() { echo "report.sh: $*" >&2; exit 1; }
usage() { sed -n '4,18p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

KIT_REPO=$(jq -r '.repository // empty' "$KIT/.claude-plugin/plugin.json" | sed -E 's#^https://github.com/##; s#\.git$##; s#/$##')
KIT_VERSION=$(jq -r '.version' "$KIT/.claude-plugin/plugin.json")

# The kit owner's findings ledger and repro folders (LEDGER.md and <tool>/<n>-<slug>/issue.md),
# kept outside this repo; absent from an installed plugin. IRIS_LEGACY_FINDINGS points at it.
FINDINGS="${IRIS_LEGACY_FINDINGS:-$KIT/../../findings}"

# The session-start hook must never fail, so only the other commands insist on a valid mode.
[[ "${1:-}" == --hook ]] || case "$MODE" in kit|upstream) ;; *) die "IRIS_LEGACY_REPORT_TO must be kit or upstream, not '$MODE'" ;; esac
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kit-report.XXXXXX") || die "cannot create a temporary directory"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------- routing ---------------------------------------------------------------------------

known_tool() {
  case "$1" in kit|claude-code) return 0 ;; esac
  jq -e --arg t "$1" 'has($t)' "$VERSIONS" >/dev/null
}

upstream_repo() {  # upstream_repo TOOL: the tool's own issue tracker
  if [[ "$1" == kit ]]; then echo "$KIT_REPO"; else jq -r --arg t "$1" '.[$t].issues // empty' "$VERSIONS"; fi
}

route() {  # route TOOL: where a finding is filed in this mode
  [[ "$1" == claude-code ]] && return 1
  if [[ "$MODE" == kit ]]; then echo "$KIT_REPO"; else upstream_repo "$1"; fi
}

tool_version() {  # the version the installed tool reports, else the pinned one
  local v=""
  case "$1" in
    kit) v="$KIT_VERSION" ;;
    claude-code) v=$(claude --version 2>/dev/null | awk 'NR==1 {print $1}') ;;
    tree-sitter-objectscript) v=$(jq -r '."tree-sitter-objectscript".version' "$VERSIONS") ;;
    *) [[ -x "$BIN/$1" ]] && v=$("$BIN/$1" --version 2>/dev/null | awk 'NR==1 {print $2}')
       [[ -n "$v" ]] || v="$(jq -r --arg t "$1" '.[$t].version' "$VERSIONS") (pinned; not installed)" ;;
  esac
  echo "$v"
}

# ---------- ledger ----------------------------------------------------------------------------

ledger() { if [[ -f "$LEDGER" ]]; then jq -c . "$LEDGER"; fi; }
get() { ledger | jq -c --arg id "$1" 'select(.id == $id)'; }

# put JSON: replace the finding with the same id, or append it. Refuses anything that is not a
# finding, and leaves the ledger as it was when the rewrite fails.
put() {
  jq -e 'type == "object" and (.id | type) == "string"' <<<"$1" >/dev/null 2>&1 || die "internal error, not a finding: ${1:0:80}"
  mkdir -p "$(dirname "$LEDGER")"
  local tmp="$LEDGER.tmp.$$"
  if { ledger | jq -c --argjson f "$1" 'select(.id != $f.id)' && echo "$1"; } >"$tmp"; then
    mv "$tmp" "$LEDGER"
  else
    rm -f "$tmp"; die "could not update $LEDGER"
  fi
}

new_id() {
  local day n
  day=$(date +%Y%m%d)
  n=$(ledger | jq -r --arg p "F-$day-" 'select(.id | startswith($p)) | .id | ltrimstr($p) | tonumber' | sort -n | tail -1)
  echo "F-$day-$(( ${n:-0} + 1 ))"
}

# parse_fields ARGS...: the add/update flags as a JSON object of the fields given
parse_fields() {
  local f='{}' files=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tool|--kind|--title|--symptom|--expected|--version)
        [[ $# -ge 2 ]] || usage
        f=$(jq -c --arg k "${1#--}" --arg v "$2" '.[$k] = $v' <<<"$f"); shift 2 ;;
      --repro-text) [[ $# -ge 2 ]] || usage; f=$(jq -c --arg v "$2" '.repro.text = $v' <<<"$f"); shift 2 ;;
      --repro-file) [[ $# -ge 2 ]] || usage; files+=("$2"); shift 2 ;;
      --json) f=$(jq -c --argjson g "$f" '$g + . | if .reproFiles then .repro.files_in = .reproFiles | del(.reproFiles) else . end' 2>/dev/null) \
                || die "--json: stdin is not a JSON object"; shift ;;
      *) echo "report.sh: unknown option $1" >&2; usage ;;
    esac
  done
  if [[ ${#files[@]} -gt 0 ]]; then
    f=$(jq -c '.repro.files_in = $ARGS.positional' --args "${files[@]}" <<<"$f")
  fi
  echo "$f"
}

# store_files ID JSON: copy repro files named in .repro.files_in into the finding's folder, so the
# finding keeps the repro it was checked with; record their names in .repro.files
store_files() {
  local id=$1 f=$2 dir="$FILES_DIR/$1" p names=()
  local list; list=$(jq -r '.repro.files_in[]?' <<<"$f")
  [[ -n "$list" ]] || { jq -c 'del(.repro.files_in)' <<<"$f"; return; }
  mkdir -p "$dir"
  while IFS= read -r p; do
    [[ -f "$p" ]] || die "repro file not found: $p"
    cp "$p" "$dir/$(basename "$p")" && names+=("$(basename "$p")")
  done <<<"$list"
  jq -c '.repro.files = ((.repro.files // []) + $ARGS.positional | unique) | del(.repro.files_in)' --args "${names[@]}" <<<"$f"
}

validate() {  # validate JSON: the fields a finding needs
  local f=$1 t k
  t=$(jq -r '.tool // empty' <<<"$f"); k=$(jq -r '.kind // empty' <<<"$f")
  [[ -n "$t" ]] || die "a finding needs --tool"
  known_tool "$t" || die "unknown tool '$t' (iris-interop-dev, ascot, ast-grep, tree-sitter-objectscript, kit, claude-code)"
  [[ -n "$k" ]] || die "a finding needs --kind ($KINDS)"
  [[ " $KINDS " == *" $k "* ]] || die "unknown kind '$k' ($KINDS)"
  [[ -n "$(jq -r '.title // empty' <<<"$f")" ]] || die "a finding needs --title"
  [[ -n "$(jq -r '.symptom // empty' <<<"$f")" ]] || die "a finding needs --symptom"
}

cmd_add() {
  local f id
  f=$(parse_fields "$@") || exit $?
  validate "$f"
  id=$(new_id)
  [[ -n "$(jq -r '.version // empty' <<<"$f")" ]] || f=$(jq -c --arg v "$(tool_version "$(jq -r .tool <<<"$f")")" '.version = $v' <<<"$f")
  f=$(jq -c --arg id "$id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id: $id, created: $now, state: "new", links: []} + . | .repro = (.repro // {})' <<<"$f")
  f=$(store_files "$id" "$f") || exit 1
  put "$f"
  echo "added $id: $(jq -r '"\(.tool) \(.version): \(.title)"' <<<"$f")"
  [[ "$(jq -r .tool <<<"$f")" == claude-code ]] && echo "  claude-code findings are not filed by the kit: send them with /feedback"
  return 0
}

cmd_update() {
  local id=${1:-} f old new
  [[ -n "$id" ]] || usage
  shift
  old=$(get "$id"); [[ -n "$old" ]] || die "no finding $id"
  [[ "$(jq -r .state <<<"$old")" != filed ]] || die "$id is filed already: $(jq -r .url <<<"$old")"
  new=$(parse_fields "$@") || exit $?
  f=$(jq -c --argjson new "$new" '. * $new | if .state == "blocked" then .state = "new" | del(.blocked) else . end' <<<"$old")
  validate "$f"
  f=$(store_files "$id" "$f") || exit 1
  put "$f"
  echo "updated $id ($(jq -r .state <<<"$f"))"
}

cmd_list() {
  local all=${1:-}
  ledger | jq -r --arg all "$all" 'select($all == "--all" or (.state != "filed" and .state != "duplicate" and .state != "dropped"))
    | [.id, .state, .tool, .title, (.url // "")] | @tsv' | awk -F'\t' '{ printf "%-14s %-9s %-24s %s %s\n", $1, $2, $3, $4, $5 }'
}

# ---------- sanitizer -------------------------------------------------------------------------

# Names that appear in every IRIS system or tool repro; never treated as the project's.
GENERIC_NAMES="TMP UTILITY ERRORS ROUTINE rMAC rINC rINT rOBJ rINDEX rMACSAVE oddDEF oddCOM oddPROC mtemp CacheTemp IRIS ISC SYS USER UnitTest SPOOL"

# project_terms: the project's identifiers, one "category<TAB>term" per line
project_terms() {
  local dirs=() d files
  while IFS= read -r d; do [[ -n "$d" && -d "$ROOT/$d" ]] && dirs+=("$ROOT/$d"); done <<<"$(source_dirs)"
  # Without configured source dirs, everything in the project counts as the project's code.
  [[ ${#dirs[@]} -gt 0 ]] || dirs=("$ROOT")
  files=$(find "${dirs[@]}" \( -name .git -o -name .claude -o -name node_modules \) -prune -o -type f \
    \( -iname '*.mac' -o -iname '*.int' -o -iname '*.inc' -o -iname '*.rtn' -o -iname '*.m' -o -iname '*.cls' -o -iname '*.xml' \) -print 2>/dev/null)
  if [[ -n "$files" ]]; then
    # routines: ROUTINE headers and file names
    while IFS= read -r p; do
      case "$p" in *.cls|*.CLS|*.xml|*.XML) ;; *) b=$(basename "$p"); printf 'routine\t%s\n' "${b%.*}" ;; esac
    done <<<"$files"
    tr '\n' '\0' <<<"$files" | xargs -0 grep -h -E '^ROUTINE[[:space:]]+[%A-Za-z0-9.]+' 2>/dev/null \
      | awk '{ sub(/\[.*/, "", $2); printf "routine\t%s\n", $2 }'
    # classes and their packages
    tr '\n' '\0' <<<"$files" | xargs -0 grep -h -o -E '^Class[[:space:]]+[%A-Za-z][A-Za-z0-9.]*' 2>/dev/null \
      | awk '{ n = split($2, p, "."); printf "class\t%s\n", $2; pk = p[1]; for (i = 1; i < n; i++) { printf "package\t%s\n", pk; pk = pk "." p[i+1] } }'
    # globals used in the code (routine references are covered above anyway)
    tr '\n' '\0' <<<"$files" | xargs -0 grep -h -o -E '\^[A-Za-z][A-Za-z0-9.]*' 2>/dev/null \
      | sed -E 's/^\^//; s/\.+$//' | awk '{ printf "global\t%s\n", $0 }'
  fi
  # the connection: namespace, host and user unless they are the defaults every install has
  local toml="$ROOT/.iris-agentic-dev.toml" v
  if [[ -f "$toml" ]]; then
    v=$(sed -n -E 's/^[[:space:]]*namespace[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$toml" | head -1)
    case "$v" in ""|USER|%SYS|SAMPLES) ;; *) printf 'namespace\t%s\n' "$v" ;; esac
    v=$(sed -n -E 's/^[[:space:]]*host[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$toml" | head -1)
    case "$v" in ""|localhost|127.0.0.1|::1|iris) ;; *) printf 'host\t%s\n' "$v" ;; esac
    v=$(sed -n -E 's/^[[:space:]]*username[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$toml" | head -1)
    case "$v" in ""|_SYSTEM|SuperUser|Admin|_system) ;; *) printf 'username\t%s\n' "$v" ;; esac
  fi
  conf '.report.denyTerms[]?' | awk 'NF { printf "deny\t%s\n", $0 }'
}

# draft_text JSON: everything the issue would carry, as "where<TAB>line" lines
draft_text() {
  local f=$1 id n
  id=$(jq -r .id <<<"$f")
  jq -r '(["title", .title], ["symptom", (.symptom // "")], ["expected", (.expected // "")], ["repro", (.repro.text // "")])
    | . as [$w, $t] | $t | split("\n")[] | "\($w)\t\(.)"' <<<"$f"
  while IFS= read -r n; do
    [[ -n "$n" && -f "$FILES_DIR/$id/$n" ]] && awk -v w="file $n" '{ print w "\t" $0 }' "$FILES_DIR/$id/$n"
  done <<<"$(jq -r '.repro.files[]?' <<<"$f")"
  return 0
}

# sanitize JSON: print each blocked term as "category<TAB>term<TAB>where"; status 1 if any
sanitize() {
  # Files, not arguments: a large project has more names than a command line holds.
  local terms="$TMP_DIR/terms.json" draft="$TMP_DIR/draft.json" out
  project_terms | awk -F'\t' -v generic="$GENERIC_NAMES" '
    BEGIN { n = split(generic, g, " "); for (i = 1; i <= n; i++) skip[g[i]] = 1 }
    length($2) >= 2 && !($2 in skip) && !seen[$2]++' | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {c: .[0], t: .[1]})' >"$terms"
  draft_text "$1" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {w: .[0], l: (.[1:] | join("\t"))})' >"$draft"
  out=$(jq -r -n --slurpfile terms "$terms" --slurpfile draft "$draft" '
    def esc: gsub("(?<c>[.^$*+?()\\[\\]{}|\\\\])"; "\\\(.c)");
    # a project name as a whole token: not inside a longer identifier, not a $function or %name
    def tokre: "(?<![A-Za-z0-9_$%.])" + esc + "(?![A-Za-z0-9_])";
    # public developer hosts that repros and issues name; anything else belongs to the site
    def allowed_host: test("(^|\\.)(github\\.com|githubusercontent\\.com|ghcr\\.io|github\\.io|intersystems\\.com|pypi\\.org|pythonhosted\\.org|python\\.org|crates\\.io|docs\\.rs|rust-lang\\.org|npmjs\\.(com|org)|docker\\.(com|io)|microsoft\\.com|visualstudio\\.com|modelcontextprotocol\\.io|json-schema\\.org|oasis-open\\.org|cyclonedx\\.org|rustsec\\.org|example\\.(com|org|net)|anthropic\\.com|claude\\.(ai|com))$"; "i");
    def allowed_ip: test("^(127\\.|0\\.0\\.0\\.0$|192\\.0\\.2\\.|198\\.51\\.100\\.|203\\.0\\.113\\.)");
    def allowed_email: test("(@users\\.noreply\\.github\\.com|^noreply@anthropic\\.com|@example\\.(com|org|net))$"; "i");
    ($draft[0] | map(.l) | join("\n")) as $all
    | [$terms[0][] | select(.c == "deny" or (. as $x | $all | contains($x.t)))] as $present
    | [ $draft[0][] as $d |
      ( $present[] | . as $x
        | select(($d.l | test($x.t | tokre)) or ($x.c == "deny" and ($d.l | test("(?<![A-Za-z0-9])" + ($x.t | esc) + "(?![A-Za-z0-9])"; "i"))))
        | [$x.c, $x.t, $d.w] ),
      ( $d.l | [scan("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")] | .[] | select(allowed_email | not) | ["email", ., $d.w] ),
      ( $d.l | [scan("(?<![0-9.])(?:[0-9]{1,3}\\.){3}[0-9]{1,3}(?![0-9.])")] | .[]
        | select((split(".") | map(tonumber) | all(. <= 255)) and (allowed_ip | not)) | ["ip address", ., $d.w] ),
      ( $d.l | [scan("(?<![A-Za-z0-9.@-])(?:[A-Za-z0-9-]+\\.)+(?:com|net|org|io|local|lan|corp|internal|intra|cloud|eu|es|de|fr|uk|nl|it|be|ch|us|ca|au|pt|se|no|dk|fi|pl|at|ie)(?![A-Za-z0-9.-])"; "i")] | .[]
        | select(allowed_host | not) | ["host name", ., $d.w] ),
      ( $d.l | [scan("(?:/Users/|/home/|[A-Za-z]:\\\\Users\\\\)[^/\\\\[:space:]]+")] | .[] | ["user path", ., $d.w] )
    ] | unique | .[] | @tsv' | awk 'NF')
  [[ -z "$out" ]] && return 0
  printf '%s\n' "$out"
  return 1
}

# ---------- dedupe ----------------------------------------------------------------------------

# The tokenizer and score, shared by every comparison. A text becomes word stems (t: title, b: body)
# and distinctive tokens (d: diagnostic codes, $functions, snake_case and CamelCase names, flags,
# %classes), which count across title and body.
JQ_LIB='
def stopwords: ["the","and","for","with","from","that","this","are","not","but","its","into","when","then","than",
  "has","have","had","was","were","been","being","can","cannot","does","doesn","don","isn","aren","won","on","in",
  "of","to","an","is","it","or","by","as","at","be","no","all","any","every","each","only","also","still","even",
  "just","which","what","who","why","how","there","their","them","they","one","two","out","now","our","you","your",
  "should","would","could","will","may","might","must","get","gets","got","via","per","more","very","same","such",
  "like","here","these","those","so","if","do","does","did","a"];
def stem: if test("^[a-z]+$") | not then .
  else (if length > 5 and endswith("ing") then .[:-3]
        elif length > 4 and endswith("ies") then .[:-3] + "y"
        elif length > 4 and endswith("ed") then .[:-2]
        elif length > 4 and test("(s|x|ch|sh)es$") then .[:-2]
        elif length > 3 and endswith("s") and (endswith("ss") | not) then .[:-1]
        else . end)
       | if length > 4 and endswith("e") then .[:-1] else . end end;
def words: ascii_downcase | [scan("[$%]?[a-z0-9_]+")] | map(select(length >= 3 and (. as $w | stopwords | index([$w]) | not)) | stem) | unique;
def distinct: [scan("\\b[A-Z][0-9]{4}\\b"), scan("\\${1,3}[A-Za-z]+"), scan("\\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+\\b"),
  scan("--[a-z][a-z-]+"), scan("\\b[a-z]+[A-Z][A-Za-z0-9]*\\b"), scan("\\b[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*\\b"),
  scan("%[A-Z][A-Za-z0-9.]+")] | map(ascii_downcase) | unique;
def prep: {t: (.title | words), b: ((.body // "") | words), d: ((.title + "\n" + (.body // "")) | distinct)};
def inter($a; $b): [$a[] | select(. as $x | $b | index([$x]))];
def score($f; $c):
  (inter($f.t; $c.t) | length) as $tt
  | (inter($f.t; $c.t + $c.b) | length) as $ta
  | (inter($f.d; $c.d) | length) as $dd
  | ($f.t | length) as $nf | ($c.t | length) as $nc
  | (if $nf == 0 then 0 else $tt / $nf end) as $cov
  | (if $nc == 0 then 0 else $tt / $nc end) as $rev
  | (if $nf == 0 then 0 else $ta / $nf end) as $all
  | 0.45 * $cov + 0.2 * $rev + 0.2 * $all + 0.15 * ([$dd, 2] | min) / 2
  | . * 100 | round / 100;
'

# finding_doc JSON: the finding as a {title, body} document for scoring
finding_doc() { jq -c '{title, body: ([.symptom, (.expected // ""), (.repro.text // "")] | join("\n"))}' <<<"$1"; }

# kit_ledger_docs TOOL: the kit repo's own record (filed, fixed upstream, open candidates) as docs
kit_ledger_docs() {
  local tool=$1 L="$FINDINGS/LEDGER.md"
  [[ -f "$L" ]] || return 0
  # Join each candidate bullet with its continuation lines.
  awk '/^- / { if (b != "") print b; b = $0; next } /^  [^ ]/ && b != "" { sub(/^ +/, " "); b = b $0; next } { if (b != "") print b; b = ""; print } END { if (b != "") print b }' "$L" \
  | jq -R -c --arg tool "$tool" --arg dir "$FINDINGS" '
      capture("^\\| *[0-9]{4}-[0-9]{2}-[0-9]{2} *\\| *(?<tool>[^ |]+) *\\| *\\[#(?<n>[0-9]+)\\]\\((?<url>[^)]+)\\) *\\| *(?<title>.+?) *\\| *[^|]* *\\| *$")
        // capture("^\\| *`(?<tool>[a-z-]+)/(?<folder>[^`]+)` *\\| *(?<title>.+?) *\\| *(?<fixed>.+?) *\\| *$")
        // capture("^- (?<tool>[a-z-]+): (?<title>.+)$")
        // empty
      | select(.tool == $tool)
      | if .n then {source: "kit ledger", title, url, state: "filed", n}
        elif .folder then {source: "kit ledger", title, url: "findings/\(.tool)/\(.folder)", state: "fixed upstream (\(.fixed))"}
        else {source: "kit ledger", title, url: "findings/LEDGER.md", state: "open candidate"} end'
}

# kit_issue_body TOOL N: the posted text of a filed finding, from its folder
kit_issue_body() {
  local f
  for f in "$FINDINGS/$1/$2"-*/issue.md; do [[ -f "$f" ]] && head -c 1500 "$f"; return 0; done
}

# Failed searches go to a file, not a variable: candidates runs in a command substitution, and a
# failure must reach the verdict (no answer from GitHub is not "no duplicates").
SEARCH_LOG=""
# gh_docs KIND REPO [QUERY]: issues or PRs matching QUERY in REPO (open and closed) as docs; with
# no query, the latest 300 (a plain listing, which does not count against the search rate limit)
gh_docs() {
  local out what="$1 list" args=(--limit 300)
  if [[ -n "${3:-}" ]]; then args=(--limit 15 --search "$3"); what="$1 search \"$3\""; fi
  if ! out=$(gh "$1" list -R "$2" --state all "${args[@]}" --json number,title,state,url,body 2>&1); then
    echo "  $2 ($what): $(head -1 <<<"$out")" >>"$SEARCH_LOG"
    return 0
  fi
  jq -c --arg kind "$1" '.[] | {source: (if $kind == "pr" then "pull request" else "issue" end), title, url, state: (.state | ascii_downcase), body: ((.body // "")[0:1500])}' <<<"$out" 2>/dev/null
}

# search_queries JSON: GitHub searches for a finding: each distinctive token, then two keyword
# groups from the title (GitHub ANDs the words of a query)
search_queries() {
  jq -r "$JQ_LIB"'
    (.title | distinct | map(select(test("^--") | not)) | .[0:3] | .[]),
    (.title | ascii_downcase | [scan("[a-z][a-z0-9_]+")] | map(select(length >= 4 and (. as $w | stopwords | index([$w]) | not))) | unique
      | sort_by(-length) | (.[0:3] | join(" ")), (.[3:6] | select(length > 0) | join(" ")))' <<<"$1" | awk 'NF && !seen[$0]++'
}

# candidates JSON: every document the finding could duplicate, as JSON lines. With LOCAL_ONLY set
# (the title was blocked), GitHub is not searched: the search text would carry the blocked names.
candidates() {
  local f=$1 tool id up q repos=()
  tool=$(jq -r .tool <<<"$f"); id=$(jq -r .id <<<"$f")
  # the project's own ledger
  ledger | jq -c --arg id "$id" --arg tool "$tool" 'select(.id != $id and .tool == $tool and .state != "blocked")
    | {source: "project ledger", title, url: (.url // "ledger:\(.id)"), state, body: ([.symptom, (.expected // "")] | join("\n"))}'
  # the kit's ledger, with the posted text for filed findings
  kit_ledger_docs "$tool" | while IFS= read -r d; do
    n=$(jq -r '.n // empty' <<<"$d")
    jq -c --arg b "$( [[ -n "$n" ]] && kit_issue_body "$tool" "$n")" '. + {body: $b} | del(.n)' <<<"$d"
  done
  [[ -z "${LOCAL_ONLY:-}" ]] || return 0
  command -v gh >/dev/null || { echo "  gh is not installed" >>"$SEARCH_LOG"; return 0; }
  # GitHub: the tool's tracker, searched (issues with every query, pull requests with the first
  # two: about 7 searches, inside GitHub's 30 a minute); the kit repo, small, listed whole in kit
  # mode. In upstream mode the kit repo is not consulted: a customer-site report there is what
  # the owner is promoting upstream.
  up=$(upstream_repo "$tool")
  if [[ -n "$up" && "$up" != "$KIT_REPO" ]]; then
    local i=0
    while IFS= read -r q; do
      [[ -n "$q" ]] || continue
      i=$((i + 1))
      gh_docs issue "$up" "$q"
      [[ $i -le 2 ]] && gh_docs pr "$up" "$q"
    done <<<"$(search_queries "$f")"
  fi
  if [[ "$MODE" == kit || "$up" == "$KIT_REPO" ]]; then
    gh_docs issue "$KIT_REPO"
  fi
  return 0
}

# dedupe JSON: scored candidates, best first, as JSON lines {score, source, state, url, title}
dedupe() {
  local f=$1 docs="$TMP_DIR/docs.json"
  candidates "$f" | jq -s -c 'unique_by(.url)' >"$docs"
  jq -c -n "$JQ_LIB"'
    ($f | prep) as $p
    | [$docs[0][] | . as $c | {score: score($p; ($c | prep)), source, state, url, title}]
    | map(select(.score >= 0.2)) | sort_by(-.score) | .[0:5] | .[]' --argjson f "$(finding_doc "$f")" --slurpfile docs "$docs"
}

# ---------- check and file --------------------------------------------------------------------

# verdict ID: print the check; sets VERDICT (ok, blocked, duplicate, incomplete), MATCHES, BLOCKED
verdict() {
  local f=$1 tool repo failed
  tool=$(jq -r .tool <<<"$f")
  VERDICT=ok MATCHES="" BLOCKED=""
  echo "== $(jq -r '"\(.id) [\(.state)] \(.tool) \(.version): \(.title)"' <<<"$f")"
  if [[ "$tool" == claude-code ]]; then
    echo "  claude-code findings are not filed by the kit: send them with /feedback"
    VERDICT=refused; return
  fi
  repo=$(route "$tool")
  echo "  mode $MODE: files to $repo"

  echo "-- sanitizer"
  if BLOCKED=$(sanitize "$f" 2>/dev/null); then
    echo "  clean: no project names, hosts, addresses or user paths"
  else
    VERDICT=blocked
    echo "  BLOCKED: the draft contains names from this project or this site. Rewrite the repro generically:"
    awk -F'\t' '{ printf "    %-10s %-30s in %s\n", $1, $2, $3 }' <<<"$BLOCKED"
  fi

  echo "-- duplicates"
  SEARCH_LOG="$TMP_DIR/search-failures"; : >"$SEARCH_LOG"
  # The searches are built from the title alone, so only a blocked title keeps them local.
  if [[ "$VERDICT" == blocked ]] && awk -F'\t' '$3 == "title" { found = 1 } END { exit !found }' <<<"$BLOCKED"; then
    echo "  GitHub not searched until the title is clean; local ledgers only"
    MATCHES=$(LOCAL_ONLY=1 dedupe "$f")
  else
    MATCHES=$(dedupe "$f")
  fi
  failed=$(cat "$SEARCH_LOG")
  if [[ -n "$MATCHES" ]]; then
    jq -r --argjson s "$STRONG" --argjson p "$POSSIBLE" '
      "  \(if .score >= $s then "DUPLICATE" elif .score >= $p then "possible " else "weak     " end) \(.score)  \(.source) \(.state)  \(.url)\n             \(.title)"' <<<"$MATCHES"
  else
    echo "  no similar issue, pull request or ledger entry"
  fi
  if [[ -n "$failed" ]]; then
    printf '  INCOMPLETE: a search failed, so a duplicate cannot be ruled out:\n%s\n' "$failed"
    [[ "$VERDICT" == ok ]] && VERDICT=incomplete
  fi
  if [[ -n "$MATCHES" && "$VERDICT" != blocked ]]; then
    if jq -e -s --argjson s "$STRONG" 'any(.[]; .score >= $s)' <<<"$MATCHES" >/dev/null; then
      VERDICT=duplicate
    elif [[ "$VERDICT" == ok ]] && jq -e -s --argjson p "$POSSIBLE" 'any(.[]; .score >= $p)' <<<"$MATCHES" >/dev/null; then
      VERDICT=possible
      echo "  POSSIBLE duplicate: read the match. Same defect: report.sh mark $(jq -r .id <<<"$f") duplicate URL. Different: report.sh file $(jq -r .id <<<"$f") --new"
    fi
  fi
  echo "-- verdict: $VERDICT"
}

cmd_check() {
  local f
  f=$(get "${1:-}"); [[ -n "$f" ]] || die "no finding ${1:-}"
  verdict "$f"
  [[ "$VERDICT" == ok ]]
}

issue_title() {
  if [[ "$MODE" == kit ]]; then jq -r '"[\(.tool)] \(.title)"' <<<"$1"; else jq -r .title <<<"$1"; fi
}

issue_body() {
  local f=$1 id n lang
  id=$(jq -r .id <<<"$f")
  jq -r '"## Summary\n\n\(.symptom)\n" + (if (.expected // "") != "" then "\n## Expected\n\n\(.expected)\n" else "" end)
    + "\n## Repro" + (if (.repro.text // "") != "" then "\n\n\(.repro.text)" else "" end)' <<<"$f"
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    case "$n" in *.cls) lang=objectscript ;; *.mac|*.int|*.inc|*.rtn) lang=objectscript ;; *.json) lang=json ;; *.sh) lang=bash ;; *) lang="" ;; esac
    printf '\n`%s`:\n\n```%s\n%s\n```\n' "$n" "$lang" "$(cat "$FILES_DIR/$id/$n")"
  done <<<"$(jq -r '.repro.files[]?' <<<"$f")"
  jq -r --arg plat "$(uname -sm)" '"\n## Environment\n\n- \(.tool) \(.version)\n- \($plat)\n- kind: \(.kind)"' <<<"$f"
  if [[ -n "${2:-}" ]]; then
    printf '\nPossibly related:\n'
    jq -r '"- \(.url) \(.title)"' <<<"$2"
  fi
  printf '\n---\nReported with iris-legacy-kit %s.\n' "$KIT_VERSION"
}

filed_today() { ledger | jq -r --arg d "$(date -u +%Y-%m-%d)" 'select(.state == "filed" and ((.filedAt // "") | startswith($d))) | .id' | wc -l | tr -d ' '; }

cmd_file() {
  local id=${1:-} dry="" new="" f state repo title body related url max tmp a
  [[ -n "$id" ]] || usage
  shift
  for a in "$@"; do
    case "$a" in --dry-run) dry=1 ;; --new) new=1 ;; *) usage ;; esac
  done
  f=$(get "$id"); [[ -n "$f" ]] || die "no finding $id"
  state=$(jq -r .state <<<"$f")
  case "$state" in
    filed) echo "$id is filed already: $(jq -r .url <<<"$f")"; return 1 ;;
    duplicate) echo "$id duplicates $(jq -r '[.links[] | select(.rel == "duplicate") | .url] | join(", ")' <<<"$f"); not filed"; return 1 ;;
    dropped) echo "$id was dropped; not filed"; return 1 ;;
  esac
  max=$(conf '.report.maxPerDay'); max=${max:-3}
  if [[ -z "$dry" && $(filed_today) -ge $max ]]; then
    echo "report.sh: $max findings filed today already (report.maxPerDay); file $id tomorrow" >&2; return 1
  fi
  verdict "$f"
  case "$VERDICT" in
    ok) ;;
    possible)
      if [[ -z "$new" ]]; then
        echo "$id not filed: possible duplicate; read the match, then mark it or file with --new"; return 1
      fi ;;
    duplicate)
      [[ -n "$dry" ]] || put "$(jq -c --argjson m "$(jq -s -c --argjson s "$STRONG" 'map(select(.score >= $s) | {rel: "duplicate", url, title, score})' <<<"$MATCHES")" \
        '.state = "duplicate" | .links = ((.links // []) + $m | unique_by(.url))' <<<"$f")"
      echo "$id not filed: duplicate${dry:+ (dry run: ledger unchanged)}"; return 1 ;;
    blocked)
      [[ -n "$dry" ]] || put "$(jq -c --arg b "$BLOCKED" '.state = "blocked" | .blocked = ($b | split("\n") | map(split("\t") | {category: .[0], term: .[1], where: .[2]}))' <<<"$f")"
      echo "$id not filed: blocked by the sanitizer${dry:+ (dry run: ledger unchanged)}"; return 1 ;;
    *) echo "$id not filed: $VERDICT"; return 1 ;;
  esac
  repo=$(route "$(jq -r .tool <<<"$f")")
  title=$(issue_title "$f")
  related=$(jq -c --argjson p "$POSSIBLE" 'select(.score >= $p and (.url | startswith("http")))' <<<"$MATCHES")
  body=$(issue_body "$f" "$related")
  if [[ -n "$dry" ]]; then
    printf '\n== dry run: would file to %s\nTitle: %s\n\n%s\n' "$repo" "$title" "$body"
    return 0
  fi
  tmp="$TMP_DIR/issue.md"
  printf '%s\n' "$body" >"$tmp"
  if ! url=$(gh issue create -R "$repo" --title "$title" --body-file "$tmp" 2>&1); then
    echo "report.sh: gh issue create failed: $url" >&2; return 1
  fi
  url=$(grep -Eo 'https://[^[:space:]]+' <<<"$url" | tail -1)
  put "$(jq -c --arg u "$url" --arg r "$repo" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.state = "filed" | .url = $u | .repo = $r | .filedAt = $now | .links = ((.links // []) + [{rel: "filed", url: $u}])' <<<"$f")"
  echo "filed $id: $url"
}

cmd_mark() {
  local id=${1:-} what=${2:-} url=${3:-} f
  f=$(get "$id"); [[ -n "$f" ]] || die "no finding $id"
  [[ "$(jq -r .state <<<"$f")" != filed ]] || die "$id is filed already: $(jq -r .url <<<"$f")"
  case "$what" in
    duplicate) [[ "$url" == http* ]] || die "mark $id duplicate needs the URL of the issue it duplicates"
      put "$(jq -c --arg u "$url" '.state = "duplicate" | .links = ((.links // []) + [{rel: "duplicate", url: $u}] | unique_by(.url))' <<<"$f")" ;;
    dropped) put "$(jq -c '.state = "dropped"' <<<"$f")" ;;
    *) usage ;;
  esac
  echo "$id: $what${url:+ of $url}"
}

cmd_hook() {
  local n
  [[ -f "$LEDGER" ]] || exit 0
  n=$(ledger | jq -r 'select(.state == "new") | .id' 2>/dev/null | wc -l | tr -d ' ')
  [[ "$n" -gt 0 ]] && echo "iris-legacy kit: $n tool finding(s) not filed yet (.claude/kit-findings.jsonl). Use /iris-legacy:report-upstream to check and file them."
  exit 0
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  update) shift; cmd_update "$@" ;;
  list) shift; cmd_list "$@" ;;
  show) f=$(get "${2:-}"); [[ -n "$f" ]] || die "no finding ${2:-}"; jq . <<<"$f" ;;
  route) [[ -n "${2:-}" ]] || usage; known_tool "$2" || die "unknown tool '$2'"
         route "$2" || { echo "claude-code: /feedback"; exit 0; } ;;
  check) shift; cmd_check "$@" ;;
  file) shift; cmd_file "$@" ;;
  mark) shift; cmd_mark "$@" ;;
  --hook) cmd_hook ;;
  *) usage ;;
esac
