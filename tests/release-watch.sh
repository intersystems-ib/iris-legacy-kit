#!/usr/bin/env bash
# Release watch tests, offline: a curl stand-in on PATH answers the GitHub and PyPI API calls from
# tests/fixtures/releases/ (captured once on 2026-11-02, cut down to the fields the script reads)
# and refuses everything else, so a tool download fails the test. The pins are a copy of the ones
# the fixtures were captured against (tests/fixtures/releases/versions.json), so the test does not
# depend on the kit's current pins and never touches them. Prints PASS/FAIL per check.
#
# The fixtures hold three new releases (iris-interop-dev v0.27.0-interop, ast-grep 0.51.1,
# tree-sitter-objectscript 1.11.0) and none for ascot (0.4.3); the declarations case adds an ascot
# release and answers npm's registry from fixtures/releases/npm (ascot 0.7.0, captured 2026-11-19).
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH="$KIT/tools/release-watch.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/iris-legacy-rw.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# The stand-in: -o FILE and -K - are what release-watch.sh passes; the URL is the last argument.
export FX="$WORK/fx" CALLS="$WORK/calls.log"
cp -R "$KIT/tests/fixtures/releases" "$FX"
mkdir -p "$WORK/bin"
cat >"$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=/dev/stdout url=
while [[ $# -gt 0 ]]; do
  case "$1" in -o) out=$2; shift ;; -K) cat >/dev/null; shift ;; http*) url=$1 ;; esac
  shift
done
echo "$url" >>"$CALLS"
url=${url%%\?*}
case "$url" in
  https://api.github.com/repos/*/releases) f="$FX/github/${url#https://api.github.com/repos/}"; f="${f%/releases}.json" ;;
  https://pypi.org/pypi/*/*/json) p=${url#https://pypi.org/pypi/}; f="$FX/pypi/${p%/json}.json" ;;
  https://pypi.org/pypi/*/json) p=${url#https://pypi.org/pypi/}; f="$FX/pypi/${p%/json}.json" ;;
  https://registry.npmjs.org/*/-/*) echo "curl stand-in: refused a package download $url" >&2; exit 7 ;;
  https://registry.npmjs.org/*) f="$FX/npm/${url#https://registry.npmjs.org/}.json" ;;
  *) echo "curl stand-in: refused $url" >&2; exit 7 ;;
esac
[[ -f "$f" ]] || { echo "curl stand-in: 404 $url" >&2; exit 22; }
cat "$f" >"$out"
EOF
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

export VERSIONS="$WORK/versions.json"
cp "$KIT/tests/fixtures/releases/versions.json" "$VERSIONS"   # the pins the fixtures were captured against
ORIG="$WORK/versions.orig.json"; cp "$VERSIONS" "$ORIG"
unset GITHUB_TOKEN GH_TOKEN

# setup.sh's own pin() reads the result, so the test checks what the installer will see.
eval "$(sed -n '/^pin() {/,/^}/p' "$KIT/plugins/iris-legacy/scripts/setup.sh")"
pin_on() { PLATFORM=$1 pin "$2" "$3"; }  # pin_on PLATFORM TOOL FIELD
v() { jq -r "$1" "$VERSIONS"; }
fx_sha() { jq -r --arg n "$2" '.[0].assets[] | select(.name == $n) | .digest | ltrimstr("sha256:")' "$FX/github/$1.json"; }

echo "== report"
"$WATCH" >"$WORK/r1" 2>&1; rc=$?
cat "$WORK/r1"
check "report exits 10 (updates available)" '[[ $rc == 10 ]]'
check "iris-interop-dev: update to v0.27.0-interop" 'grep -Eq "^iris-interop-dev +v0.26.0-interop +v0.27.0-interop +update$" "$WORK/r1"'
check "ast-grep: update to 0.51.1" 'grep -Eq "^ast-grep +0.51.0 +0.51.1 +update$" "$WORK/r1"'
check "tree-sitter-objectscript: update to 1.11.0" 'grep -Eq "^tree-sitter-objectscript +1.10.2 +1.11.0 +update$" "$WORK/r1"'
check "ascot: up to date at 0.4.3" 'grep -Eq "^ascot +0.4.3 +0.4.3 +up to date$" "$WORK/r1"'
check "derived reports shown for iris-interop-dev" 'grep -q "iris-interop-dev: reports 0.27.0" "$WORK/r1"'
check "platform gap named, with the release files that could fill it" \
  'grep -q "iris-interop-dev: no pin for linux-aarch64; release files not pinned: .*iris-interop-dev-linux-arm64-musl" "$WORK/r1"'

"$WATCH" --updates >"$WORK/u1" 2>&1; rc=$?
check "--updates lists exactly the three tools, exit 10" \
  '[[ $rc == 10 && "$(cat "$WORK/u1")" == $'"'"'iris-interop-dev v0.27.0-interop\nast-grep 0.51.1\ntree-sitter-objectscript 1.11.0'"'"' ]]'
check "only API calls, no download" '! grep -Ev "^https://(api.github.com/repos/[^/]+/[^/]+/releases|pypi.org/pypi/|registry.npmjs.org/@[^/]+/[^/]+/[0-9][^/]*$)" "$CALLS"'

echo "== write"
"$WATCH" --write >"$WORK/w1" 2>&1; rc=$?
cat "$WORK/w1"
check "--write exits 0" '[[ $rc == 0 ]]'
check "versions.json parses" 'jq -e . "$VERSIONS" >/dev/null'
check "ascot entry unchanged" '[[ "$(jq -c .ascot "$VERSIONS")" == "$(jq -c .ascot "$ORIG")" ]]'
check "iris-interop-dev: version and reports" '[[ $(v ".\"iris-interop-dev\".version") == v0.27.0-interop && $(v ".\"iris-interop-dev\".reports") == 0.27.0 ]]'
check "iris-interop-dev darwin-arm64 pin (setup.sh pin)" \
  '[[ $(pin_on darwin-arm64 iris-interop-dev url) == https://github.com/intersystems-ib/iris-interop-dev/releases/download/v0.27.0-interop/iris-interop-dev-macos-arm64
     && $(pin_on darwin-arm64 iris-interop-dev sha256) == 3ebf3043c32d67d7c2d42e907e5e2092f47d750e86e9c9c2df3391150625fcb6
     && $(pin_on darwin-arm64 iris-interop-dev reports) == 0.27.0 ]]'
check "iris-interop-dev linux-x86_64 keeps the musl asset" \
  '[[ $(pin_on linux-x86_64 iris-interop-dev sha256) == 48ed499a57c069cdf0152376d8418793256dc760a195d3aac10962e80aaa3295 ]]'
check "iris-interop-dev: no linux-aarch64 pin added" '[[ -z "$(pin_on linux-aarch64 iris-interop-dev url)" ]]'
check "ast-grep darwin-arm64 pin (setup.sh pin)" \
  '[[ $(pin_on darwin-arm64 ast-grep url) == https://github.com/ast-grep/ast-grep/releases/download/0.51.1/app-aarch64-apple-darwin.zip
     && $(pin_on darwin-arm64 ast-grep sha256) == a95772097b4d02bd9d45ed63b300c37041ae3c36632b3bf19250cc7c10187dc4
     && $(pin_on darwin-arm64 ast-grep reports) == 0.51.1 ]]'
check "ast-grep: every platform pinned to its release digest" \
  'for p in darwin-arm64 darwin-x86_64 linux-x86_64 linux-aarch64; do n=$(v ".\"ast-grep\".assets.\"$p\".name"); [[ $(v ".\"ast-grep\".assets.\"$p\".sha256") == $(fx_sha ast-grep/ast-grep "$n") ]] || exit 1; done'
check "tree-sitter-objectscript darwin-arm64 wheel (setup.sh pin)" \
  '[[ $(pin_on darwin-arm64 tree-sitter-objectscript url) == https://files.pythonhosted.org/packages/22/cc/3fd569baecab16246bde771eefe932288839434f0678d2c0d77e6dae2b17/tree_sitter_objectscript-1.11.0-cp38-abi3-macosx_11_0_arm64.whl
     && $(pin_on darwin-arm64 tree-sitter-objectscript sha256) == f44f6916b438490564f8fcac88a85453fd097974c2ba86632a55176f73672112
     && $(pin_on darwin-arm64 tree-sitter-objectscript version) == 1.11.0 ]]'
check "tree-sitter-objectscript linux-x86_64 stays manylinux, not musllinux" \
  '[[ $(pin_on linux-x86_64 tree-sitter-objectscript sha256) == c4501ae3ce752b7cca176ce3bb65b64820b6a10a57282a8def8f28763096dbc4 ]]'
check "every pinned checksum is 64 hex characters" '[[ $(jq "[.. | objects | select(has(\"sha256\")) | .sha256 | test(\"^[0-9a-f]{64}$\") | not] | any" "$VERSIONS") == false ]]'
"$WATCH" >"$WORK/r2" 2>&1; rc=$?
check "report after the write: exit 0, all up to date" '[[ $rc == 0 && $(grep -c "up to date$" "$WORK/r2") == 4 ]]'
cp "$VERSIONS" "$WORK/after1"; "$WATCH" --write >/dev/null 2>&1
check "a second --write changes nothing" 'cmp -s "$VERSIONS" "$WORK/after1"'

# The cases below each start from the original pins and a fresh copy of the fixtures.
reset() { cp "$ORIG" "$VERSIONS"; rm -rf "$FX"; cp -R "$KIT/tests/fixtures/releases" "$FX"; }
edit_fx() { jq "$2" "$FX/$1" >"$FX/$1.tmp" && mv "$FX/$1.tmp" "$FX/$1"; }

echo "== refusals"
reset
edit_fx github/intersystems-ib/iris-interop-dev.json '.[0].assets |= map(select(.name != "iris-interop-dev-macos-x64"))'
"$WATCH" --write >"$WORK/m1" 2>&1; rc=$?
check "missing platform asset: --write fails" '[[ $rc == 1 ]]'
check "missing platform asset: named with its platform" 'grep -q "iris-interop-dev: darwin-x86_64: no asset iris-interop-dev-macos-x64 in v0.27.0-interop" "$WORK/m1"'
check "missing platform asset: nothing written, not even the other tools" 'cmp -s "$VERSIONS" "$ORIG"'
"$WATCH" >/dev/null 2>&1; rc=$?
check "missing platform asset: report exits 1" '[[ $rc == 1 ]]'
"$WATCH" --write ast-grep >/dev/null 2>&1; rc=$?
check "a named tool that resolves is still written" '[[ $rc == 0 && $(v ".\"ast-grep\".version") == 0.51.1 && $(v ".\"iris-interop-dev\".version") == v0.26.0-interop ]]'

reset
edit_fx github/ast-grep/ast-grep.json '.[0].assets |= map(if .name == "app-x86_64-unknown-linux-gnu.zip" then .digest = null else . end)'
"$WATCH" --write ast-grep >"$WORK/d1" 2>&1; rc=$?
check "missing digest: --write fails, asset named" '[[ $rc == 1 ]] && grep -q "linux-x86_64: app-x86_64-unknown-linux-gnu.zip in 0.51.1 has no sha256 digest" "$WORK/d1"'
check "missing digest: nothing written" 'cmp -s "$VERSIONS" "$ORIG"'
reset
edit_fx github/ast-grep/ast-grep.json '.[0].assets |= map(if .name == "app-x86_64-unknown-linux-gnu.zip" then .digest = "sha512:abc" else . end)'
"$WATCH" --write ast-grep >/dev/null 2>&1; rc=$?
check "a digest that is not sha256: refused" '[[ $rc == 1 ]] && cmp -s "$VERSIONS" "$ORIG"'
reset
edit_fx pypi/tree-sitter-objectscript/1.11.0.json '.urls |= map(select(.filename | test("macosx_11_0_arm64") | not))'
"$WATCH" --write tree-sitter-objectscript >"$WORK/p1" 2>&1; rc=$?
check "missing wheel: --write fails, wheel named" '[[ $rc == 1 ]] && grep -q "darwin-arm64: no asset tree_sitter_objectscript-1.11.0-cp38-abi3-macosx_11_0_arm64.whl in 1.11.0" "$WORK/p1" && cmp -s "$VERSIONS" "$ORIG"'
reset
jq '."iris-interop-dev".reports = "0.26.0-dev"' "$ORIG" >"$VERSIONS"; cp "$VERSIONS" "$WORK/rp.json"
"$WATCH" --write iris-interop-dev >"$WORK/rp" 2>&1; rc=$?
check "reports that is not part of the version: flagged, nothing written" '[[ $rc == 1 ]] && grep -q "cannot derive reports: 0.26.0-dev is not part of v0.26.0-interop" "$WORK/rp" && cmp -s "$VERSIONS" "$WORK/rp.json"'
jq '."iris-interop-dev".reports = "0.26.0-interop"' "$ORIG" >"$VERSIONS"; cp "$VERSIONS" "$WORK/rp.json"
"$WATCH" --write iris-interop-dev >"$WORK/rp2" 2>&1; rc=$?
check "reports that would not be a plain version: flagged, nothing written" '[[ $rc == 1 ]] && grep -q "cannot derive reports for v0.27.0-interop" "$WORK/rp2" && cmp -s "$VERSIONS" "$WORK/rp.json"'

echo "== which release counts"
reset
edit_fx github/intersystems-ib/iris-interop-dev.json '
  [(.[0] | .tag_name = "v0.28.0-interop" | .prerelease = true | .published_at = "2026-11-03T00:00:00Z"),
   (.[0] | .tag_name = "v0.29.0-interop" | .draft = true),
   (.[0] | .tag_name = "v0.30.0"),
   (.[0] | .tag_name = "v0.31.0-interop-rc1")] + .'
edit_fx github/ast-grep/ast-grep.json '[(.[1] | .tag_name = "0.9.9" | .published_at = "2026-11-04T00:00:00Z")] + .'
edit_fx pypi/tree-sitter-objectscript.json '.releases["1.12.0rc1"] = [{filename: "x.whl", yanked: false}] | .releases["1.13.0"] = [{filename: "y.whl", yanked: true}]'
"$WATCH" --updates >"$WORK/q1" 2>&1
check "prerelease, draft and other tag shapes skipped" 'grep -qx "iris-interop-dev v0.27.0-interop" "$WORK/q1"'
check "highest version wins over the latest published (0.51.1, not 0.9.9)" 'grep -qx "ast-grep 0.51.1" "$WORK/q1"'
check "PyPI: rc and all-yanked versions skipped" 'grep -qx "tree-sitter-objectscript 1.11.0" "$WORK/q1"'

reset
rm "$FX/github/intersystems-community/ascot.json"
"$WATCH" >"$WORK/n1" 2>&1; rc=$?
check "API unreachable for one tool: exit 1, the others still reported" '[[ $rc == 1 ]] && grep -q "ascot: cannot read the releases of intersystems-community/ascot" "$WORK/n1" && grep -Eq "^ast-grep .* update$" "$WORK/n1"'
"$WATCH" --write >/dev/null 2>&1; rc=$?
check "API unreachable for one tool: --write with no tool named writes nothing" '[[ $rc == 1 ]] && cmp -s "$VERSIONS" "$ORIG"'

echo "== declarations (ascot's npm package moves with it)"
reset
jq '.ascot.declarations = {url: "https://registry.npmjs.org/@intersystems-community/ascot/-/ascot-{version}.tgz", sha512: ("1" * 128)}' "$ORIG" >"$VERSIONS"
cp "$VERSIONS" "$WORK/decl.json"
edit_fx github/intersystems-community/ascot.json '[(.[0] | .tag_name = "v0.7.0" | .assets |= map(.digest = "sha256:" + ("a" * 64)))] + .'
"$WATCH" >"$WORK/dc0" 2>&1
check "report names where the declarations come from" 'grep -q "ascot: declarations from npm @intersystems-community/ascot 0.7.0" "$WORK/dc0"'
"$WATCH" --write ascot >"$WORK/dc1" 2>&1; rc=$?
check "ascot bump: version, and the declarations sha512 from npm's integrity" \
  '[[ $rc == 0 && $(v .ascot.version) == 0.7.0 && $(v .ascot.declarations.sha512) == 3cd35d3b33a8121de87d16d583ec43d200197dca3cd674669b34a55627e90726561e1069c6ca899ae607a193224f82ef3faf29c63030fcab4db773c978f8505a ]]'
check "ascot bump: setup.sh reads the declarations of the new version" \
  '[[ $(pin_on linux-x86_64 ascot decl_url) == https://registry.npmjs.org/@intersystems-community/ascot/-/ascot-0.7.0.tgz && $(pin_on linux-x86_64 ascot decl_sha512) == $(v .ascot.declarations.sha512) ]]'
cp "$WORK/decl.json" "$VERSIONS"; rm "$FX/npm/@intersystems-community/ascot/0.7.0.json"
"$WATCH" --write ascot >"$WORK/dc2" 2>&1; rc=$?
check "no npm package for the new version yet: refused, nothing written" \
  '[[ $rc == 1 ]] && grep -q "ascot: declarations: no npm package @intersystems-community/ascot 0.7.0" "$WORK/dc2" && cmp -s "$VERSIONS" "$WORK/decl.json"'

echo "== pr"
reset
REPO="$WORK/repo"
mkdir -p "$REPO/tools" "$REPO/plugins/iris-legacy"
cp "$WATCH" "$REPO/tools/" && cp "$ORIG" "$REPO/plugins/iris-legacy/versions.json"
git -C "$REPO" init -q -b main && git -C "$REPO" add -A && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m base
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
(unset VERSIONS; "$REPO/tools/release-watch.sh" --pr ast-grep) >"$WORK/pr1" 2>&1; rc=$?
check "--pr ast-grep: exit 0, branch pin/ast-grep-0.51.1" '[[ $rc == 0 ]] && git -C "$REPO" rev-parse -q --verify pin/ast-grep-0.51.1 >/dev/null'
check "--pr: back on the starting branch, tree clean" '[[ $(git -C "$REPO" symbolic-ref --short HEAD) == main && -z $(git -C "$REPO" status --porcelain) ]]'
check "--pr: one commit, versions.json only" '[[ $(git -C "$REPO" rev-list --count main..pin/ast-grep-0.51.1) == 1 && $(git -C "$REPO" diff --name-only main pin/ast-grep-0.51.1) == plugins/iris-legacy/versions.json ]]'
check "--pr: commit title" '[[ $(git -C "$REPO" log -1 --format=%s pin/ast-grep-0.51.1) == "Pin ast-grep 0.51.1" ]]'
check "--pr: body has the table, the test placeholder and the notes" \
  'grep -q "| ast-grep | 0.51.0 | 0.51.1 |" "$WORK/pr1" && grep -q "_Not run yet._" "$WORK/pr1" && grep -q "### ast-grep 0.51.1" "$WORK/pr1"'
check "--pr: not pushed" 'grep -q "^not pushed" "$WORK/pr1"'
echo "smoke.sh: 18 passed" >"$WORK/tests.txt"
(unset VERSIONS; RELEASE_WATCH_DATE=2026-11-02 RELEASE_WATCH_TESTS="$WORK/tests.txt" "$REPO/tools/release-watch.sh" --pr) >"$WORK/pr2" 2>&1; rc=$?
check "--pr with no tool: one branch pin/2026-11-02 for the three" \
  '[[ $rc == 0 ]] && [[ $(git -C "$REPO" log -1 --format=%s pin/2026-11-02) == "Pin iris-interop-dev v0.27.0-interop, ast-grep 0.51.1, tree-sitter-objectscript 1.11.0" ]]'
check "--pr: test results from RELEASE_WATCH_TESTS" 'grep -q "smoke.sh: 18 passed" "$WORK/pr2" && ! grep -q "_Not run yet._" "$WORK/pr2"'
(unset VERSIONS; "$REPO/tools/release-watch.sh" --pr ast-grep) >"$WORK/pr3" 2>&1; rc=$?
check "--pr: an existing branch is refused" '[[ $rc == 1 ]] && grep -q "branch pin/ast-grep-0.51.1 already exists" "$WORK/pr3"'
echo '{}' >"$REPO/plugins/iris-legacy/versions.json"
(unset VERSIONS; "$REPO/tools/release-watch.sh" --pr iris-interop-dev) >"$WORK/pr4" 2>&1; rc=$?
check "--pr: uncommitted versions.json refused" '[[ $rc == 1 ]]'
git -C "$REPO" checkout -q -- plugins/iris-legacy/versions.json
"$WATCH" --write --push >/dev/null 2>&1; rc=$?
check "--push without --pr refused" '[[ $rc == 1 ]] && cmp -s "$VERSIONS" "$ORIG"'
check "no download in any case" '! grep -Ev "^https://(api.github.com/repos/[^/]+/[^/]+/releases|pypi.org/pypi/|registry.npmjs.org/@[^/]+/[^/]+/[0-9][^/]*$)" "$CALLS"'

echo "TESTS: $fails failed"
exit $((fails > 0))
