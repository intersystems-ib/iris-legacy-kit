#!/usr/bin/env bash
# MCP server entry point (the plugin's .mcp.json): the kit's pinned iris-interop-dev, started in
# the project root so that it reads the project's .iris-agentic-dev.toml. That file wins over
# IRIS_* variables, so a server configured elsewhere for another stack cannot reach the wrong
# instance from here.
#
# The tool profile is the project's: "toolset" in .claude/iris-legacy.json, `routines` when it is
# not set. An IRIS_TOOLSET inherited from the environment is ignored, for the same reason the
# connection comes from the file: a variable meant for another server must not change this one.
# A profile the pinned binary does not have stops the server with its own message naming the
# ones it has.
#
#   mcp.sh PROJECT_DIR    (Claude Code passes ${CLAUDE_PROJECT_DIR}; falls back to the cwd)
dir="${1:-}"
[[ -d "$dir" ]] || dir="$PWD"
IID="${CLAUDE_PLUGIN_DATA:-/nonexistent}/bin/iris-interop-dev"
if [[ ! -x "$IID" ]]; then
  echo "iris-legacy: iris-interop-dev is not installed; run /iris-legacy:setup" >&2
  exit 1
fi
if [[ ! -f "$dir/.iris-agentic-dev.toml" ]]; then
  echo "iris-legacy: $dir has no .iris-agentic-dev.toml, so there is no IRIS to connect to" >&2
  exit 1
fi
toolset=$(jq -r '.toolset // empty' "$dir/.claude/iris-legacy.json" 2>/dev/null)
cd "$dir" && IRIS_TOOLSET="${toolset:-routines}" exec "$IID" mcp
