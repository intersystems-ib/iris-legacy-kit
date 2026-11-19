#!/usr/bin/env bash
# MCP server entry point (the plugin's .mcp.json): the kit's pinned iris-interop-dev with the
# routines profile, started in the project root so that it reads the project's
# .iris-agentic-dev.toml. That file wins over IRIS_* variables, so a server configured elsewhere
# for another stack cannot reach the wrong instance from here.
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
cd "$dir" && IRIS_TOOLSET="${IRIS_TOOLSET:-routines}" exec "$IID" mcp
