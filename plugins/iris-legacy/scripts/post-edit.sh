#!/usr/bin/env bash
# Claude Code PostToolUse hook (Write|Edit|MultiEdit): put what was just edited live, and tell the
# agent. Acts only in a kit project (one with .claude/iris-legacy.json).
#
#   ObjectScript file in a source dir      upload and compile it in IRIS through
#                                          `iris-interop-dev hook post-edit`:
#     compile errors, or no answer from IRIS   exit 2, message on stderr (the channel the model reads)
#     clean compile                            exit 0, one line of JSON additionalContext
#   file in a publish dir                  run that dir's publish command
#   ObjectScript file outside the source dirs  exit 0, a note that it was not uploaded
#   anything else, or not a kit project    exit 0, silent
#
# The connection and namespace come from the project's .iris-agentic-dev.toml, the file the MCP
# server reads, so the hook and the agent's tools talk to the same instance and namespace.
set -uo pipefail
source "$(dirname "$0")/common.sh"

note() { jq -nc --arg m "$1" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'; }

payload=$(cat)
[[ -f "$CONF" ]] || exit 0
file=$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null)
[[ -n "$file" ]] || exit 0
dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd -P) || exit 0

# Publish dirs: run the configured command from the project root.
n=$(conf '.publish | length')
for ((i = 0; i < ${n:-0}; i++)); do
  pdir=$(conf ".publish[$i].dir")
  cmd=$(conf ".publish[$i].command")
  [[ -n "$pdir" && -n "$cmd" ]] || continue
  if in_dirs "$dir" "$pdir"; then
    if out=$(cd "$ROOT" && bash -c "$cmd" 2>&1); then note "${out:-$pdir published}"; exit 0; fi
    echo "Edit under $pdir/ NOT published ($cmd): $out" >&2
    exit 2
  fi
done

case "$file" in
  *.cls|*.mac|*.int|*.inc) ;;
  *) exit 0 ;;
esac
# Only the configured source dirs are loaded into IRIS: a scratch file or another checkout's file
# must not reach the namespace (iris-interop-dev uploads whatever path it is given).
if ! in_dirs "$dir" "$(source_dirs)"; then
  note "$file is outside this project's source dirs ($(source_dirs | paste -sd, -)), so it was NOT uploaded or compiled."
  exit 0
fi

IID="$BIN/iris-interop-dev"
if [[ ! -x "$IID" ]]; then
  echo "$file was NOT compile-checked: the kit's tools are not installed. Run /iris-legacy:setup." >&2
  exit 2
fi
if [[ ! -f "$ROOT/.iris-agentic-dev.toml" ]]; then
  echo "$file was NOT compile-checked: no .iris-agentic-dev.toml in $ROOT says which IRIS to use." >&2
  exit 2
fi
cd "$ROOT" && exec "$IID" hook post-edit <<<"$payload"
