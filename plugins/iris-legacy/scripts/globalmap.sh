#!/usr/bin/env bash
# The global map: which routine labels and class methods read, set, kill or lock each global,
# from the code alone. Runs tools/globalmap/globalmap.py with the grammar setup.sh installed and
# checked, and with its one Python dependency (tree-sitter) locked by hash in globalmap.py.lock.
#
#   globalmap.sh [--summary|--json|--global NAME] [PATH...]
#
# With no PATH, it maps the source directories of the kit config, relative to the project root.
# Needs uv (https://docs.astral.sh/uv/); uv fetches tree-sitter once, checks it against the lock
# file and caches it.
set -uo pipefail
. "$(dirname "$0")/common.sh"

GM="$KIT/tools/globalmap/globalmap.py"
G=$(grammar_dir)
command -v uv >/dev/null || { echo "globalmap: uv is not installed (https://docs.astral.sh/uv/)" >&2; exit 1; }
[[ -d "$G/tree_sitter_objectscript_routine" ]] || {
  echo "globalmap: the grammar is not installed in $G; run /iris-legacy:setup" >&2; exit 1; }

# Paths are relative to the project root, like the source directories in the kit config.
paths=() opts=()
while (($#)); do
  case "$1" in
    --global) opts+=("$1" "${2:-}"); shift 2 ;;
    -*) opts+=("$1"); shift ;;
    *) paths+=("$1"); shift ;;
  esac
done
if ((${#paths[@]} == 0)); then
  while IFS= read -r d; do [[ -n "$d" ]] && paths+=("$d"); done < <(source_dirs)
fi
((${#paths[@]})) || { echo "globalmap: no PATH given and no sourceDirs in $CONF" >&2; exit 2; }

cd "$ROOT" || exit 1
PYTHONPATH="$G${PYTHONPATH:+:$PYTHONPATH}" exec uv run --quiet --no-project --locked --script "$GM" \
  ${opts[@]+"${opts[@]}"} "${paths[@]}"
