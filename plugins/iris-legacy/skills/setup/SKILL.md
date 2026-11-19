---
name: setup
description: Install or check the iris-legacy kit's pinned tools (iris-interop-dev, ascot, ast-grep, the tree-sitter-objectscript grammars). Use when the session-start message says the tools are not ready, when a kit hook or script reports a missing tool, or when asked to check the kit's installation.
---

# Kit tools: install and check

The kit installs its tools into the plugin data directory, `${CLAUDE_PLUGIN_DATA}`, and nowhere
else. Every download is checked against the checksum pinned in `${CLAUDE_PLUGIN_ROOT}/versions.json`
(sha256, or the sha512 npm publishes for ascot's IRIS declarations, which come from its npm
package).
A session-start hook does this automatically; use this skill when it reported a problem.

1. Check what is installed (installs nothing):

   ```bash
   CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" --check
   ```

2. Install what is missing (needs network to GitHub, PyPI and the npm registry):

   ```bash
   CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh"
   ```

3. Report each tool's line (`ok`, `installed`, `missing` or `failed`) to the user. On a failure,
   show the message and stop: a checksum mismatch means the download is not the pinned release,
   so never work around it by downloading another version or skipping the check.

Requirements: `jq`, `curl` and `unzip` on the machine. There is no iris-interop-dev release for
Linux arm64 yet; on that platform the user has to provide the binary.
