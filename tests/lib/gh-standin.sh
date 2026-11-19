#!/usr/bin/env bash
# gh stand-in for tests/report.sh: serves issue and pull request searches from the captured
# fixtures in $GH_FIXTURES (<owner>__<repo>.issues.json / .prs.json), with GitHub's AND of the
# query words over title and body, and records every call in $GH_LOG. `issue create` posts
# nothing: it appends {repo, title, body} to $GH_LOG.creates and prints a made-up URL.
# GH_STANDIN_FAIL=1 makes every search fail, as GitHub does when it is unreachable.
set -uo pipefail
echo "$*" >>"$GH_LOG.calls"
kind=${1:-}; verb=${2:-}
shift 2 2>/dev/null || true
repo="" search="" title="" body_file="" limit=30
while [[ $# -gt 0 ]]; do
  case "$1" in
    -R|--repo) repo=$2; shift 2 ;;
    --search) search=$2; shift 2 ;;
    --title) title=$2; shift 2 ;;
    --body-file) body_file=$2; shift 2 ;;
    --limit) limit=$2; shift 2 ;;
    --state|--json|--jq|--label) shift 2 ;;
    *) shift ;;
  esac
done
case "$kind $verb" in
  "auth status") exit 0 ;;
  "issue list"|"pr list")
    [[ -z "${GH_STANDIN_FAIL:-}" ]] || { echo "HTTP 503: Service Unavailable (gh stand-in)" >&2; exit 1; }
    f="$GH_FIXTURES/${repo/\//__}.${kind}s.json"
    [[ -f "$f" ]] || { echo '[]'; exit 0; }
    jq -c --arg q "$search" --argjson n "$limit" '
      ($q | ascii_downcase | split(" ") | map(select(length > 0 and (test(":") | not)))) as $w
      | [.[] | select(((.title + " " + (.body // "")) | ascii_downcase) as $t | all($w[]; . as $x | $t | contains($x)))] | .[0:$n]' "$f" ;;
  "issue create")
    jq -n -c --arg r "$repo" --arg t "$title" --rawfile b "$body_file" '{repo: $r, title: $t, body: $b}' >>"$GH_LOG.creates"
    n=$(( $(wc -l <"$GH_LOG.creates") + 9000 ))
    echo "https://github.com/$repo/issues/$n" ;;
  *) echo "gh stand-in: unsupported call: $kind $verb" >&2; exit 1 ;;
esac
