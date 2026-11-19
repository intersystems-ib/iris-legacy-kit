#!/usr/bin/env bash
# Release watch: compare the kit's pinned tools (plugins/iris-legacy/versions.json) with their
# latest releases and propose pin bumps. It reads the GitHub releases API and PyPI's JSON API and
# never downloads a tool: the new checksums are the sha256 digests GitHub publishes for every
# release asset and PyPI for every file.
#
#   tools/release-watch.sh                        report pinned vs latest for every tool
#   tools/release-watch.sh --updates              one "TOOL VERSION" line per tool with an update
#   tools/release-watch.sh --write [TOOL...]      rewrite the pins (default: every tool with an update)
#   tools/release-watch.sh --pr [--push] [TOOL...]
#       --write on a new branch (pin/<tool>-<version> for one tool, pin/<date> for several),
#       commit versions.json, print the PR title and body and go back to the starting branch.
#       Only with --push: push the branch and open the PR with gh. Nothing is pushed otherwise.
#
# Exit codes: 0 up to date (report, --updates) or done (--write, --pr); 10 updates available
# (report, --updates); 1 error. Nothing is written when a requested tool cannot be pinned (a
# platform's asset or its digest is missing): a checksum is never guessed or left empty.
#
# Which release counts: the highest version among the published releases whose tag has the same
# shape as the pinned one (v0.26.0-interop matches v0.27.0-interop, not v0.27.0); drafts and
# prereleases are skipped, and so are PyPI versions that are not plain numbers (1.12.0rc1) or
# whose files are all yanked. Each platform keeps the asset naming of its current pin, with the
# version substituted. "reports" (what the binary prints for --version) is derived the way the
# pinned entry relates it to its version; setup.sh checks it against the binary after install.
# A pin with "declarations" (ascot: the IRIS declarations from its npm package) moves them with
# the tool: the npm package of the new version, pinned by the sha512 integrity npm publishes.
#
# Environment: VERSIONS (default plugins/iris-legacy/versions.json); GITHUB_TOKEN or GH_TOKEN
# (optional, raises GitHub's rate limit; sent on curl's stdin, never on its command line);
# RELEASE_WATCH_DATE (the date in pin/<date>, default today); RELEASE_WATCH_TESTS (a file whose
# content goes into the PR body as the test results).
set -uo pipefail

KIT="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS="${VERSIONS:-$KIT/plugins/iris-legacy/versions.json}"
PLATFORMS="darwin-arm64 darwin-x86_64 linux-x86_64 linux-aarch64"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/release-watch.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

die() { echo "release-watch: $*" >&2; exit 1; }

MODE=report PUSH=0 TOOLS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --updates) MODE="updates" ;;
    --write) MODE="write" ;;
    --pr) MODE="pr" ;;
    --push) PUSH=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) TOOLS+=("$1") ;;
  esac
  shift
done
[[ $PUSH == 0 || $MODE == pr ]] || die "--push only goes with --pr"
command -v jq >/dev/null || die "jq is not installed"
command -v curl >/dev/null || die "curl is not installed"
[[ -f "$VERSIONS" ]] || die "no $VERSIONS"
VERSIONS="$(cd "$(dirname "$VERSIONS")" && pwd)/$(basename "$VERSIONS")"
for t in "${TOOLS[@]+"${TOOLS[@]}"}"; do
  jq -e --arg t "$t" 'has($t)' "$VERSIONS" >/dev/null || die "no tool '$t' in $VERSIONS"
done

get() {  # get URL OUT
  local tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "$tok" && "$1" == https://api.github.com/* ]]; then
    curl -fsSL --retry 2 -o "$2" -K - "$1" <<<"header = \"Authorization: Bearer $tok\""
  else
    curl -fsSL --retry 2 -o "$2" "$1"
  fi
}

# The highest plain version in a list of {v, ok} objects, compared number by number; null if none.
JQ_LATEST='map(select(.ok)) | sort_by(.v | split(".") | map(tonumber)) | last | .v'

# resolve TOOL: write $WORK/TOOL.json, the plan for that tool:
#   {tool, kind, current, latest, update, html_url, body, reports, has_reports,
#    assets: {platform: {name, sha256}}, errors: [...], gaps: [...], unpinned: [...]}
# The release itself is first normalized to {latest, html_url, body, files: [{name, url, sha256}]}.
resolve() {
  local t=$1
  local url cur kind rel="$WORK/$t.release.json"
  url=$(jq -r --arg t "$t" '.[$t].url' "$VERSIONS")
  cur=$(jq -r --arg t "$t" '.[$t].version' "$VERSIONS")
  if [[ "$url" =~ ^https://github\.com/([^/]+/[^/]+)/releases/download/(.*)\{version\}/ ]]; then
    kind=github
    local repo=${BASH_REMATCH[1]} prefix=${BASH_REMATCH[2]}
    get "https://api.github.com/repos/$repo/releases?per_page=50" "$WORK/$t.api.json" \
      || { echo "{\"tool\":\"$t\",\"errors\":[\"cannot read the releases of $repo\"]}" >"$WORK/$t.json"; return; }
    # Tags of the pinned tag's shape: same text around the version number.
    jq --arg tag "$prefix$cur" --arg prefix "$prefix" '
      ($tag | capture("^(?<pre>[^0-9]*)[0-9]+(\\.[0-9]+)*(?<post>.*)$")) as $shape
      | [.[] | select((.draft | not) and (.prerelease | not))
             | select(.tag_name | startswith($shape.pre) and endswith($shape.post))
             | . + {num: (.tag_name | ltrimstr($shape.pre) | .[0:(length - ($shape.post | length))])}
             | select(.num | test("^[0-9]+(\\.[0-9]+)*$"))] as $rels
      | ($rels | map({v: .num, ok: true}) | '"$JQ_LATEST"') as $num
      | ($rels | map(select(.num == $num)) | first) as $r
      | if $r == null then {latest: null}
        else {latest: ($r.tag_name | ltrimstr($prefix)), html_url: $r.html_url, body: ($r.body // ""),
              files: [$r.assets[] | {name, url: null,
                                     sha256: ((.digest // "") | if startswith("sha256:") then ltrimstr("sha256:") else "" end)}]}
        end' "$WORK/$t.api.json" >"$rel" || { echo "{\"tool\":\"$t\",\"errors\":[\"unexpected answer from the GitHub API for $repo\"]}" >"$WORK/$t.json"; return; }
  elif [[ "$url" == "{asset}" ]] && jq -e --arg t "$t" '[.[$t].assets[].name] | all(startswith("https://files.pythonhosted.org/"))' "$VERSIONS" >/dev/null; then
    kind=pypi
    local file dist
    file=$(jq -r --arg t "$t" '[.[$t].assets[].name] | first | split("/") | last' "$VERSIONS")
    dist=${file%%-"$cur"-*}
    dist=$(tr '_.' '--' <<<"$dist" | tr '[:upper:]' '[:lower:]')
    get "https://pypi.org/pypi/$dist/json" "$WORK/$t.api.json" \
      || { echo "{\"tool\":\"$t\",\"errors\":[\"cannot read PyPI project $dist\"]}" >"$WORK/$t.json"; return; }
    local latest
    latest=$(jq -r '(.releases // {}) | to_entries
                    | map({v: .key, ok: ((.key | test("^[0-9]+(\\.[0-9]+)*$")) and any(.value[]; .yanked | not))})
                    | '"$JQ_LATEST"' // empty' "$WORK/$t.api.json")
    [[ -n "$latest" ]] || latest=$(jq -r '.info.version // empty' "$WORK/$t.api.json")
    if [[ -z "$latest" ]]; then
      echo '{"latest": null}' >"$rel"
    elif [[ "$latest" == "$cur" ]]; then
      jq -n --arg v "$latest" --arg d "$dist" '{latest: $v, html_url: "https://pypi.org/project/\($d)/\($v)/", body: "", files: []}' >"$rel"
    else
      get "https://pypi.org/pypi/$dist/$latest/json" "$WORK/$t.files.json" \
        || { echo "{\"tool\":\"$t\",\"errors\":[\"cannot read PyPI release $dist $latest\"]}" >"$WORK/$t.json"; return; }
      jq --arg v "$latest" --arg d "$dist" '
        {latest: $v, html_url: "https://pypi.org/project/\($d)/\($v)/",
         body: ("No release notes on PyPI." + (if .info.project_urls.Homepage then " Project: " + .info.project_urls.Homepage else "" end)),
         files: [.urls[] | select(.yanked | not) | {name: .filename, url, sha256: (.digests.sha256 // "")}]}' \
        "$WORK/$t.files.json" >"$rel"
    fi
  else
    echo "{\"tool\":\"$t\",\"errors\":[\"no release source known for url $url\"]}" >"$WORK/$t.json"
    return
  fi

  jq --arg t "$t" --arg kind "$kind" --arg platforms "$PLATFORMS" --slurpfile rel "$rel" '
    .[$t] as $pin | $rel[0] as $r | $pin.version as $cur
    | ($r.latest // null) as $new
    | {tool: $t, kind: $kind, current: $cur, latest: $new, update: ($new != null and $new != $cur),
       html_url: $r.html_url, body: ($r.body // ""), has_reports: ($pin | has("reports"))}
    | if $new == null then . + {errors: ["no published release with a tag shaped like the pin"]} else . end
    # reports: the pinned entry says how the printed version relates to the version (text cut
    # from the front and the back); apply the same cut to the new version.
    | if .has_reports and .update then
        ($cur | index($pin.reports)) as $i
        | if $i == null then . + {errors: ((.errors // []) + ["cannot derive reports: \($pin.reports) is not part of \($cur)"])}
          else {pre: $cur[0:$i], post: $cur[($i + ($pin.reports | length)):]} as $cut
            | if ($new | startswith($cut.pre) and endswith($cut.post)) and
                 ($new | ltrimstr($cut.pre) | .[0:(length - ($cut.post | length))] | test("^[0-9]+(\\.[0-9]+)*$"))
              then . + {reports: ($new | ltrimstr($cut.pre) | .[0:(length - ($cut.post | length))])}
              else . + {errors: ((.errors // []) + ["cannot derive reports for \($new) from \($pin.reports) for \($cur)"])} end
          end
      else . end
    # Each pinned platform: the same asset name with the version substituted.
    | if .update then
        reduce ($pin.assets | to_entries[]) as $e (.;
          ($e.value.name | if $kind == "pypi" then split("/") | last else . end | split($cur) | join($new)) as $want
          | ([$r.files[] | select(.name == $want)] | first) as $f
          | if $f == null then .errors = ((.errors // []) + ["\($e.key): no asset \($want) in \($new)"])
            elif ($f.sha256 | test("^[0-9a-f]{64}$") | not) then .errors = ((.errors // []) + ["\($e.key): \($want) in \($new) has no sha256 digest"])
            else .assets[$e.key] = {name: (if $kind == "pypi" then $f.url else $f.name end), sha256: $f.sha256} end)
        # Release files no platform uses (not Windows; for PyPI wheels only): candidates for a gap.
        | .unpinned = ([$r.files[].name] - [.assets[]?.name | split("/") | last]
                       | map(select(test("windows|msvc|win_|win32|\\.exe$") | not))
                       | if $kind == "pypi" then map(select(endswith(".whl"))) else . end)
      else . end
    | .gaps = [($platforms | split(" "))[] | select(. as $p | $pin.assets | has($p) | not)]
    | .errors = (.errors // [])' "$VERSIONS" >"$WORK/$t.json" \
    || echo "{\"tool\":\"$t\",\"errors\":[\"internal error while planning $t\"]}" >"$WORK/$t.json"
  declarations "$t"
}

# declarations TOOL: for a pin with "declarations" and an update, add declarations_sha512 (hex)
# to the plan: npm's integrity for the package version, read from the registry, never downloaded.
declarations() {
  local t=$1 durl new pkg hex
  durl=$(jq -r --arg t "$t" '.[$t].declarations.url // empty' "$VERSIONS")
  [[ -n "$durl" ]] && jq -e '.update and (.errors | length == 0)' "$WORK/$t.json" >/dev/null || return 0
  new=$(jq -r .latest "$WORK/$t.json")
  if [[ "$durl" =~ ^https://registry\.npmjs\.org/(.+)/-/[^/]+$ ]]; then
    pkg=${BASH_REMATCH[1]}
    if get "https://registry.npmjs.org/$pkg/$new" "$WORK/$t.npm.json" 2>/dev/null; then
      hex=$(jq -r '.dist.integrity // "" | select(startswith("sha512-")) | ltrimstr("sha512-")' "$WORK/$t.npm.json" 2>/dev/null \
            | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n')
    fi
    if [[ "${hex:-}" =~ ^[0-9a-f]{128}$ ]]; then
      jq --arg h "$hex" --arg p "$pkg" '. + {declarations_sha512: $h, declarations_from: "npm \($p) \(.latest)"}' "$WORK/$t.json" >"$WORK/$t.d.json"
    else
      jq --arg e "declarations: no npm package $pkg $new with a sha512 integrity" '.errors += [$e]' "$WORK/$t.json" >"$WORK/$t.d.json"
    fi
  else
    jq --arg e "declarations: no release source known for url $durl" '.errors += [$e]' "$WORK/$t.json" >"$WORK/$t.d.json"
  fi
  mv "$WORK/$t.d.json" "$WORK/$t.json"
}

ALL=$(jq -r 'keys_unsorted[]' "$VERSIONS")
for t in $ALL; do resolve "$t"; done
PLAN=$(for t in $ALL; do cat "$WORK/$t.json"; done | jq -s '.')
errors=$(jq '[.[] | select(.errors | length > 0)] | length' <<<"$PLAN")
updates=$(jq -r '.[] | select(.update and (.errors | length == 0)) | "\(.tool) \(.latest)"' <<<"$PLAN")

case "$MODE" in
  report)
    printf '%-26s %-18s %-18s %s\n' tool pinned latest status
    jq -r '.[] | [.tool, (.current // "?"), (.latest // "?"),
                  (if (.errors | length) > 0 then "ERROR" elif .update then "update" else "up to date" end)] | @tsv' <<<"$PLAN" \
      | while IFS=$'\t' read -r a b c d; do printf '%-26s %-18s %-18s %s\n' "$a" "$b" "$c" "$d"; done
    jq -r '.[] | (.errors[] as $e | "  \(.tool): \($e)"),
                 (select(.update and (.reports != null)) | "  \(.tool): reports \(.reports) (derived; setup.sh checks it after install)"),
                 (select(.update and (.declarations_from != null)) | "  \(.tool): declarations from \(.declarations_from) (sha512 from its integrity)"),
                 (select(.update and (.gaps | length) > 0) | "  \(.tool): no pin for \(.gaps | join(", "))"
                    + (if (.unpinned | length) > 0 then "; release files not pinned: \(.unpinned | join(", "))" else "" end))' <<<"$PLAN"
    [[ $errors == 0 ]] || exit 1
    [[ -z "$updates" ]] && exit 0 || exit 10 ;;
  updates)
    [[ -n "$updates" ]] && echo "$updates"
    jq -r '.[] | .errors[] as $e | "release-watch: \(.tool): \($e)"' <<<"$PLAN" >&2
    [[ $errors == 0 ]] || exit 1
    [[ -z "$updates" ]] && exit 0 || exit 10 ;;
esac

# --write and --pr: the tools to bump. With no TOOL named, every tool must resolve: a tool whose
# release could not be read might have an update too, so nothing is written.
if [[ ${#TOOLS[@]} == 0 ]]; then
  TOOLS=()
  while read -r t _; do [[ -n "$t" ]] && TOOLS+=("$t"); done < <(jq -r '.[] | select(.update or (.errors | length > 0)) | .tool' <<<"$PLAN")
fi
BUMP=()
for t in "${TOOLS[@]+"${TOOLS[@]}"}"; do
  p=$(jq -c --arg t "$t" '.[] | select(.tool == $t)' <<<"$PLAN")
  if [[ $(jq '.errors | length' <<<"$p") != 0 ]]; then
    jq -r '.errors[] as $e | "release-watch: \(.tool): \($e)"' <<<"$p" >&2
    failed=1
  elif [[ $(jq '.update' <<<"$p") == true ]]; then
    BUMP+=("$t")
  else
    echo "$t: already at the latest release ($(jq -r .current <<<"$p"))"
  fi
done
[[ -z "${failed:-}" ]] || die "nothing written: a requested tool cannot be pinned (see above)"
if [[ ${#BUMP[@]} == 0 ]]; then echo "nothing to bump"; exit 0; fi

write_pins() {
  local out="$WORK/versions.new.json" t p
  cp "$VERSIONS" "$out"
  for t in "${BUMP[@]}"; do
    p=$(jq -c --arg t "$t" '.[] | select(.tool == $t)' <<<"$PLAN")
    jq --arg t "$t" --argjson p "$p" '
      .[$t].version = $p.latest
      | if $p.has_reports then .[$t].reports = $p.reports else . end
      | if $p.declarations_sha512 then .[$t].declarations.sha512 = $p.declarations_sha512 else . end
      | .[$t].assets |= with_entries(.value = $p.assets[.key])' "$out" >"$out.tmp" && mv "$out.tmp" "$out" \
      || { echo "release-watch: cannot write the pins for $t; nothing written" >&2; return 1; }
  done
  jq -e . "$out" >/dev/null || { echo "release-watch: the new versions.json does not parse; nothing written" >&2; return 1; }
  mv "$out" "$VERSIONS"
  for t in "${BUMP[@]}"; do
    jq -r --arg t "$t" '.[] | select(.tool == $t) | "pinned \(.tool) \(.current) -> \(.latest)"' <<<"$PLAN"
  done
}

if [[ $MODE == write ]]; then write_pins; exit; fi

# --pr
command -v git >/dev/null || die "git is not installed"
cd "$(dirname "$VERSIONS")" || die "cannot enter $(dirname "$VERSIONS")"
git rev-parse --git-dir >/dev/null 2>&1 || die "$VERSIONS is not in a git repository"
git diff --quiet HEAD -- "$VERSIONS" || die "$VERSIONS has uncommitted changes"
start=$(git symbolic-ref --short -q HEAD) || die "not on a branch"
if [[ ${#BUMP[@]} == 1 ]]; then
  branch="pin/${BUMP[0]}-$(jq -r --arg t "${BUMP[0]}" '.[] | select(.tool == $t) | .latest' <<<"$PLAN")"
else
  branch="pin/${RELEASE_WATCH_DATE:-$(date +%F)}"
fi
if [[ $PUSH == 1 ]] && git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  echo "$branch is already proposed (the branch exists on origin); nothing to do"
  exit 0
fi
git rev-parse -q --verify "refs/heads/$branch" >/dev/null && die "branch $branch already exists"

sel=$(printf '%s\n' "${BUMP[@]}" | jq -R . | jq -s .)
title="Pin $(jq -r --argjson s "$sel" '[.[] | select(.tool | IN($s[])) | "\(.tool) \(.latest)"] | join(", ")' <<<"$PLAN")"
body="$WORK/body.md"
{
  echo "## Pin bumps"
  echo
  echo "| Tool | Pinned | New | Release |"
  echo "| --- | --- | --- | --- |"
  jq -r --argjson s "$sel" '.[] | select(.tool | IN($s[])) | "| \(.tool) | \(.current) | \(.latest) | [\(.latest)](\(.html_url)) |"' <<<"$PLAN"
  echo
  echo "Proposed by \`tools/release-watch.sh\`. Every checksum is the sha256 digest the release"
  echo "publishes (GitHub asset digests, PyPI file digests); \`setup.sh\` verifies it on download."
  jq -r --argjson s "$sel" '.[] | select(.tool | IN($s[]))
    | (select(.reports != null) | "`reports` for \(.tool) is \(.reports), derived from the pinned entry; setup.sh checks it against `--version` after install."),
      (select(.declarations_from != null) | "The declarations for \(.tool) move with it: \(.declarations_from), pinned by the sha512 of its npm integrity."),
      (select((.gaps | length) > 0) | "\(.tool) has no pin for \(.gaps | join(", "))" + (if (.unpinned | length) > 0 then "; this release also has \(.unpinned | join(", "))." else "." end))' <<<"$PLAN"
  echo
  echo "## Test results"
  echo
  if [[ -n "${RELEASE_WATCH_TESTS:-}" && -f "$RELEASE_WATCH_TESTS" ]]; then
    echo '```'
    cat "$RELEASE_WATCH_TESTS"
    echo '```'
  else
    echo "_Not run yet._ Install the new pins once (needs network), then run the offline tests:"
    echo
    echo '```bash'
    echo 'CLAUDE_PLUGIN_DATA="$PWD/.test-data" plugins/iris-legacy/scripts/setup.sh'
    echo 'tests/smoke.sh && tests/hooks.sh'
    echo '```'
  fi
  echo
  echo "## Release notes"
  jq -r --argjson s "$sel" '.[] | select(.tool | IN($s[]))
    | (.body | gsub("\r"; "") | gsub("<!--[^>]*-->"; "") | split("\n")) as $lines
    | ($lines[0:40] | join("\n")) as $short
    | "\n### \(.tool) \(.latest)\n\n"
      + (if ($short | length) > 3000 then $short[0:3000] else $short end)
      + (if ($lines | length) > 40 or ($short | length) > 3000 then "\n\n... (trimmed; full notes: \(.html_url))" else "" end)' <<<"$PLAN"
} >"$body"

git checkout -q -b "$branch" || die "cannot create branch $branch"
write_pins >/dev/null || { git checkout -q -- "$VERSIONS"; git checkout -q "$start"; git branch -q -D "$branch"; die "branch removed"; }
git add -- "$VERSIONS" && git commit -q -m "$title" -m "$(jq -r --argjson s "$sel" '.[] | select(.tool | IN($s[])) | "- \(.tool): \(.current) -> \(.latest)"' <<<"$PLAN")" -- "$VERSIONS" \
  || { git checkout -q "$start"; git branch -q -D "$branch"; die "commit failed; branch removed"; }
echo "branch $branch: $(git log -1 --format='%h %s')"
if [[ $PUSH == 1 ]]; then
  command -v gh >/dev/null || die "--push needs gh"
  git push -q -u origin "$branch" || die "push failed; the branch is still here"
  gh pr create --base "$start" --head "$branch" --title "$title" --body-file "$body" || die "gh pr create failed"
else
  echo "not pushed. PR title:"
  echo "  $title"
  echo "PR body:"
  sed 's/^/  /' "$body"
fi
git checkout -q "$start"
