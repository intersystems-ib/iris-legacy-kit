# Shared by the kit's hooks and scripts (sourced, not run): where the project, its kit config and
# the pinned tools are.
#
#   ROOT   the project root: $CLAUDE_PROJECT_DIR, else the current directory (symlinks resolved)
#   CONF   the project's kit config, .claude/iris-legacy.json; a project without it is not a
#          kit project, and the hooks leave it alone
#   KIT    the plugin root (this script's parent directory)
#   BIN    the tools installed by setup.sh, under $CLAUDE_PLUGIN_DATA
#
# Kit config, written by bootstrap.sh write (all keys optional except sourceDirs):
#   {
#     "sourceDirs": ["src"],                                  ObjectScript the hooks upload and lint
#     "environment": "docker" | "existing",                   where IRIS runs (bootstrap step 3)
#     "tests": {"package": "App.Test"},                       the project's %UnitTest package
#     "errors": {"trap": "ERR^APPUTL", "log": "^ERRORS"},     the error trap the code uses, its log
#     "container": "app-iris",                                docker: the IRIS container
#     "publish": [{"dir": "ui", "command": "scripts/ui.sh"}], run after an edit under dir
#     "lint": {"ascot": true, "smells": true, "ascotCodes": ["A6851", ...],
#              "ascotIris": ["decl/app.d.json"]},                   declarations asked first
#     "toolset": "routines"                                   the MCP server's profile (mcp.sh)
#   }
ROOT="$(cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null && pwd -P)"
CONF="$ROOT/.claude/iris-legacy.json"
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN="${CLAUDE_PLUGIN_DATA:-/nonexistent}/bin"

# conf JQ_FILTER: read the kit config; empty output when the key or the file is missing
conf() { [[ -f "$CONF" ]] && jq -r "$1 // empty" "$CONF" 2>/dev/null; }

# source_dirs: the configured source directories, one per line, relative to ROOT
source_dirs() { conf '.sourceDirs[]?'; }

# in_dirs DIR LIST: 0 when DIR (absolute, resolved) is inside one of LIST (relative to ROOT)
in_dirs() {
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    case "$1/" in "$ROOT/${d%/}/"*) return 0 ;; esac
  done <<<"$2"
  return 1
}

# grammar_dir: where setup.sh unpacked the pinned tree-sitter-objectscript wheel
grammar_dir() {
  echo "${CLAUDE_PLUGIN_DATA:-/nonexistent}/grammars/tree-sitter-objectscript-$(jq -r '."tree-sitter-objectscript".version' "$KIT/versions.json")"
}

# sg_config: write the ast-grep project config for the kit's rules and grammars, print its path.
# Written on every call because the plugin root moves when the plugin updates.
sg_config() {
  local g cfg dir
  g=$(grammar_dir)
  dir="${CLAUDE_PLUGIN_DATA:?}/ast-grep"
  mkdir -p "$dir"
  cfg="$dir/sgconfig.yml"
  cat >"$cfg.$$" <<EOF
ruleDirs:
  - $KIT/lint/ast-grep/rules
testConfigs:
  - testDir: $KIT/lint/ast-grep/rule-tests
customLanguages:
  cosroutine:
    libraryPath: $g/tree_sitter_objectscript_routine/_binding.abi3.so
    languageSymbol: tree_sitter_objectscript_routine
    extensions: [mac, int, inc, rtn]
    expandoChar: "%"
  cosudl:
    libraryPath: $g/tree_sitter_objectscript_udl/_binding.abi3.so
    languageSymbol: tree_sitter_objectscript_udl
    extensions: [cls]
    expandoChar: "%"
EOF
  mv "$cfg.$$" "$cfg"
  echo "$cfg"
}
