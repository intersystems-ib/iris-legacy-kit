#!/usr/bin/env bash
# Install the kit's pinned tools into the plugin's data directory, each one checked against the
# sha256 in versions.json. Nothing is installed anywhere else. Idempotent, and safe when two
# sessions start at the same time.
#
#   setup.sh           install what is missing or at another version; one line per tool
#   setup.sh --check   install nothing; one line per tool; exit 1 if a tool is missing
#   setup.sh --hook    SessionStart hook: install what is missing, print one status line, exit 0
#
# The data directory is $CLAUDE_PLUGIN_DATA. Claude Code sets it for plugin hooks; pass it
# explicitly when running this by hand or from a skill.
#
# Layout: $CLAUDE_PLUGIN_DATA/bin/{iris-interop-dev,ascot,ast-grep},
#         $CLAUDE_PLUGIN_DATA/ascot/declarations.d.json.gz (the IRIS classes and routines ascot
#         resolves against, from ascot's npm package of the pinned version),
#         $CLAUDE_PLUGIN_DATA/grammars/tree-sitter-objectscript-<version>/, downloads in dl/.
set -uo pipefail

MODE="${1:-install}"
case "$MODE" in install|--check|--hook) ;; *) echo "usage: $0 [--check|--hook]" >&2; exit 64 ;; esac
KIT="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS="$KIT/versions.json"
TOOLS="iris-interop-dev ascot ast-grep tree-sitter-objectscript"

# In hook mode a failure must not block the session: say what is wrong in one line and exit 0.
fail() {
  if [[ "$MODE" == --hook ]]; then
    echo "iris-legacy kit: tools not ready ($1). Run /iris-legacy:setup for details."
    exit 0
  fi
  echo "setup.sh: $1" >&2
  exit 1
}

[[ -n "${CLAUDE_PLUGIN_DATA:-}" ]] || fail "CLAUDE_PLUGIN_DATA is not set"
command -v jq >/dev/null || fail "jq is not installed"
command -v curl >/dev/null || fail "curl is not installed"
command -v unzip >/dev/null || fail "unzip is not installed"
DATA="$CLAUDE_PLUGIN_DATA"
BIN="$DATA/bin"
DL="$DATA/dl"
mkdir -p "$BIN" "$DL" "$DATA/grammars" "$DATA/ascot" || fail "cannot create $DATA"

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
PLATFORM="$os-$arch"

# pin TOOL FIELD: version | reports | url | sha256 for this platform ("" when there is none);
# decl_url | decl_sha512 for the declarations a tool's pin carries (ascot)
pin() {
  jq -r --arg t "$1" --arg f "$2" --arg p "$PLATFORM" '
    .[$t] as $x | ($x.assets[$p] // {}) as $a |
    if $f == "version" then $x.version
    elif $f == "reports" then ($x.reports // ($x.version | ltrimstr("v")))
    elif $f == "url" then (if $a.name then ($x.url | gsub("\\{version\\}"; $x.version) | gsub("\\{asset\\}"; $a.name)) else "" end)
    elif $f == "decl_url" then (($x.declarations.url // "") | gsub("\\{version\\}"; $x.version))
    elif $f == "decl_sha512" then ($x.declarations.sha512 // "")
    else ($a[$f] // "") end' "$VERSIONS"
}

sha_ok() {  # sha_ok SUM FILE: a 64-digit SUM is a sha256, a 128-digit one a sha512
  local a=256
  [[ ${#1} == 128 ]] && a=512
  if command -v sha${a}sum >/dev/null; then echo "$1  $2" | sha${a}sum -c - >/dev/null 2>&1
  else echo "$1  $2" | shasum -a $a -c - >/dev/null 2>&1; fi
}

fetch() {  # fetch URL SHA OUT: download unless OUT is already there with the right checksum
  [[ -f "$3" ]] && sha_ok "$2" "$3" && return 0
  curl -fsSL --retry 2 -o "$3.part" "$1" || { rm -f "$3.part"; echo "download failed: $1" >&2; return 1; }
  if ! sha_ok "$2" "$3.part"; then rm -f "$3.part"; echo "checksum mismatch: $1" >&2; return 1; fi
  mv "$3.part" "$3"
}

installed() {  # the version a tool reports, or "" when it is not installed
  case "$1" in
    tree-sitter-objectscript)
      local v; v=$(pin "$1" version)
      [[ -f "$DATA/grammars/tree-sitter-objectscript-$v/tree_sitter_objectscript_routine/_binding.abi3.so" ]] && echo "$v" ;;
    ascot)  # the binary, and the declarations of its pin
      [[ "$(cat "$DATA/ascot/declarations.sha512" 2>/dev/null)" == "$(pin ascot decl_sha512)" ]] || return 0
      "$BIN/ascot" --version 2>/dev/null | awk 'NR==1 {print $2}' ;;
    *) "$BIN/$1" --version 2>/dev/null | awk 'NR==1 {print $2}' ;;
  esac
}

# install_declarations TMPDIR: the pre-built IRIS declarations ascot reads with --iris FILE. They
# come from ascot's npm package of the pinned version, which never changes once published; the
# release asset ascot itself downloads into ~/.ascot is replaced in place when upstream rebuilds it.
install_declarations() {
  local url sha f d
  url=$(pin ascot decl_url); sha=$(pin ascot decl_sha512)
  [[ -n "$url" && -n "$sha" ]] || { echo "no ascot declarations pinned" >&2; return 1; }
  f="$DL/$(basename "$url")"
  fetch "$url" "$sha" "$f" || return 1
  mkdir -p "$1/npm" && tar xzf "$f" -C "$1/npm" package/lib || return 1
  d=$(find "$1/npm/package/lib" -maxdepth 1 -name '*.d.json.gz' | head -2)
  [[ -f "$d" ]] || { echo "not one declarations file in $(basename "$url")" >&2; return 1; }
  install -m 644 "$d" "$DATA/ascot/declarations.d.json.gz" && echo "$sha" >"$DATA/ascot/declarations.sha512"
}

install_tool() {
  local t=$1 url sha file tmp
  url=$(pin "$t" url); sha=$(pin "$t" sha256)
  [[ -n "$url" && -n "$sha" ]] || { echo "no $t release for $PLATFORM" >&2; return 1; }
  file="$DL/$(basename "$url")"
  fetch "$url" "$sha" "$file" || return 1
  tmp=$(mktemp -d "$DATA/.unpack.XXXXXX")
  case "$t" in
    iris-interop-dev) install -m 755 "$file" "$BIN/iris-interop-dev" ;;
    ascot) tar xzf "$file" -C "$tmp" && install -m 755 "$tmp/ascot" "$BIN/ascot" && install_declarations "$tmp" ;;
    ast-grep) unzip -o -q "$file" -d "$tmp" && install -m 755 "$tmp/ast-grep" "$BIN/ast-grep" ;;
    tree-sitter-objectscript)
      local dest="$DATA/grammars/tree-sitter-objectscript-$(pin "$t" version)"
      rm -rf "$dest" && mkdir -p "$dest" && unzip -o -q "$file" -d "$dest" ;;
  esac
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

# One installer at a time; a lock older than 10 minutes is left over from a killed run.
LOCK="$DATA/.setup.lock"
if [[ "$MODE" != --check ]]; then
  for _ in $(seq 1 300); do
    mkdir "$LOCK" 2>/dev/null && break
    [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]] && rmdir "$LOCK" 2>/dev/null
    sleep 1
  done
  [[ -d "$LOCK" ]] || fail "another setup is still running"
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
fi

missing="" summary=""
for t in $TOOLS; do
  want=$(pin "$t" reports)
  have=$(installed "$t")
  if [[ "$have" == "$want" ]]; then
    state="ok"
  elif [[ "$MODE" == --check ]]; then
    state="missing"
  elif install_tool "$t" && [[ "$(installed "$t")" == "$want" ]]; then
    state="installed"
  else
    state="failed"
  fi
  [[ "$state" == ok || "$state" == installed ]] || missing="$missing $t"
  summary="$summary, $t $want"
  [[ "$MODE" == --hook ]] || printf '%-10s %s %s\n' "$state" "$t" "$want"
done

if [[ -n "$missing" ]]; then
  fail "missing or failed:$missing"
fi
[[ "$MODE" == --hook ]] && echo "iris-legacy kit: tools ready in $BIN (${summary#, })."
exit 0
