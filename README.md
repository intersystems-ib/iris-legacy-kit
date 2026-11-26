# iris-legacy-kit

A Claude Code plugin, and its marketplace, for legacy InterSystems IRIS code: routines, globals
and the class layers built on them. It packages what a demo on a synthetic 1998-style
order-management system (OMS) proved: pinned tools, legacy-routine skills, a compile-and-lint edit
loop, and a way to report tool defects upstream.

What it gives a Claude Code session in an IRIS code repository:

- **An edit loop.** Every edit of a `.mac`, `.int`, `.inc` or `.cls` file in the source dirs is
  uploaded and compiled in a development namespace, and compile errors come straight back to
  Claude. A second hook runs [ascot](https://github.com/intersystems-community/ascot) over the
  source dirs (callers broken anywhere by the edit, missing labels and routines, wrong argument
  counts) and reports the legacy smells the edit added (naked global references, `LOCK` without
  a timeout, `GOTO LABEL+n`, `QUIT` inside an open transaction, `$ZU`).
- **An MCP server**, [iris-interop-dev](https://github.com/intersystems-ib/iris-interop-dev) with
  its `routines` profile unless the project picks another: run ObjectScript, read documents and
  globals, run unit tests. One IRIS server per project: see [below](#one-iris-server-per-project).
- **Skills** for routine and global idioms, a bootstrap that sets a repository up, a global map
  (which labels read, set, kill or lock each global), characterization tests before a change,
  on-demand lint, and reporting tool defects upstream.
- **Pinned tools**, installed into the plugin's data directory on the first session and checked
  against the checksums in `versions.json`, with a weekly release watch that proposes pin bumps.

See [DESIGN.md](DESIGN.md) for how it is put together.

## Install

```bash
claude plugin marketplace add intersystems-ib/iris-legacy-kit
claude plugin install iris-legacy@iris-legacy-kit --scope project
```

`--scope project` records both in the project's `.claude/settings.json`, so teammates who open
the repo get the same plugin. At the first session start, a hook installs the pinned tools into
the plugin's data directory (`~/.claude/plugins/data/<plugin id>/`), each checked against the
sha256 in `plugins/iris-legacy/versions.json`. `/iris-legacy:setup` checks or repeats that.

Requirements: `jq`, `curl`, `unzip`; [`uv`](https://docs.astral.sh/uv/) for the global map;
network access to GitHub, PyPI and the npm registry for the first install.

Then, in the project, ask Claude to bootstrap it (`/iris-legacy:bootstrap`): it finds the code,
converts headerless or exported routines, asks whether IRIS runs in Docker (it generates the
stack) or on an existing development instance, writes the files below plus `CLAUDE.md` and the
project settings, proves the compile-on-edit loop and records a baseline. It commits nothing.

## Project files

The hooks and the MCP server act only in a project that has both of these (the bootstrap writes
them):

`.iris-agentic-dev.toml`, the IRIS the MCP server and the compile hook use:

```toml
host = "localhost"
web_port = 46080          # the Web Gateway's port: Atelier REST, not the superserver
namespace = "APP"         # a development namespace, never production
username = "_SYSTEM"
password = "SYS"          # Docker dev stack only. For an existing instance the bootstrap writes no
                          # credentials: each developer sets IRIS_USERNAME and IRIS_PASSWORD in
                          # .claude/settings.local.json (gitignored)
```

`.claude/iris-legacy.json`, the kit config:

```json
{
  "sourceDirs": ["src"],
  "environment": "docker",
  "tests": { "package": "App.Test" },
  "errors": { "trap": "ERR^APPUTL", "log": "^ERRORS" },
  "publish": [{ "dir": "ui", "command": "scripts/ui.sh" }],
  "lint": { "ascot": true, "smells": true },
  "toolset": "routines"
}
```

- `sourceDirs`: ObjectScript under these is uploaded, compiled and linted after each edit.
  Anything elsewhere is never sent to IRIS.
- `publish` (optional): a command run from the project root after an edit under `dir`.
- `lint` (optional): switch either check off, replace the ascot code list with `ascotCodes`, or
  list declarations files for ascot to ask before the kit's with `ascotIris` (for classes IRIS
  Community's `%SYS` lacks, such as `Ens.*` and `HS.*`; make one with `ascot declare`).
- `report` (optional): `denyTerms` the sanitizer always refuses (the customer's name), `maxPerDay`
  (default 3). Findings go to this repo's issues, sanitized and checked for duplicates first,
  unless `IRIS_LEGACY_REPORT_TO=upstream` is set (the kit owner's environment only, where
  `IRIS_LEGACY_FINDINGS` points at the owner's findings ledger).
- `toolset` (optional, default `routines`): the MCP server's profile, any one the pinned
  iris-interop-dev has (`routines`, `interop`, ...). An `IRIS_TOOLSET` in the environment does
  not change it. A name the binary does not have stops the server, which then lists the ones it
  has (in `/mcp`, the server shows as failed). Restart Claude Code after changing it.

## One IRIS server per project

The kit starts the project's IRIS MCP server. A second IRIS server in the same session shows
Claude the same tools twice (`iris_doc`, `iris_compile`, `iris_execute`, ...) under two names,
usually connected to the same namespace, and the permission rules cover only one of them. A server
registered at user scope (`claude mcp add --scope user`) starts in every project on the machine,
this one included.

- The bootstrap writes `mcp__iris-interop-dev` and `mcp__iris-agentic-dev` into
  `permissions.deny` in `.claude/settings.json`. These are the server names the iris-interop-dev
  and iris-agentic-dev READMEs use. A deny rule without a tool name hides all of that server's
  tools in this project. It reaches everyone who opens the project, which disabling the server in
  `/mcp` does not: that only covers one machine. The server process itself still starts.
- If it finds an IRIS server under another name (in `.mcp.json`, or at user or local scope), the
  bootstrap names it and the deny rule to add.
- Better still, keep IRIS servers out of user scope altogether and register them per project:
  `claude mcp remove iris-interop-dev -s user`.

### Projects that also have productions

The [iris-interop-skills](https://github.com/intersystems-ib/iris-interop-skills) plugin is not
tied to one server: its skills, agents and hooks name tools, never a server. In a project with both
legacy code and productions, it can therefore run on the kit's server, provided that server also
serves the interop tools: `"toolset": "interop,routines"`. That needs an iris-interop-dev that
serves combined profiles
([iris-interop-dev#579](https://github.com/intersystems-ib/iris-interop-dev/issues/579)). Until
the kit pins one, such a project cannot run on a single server. Install iris-interop-skills with
`--scope project` too, so that its hooks stay out of projects that do not use it.

## What it contains

| Path | What |
| --- | --- |
| `.claude-plugin/marketplace.json` | The marketplace: one plugin, `iris-legacy` |
| `plugins/iris-legacy/.claude-plugin/plugin.json` | Plugin manifest |
| `plugins/iris-legacy/versions.json` | The only place versions and checksums are pinned: iris-interop-dev, ascot (with the IRIS declarations from its npm package), ast-grep, tree-sitter-objectscript |
| `plugins/iris-legacy/hooks/hooks.json` | SessionStart: install the tools. PostToolUse on edits: compile hook, then lint hook |
| `plugins/iris-legacy/.mcp.json` | MCP server `iris`: the pinned iris-interop-dev, started in the project root with the project's profile (`toolset`, default `routines`) |
| `plugins/iris-legacy/scripts/setup.sh` | Installs and checks the pinned tools (`--check`, `--hook`) |
| `plugins/iris-legacy/scripts/post-edit.sh` | Compile hook: upload and compile edits in the source dirs; compile errors back to Claude |
| `plugins/iris-legacy/scripts/lint.sh` | Lint hook and on-demand checks: filtered ascot, plus legacy smells an edit adds; `--sarif` for CI |
| `plugins/iris-legacy/scripts/report.sh` | The auto-improve loop: findings ledger, dedupe, sanitizer, filing with gh |
| `plugins/iris-legacy/scripts/bootstrap.sh` | The bootstrap's steps: `detect`, `convert`, `write`, `prove`, `baseline` |
| `plugins/iris-legacy/scripts/globalmap.sh`, `tools/globalmap/` | The global map (tree-sitter), with the pinned grammar and a hash-locked `tree-sitter` |
| `plugins/iris-legacy/scripts/mcp.sh`, `common.sh` | MCP entry point; shared project and config lookup |
| `plugins/iris-legacy/templates/` | What the bootstrap writes: the `CLAUDE.md` block, permissions, `.gitignore` lines, the Docker stack and its scripts |
| `plugins/iris-legacy/lint/ast-grep/` | The legacy-smell rules and their tests |
| `plugins/iris-legacy/skills/` | `bootstrap`, `legacy-routines-globals` (idioms), `map-globals`, `characterize` (with `Template.cls`), `report-upstream`, `lint`, `setup` |
| `tools/release-watch.sh`, `.github/workflows/release-watch.yml` | The release watch (below) |
| `tests/` | The test suites below; the OMS fixture `hooks.sh` edits; captured GitHub, PyPI and npm answers |

## Tests

The tests never download anything. Fetch the pinned tools once into `.test-data/` (gitignored)
and keep them:

```bash
CLAUDE_PLUGIN_DATA="$PWD/.test-data" plugins/iris-legacy/scripts/setup.sh    # once, needs network
```

```bash
tests/smoke.sh     # manifests validate; a fresh install from the kept downloads; a re-run changes
                   # nothing; a wrong checksum is refused. A curl stand-in blocks any network fetch
tests/install.sh   # marketplace add and install at project scope in a throwaway project; user settings untouched
tests/hooks.sh     # 45 checks: the scripted agent mistakes from the OMS evaluation, SARIF output,
                   # ascot never downloading, hook routing, the MCP server's tool list and the
                   # profile it takes from the kit config, the smell rules; the 2 live compile
                   # checks run only when the OMS stack answers
tests/bootstrap.sh # 68 checks: detect, convert, write in both modes, other IRIS servers named,
                   # refusals, idempotence, baseline; prove against the OMS stack when it answers
tests/skills.sh    # the global map against golden output; the characterize template in IRIS
tests/report.sh    # 57 checks, offline: this month's real findings replay as duplicates; new ones
                   # file once, to the right repo per mode; customer names are blocked
tests/release-watch.sh  # offline: the release watch against captured GitHub, PyPI and npm
                        # answers; no download, kit pins untouched
```

The live checks need a development IRIS with the OMS fixture loaded in namespace `OMS`, its Web
Gateway on `localhost:46080`; they create throwaway `ZZ*` probes and delete them, and are skipped
when nothing answers there.

`hooks.sh` checks that ascot reads only the pinned declarations: it runs with an empty `HOME` and
fails if ascot created `~/.ascot`.

## Release watch

`tools/release-watch.sh` compares each pin with the tool's latest release (GitHub releases API;
PyPI for the grammar) and never downloads a tool: new checksums are the sha256 digests the
release publishes, and for ascot's declarations the sha512 integrity of its npm package of the
same version, which moves with the ascot pin. `--updates` lists them, `--write [TOOL...]` rewrites the pins (all or nothing;
never a guessed or empty checksum), and `--pr [TOOL...]` makes `pin/<tool>-<version>` or
`pin/<date>` with one commit and prints the PR title and body; only `--push` pushes and opens it.
The weekly workflow `.github/workflows/release-watch.yml` does that per tool, with the new pin
installed and tested on the runner. It needs Actions enabled on the repo and, under Settings >
Actions > General > Workflow permissions, "Allow GitHub Actions to create and approve pull
requests".

## Licence

MIT, see [LICENSE](LICENSE). The tools the kit installs keep their own licences.
