# Design

The kit turns an IRIS code repository with legacy routines and globals into a setup where Claude
Code checks its own work: every edit is compiled in a development namespace and statically
checked, the agent can run code and read globals through an MCP server, and skills carry the
idioms of routine-and-global code. It packages what a demo on a synthetic legacy application (OMS,
an order-management system in 1998-style ObjectScript) proved, and it keeps improving that setup
by reporting tool defects upstream and watching for new tool releases.

## 1. Shape: one repo, a Claude Code plugin plus its marketplace

```
iris-legacy-kit/
  .claude-plugin/marketplace.json        the marketplace (one plugin, versioned)
  plugins/iris-legacy/
    .claude-plugin/plugin.json           name, version, author, repository
    .mcp.json                            MCP server `iris`: iris-interop-dev, routines profile
    hooks/hooks.json                     SessionStart: install the tools, unfiled findings
                                         PostToolUse on edits: compile, then lint
    skills/
      bootstrap/                         /iris-legacy:bootstrap, sets a repository up
      legacy-routines-globals/           the idioms: naked references, $ORDER/$DATA, LOCK, ...
      map-globals/                       global map + live sampling -> a project globals skill
      characterize/                      characterization tests before a change (Template.cls)
      lint/                              the static checks on demand
      report-upstream/                   the auto-improve loop (section 5)
      setup/                             install or check the pinned tools
    scripts/                             setup, post-edit, lint, report, bootstrap, globalmap, mcp
    lint/ast-grep/                       legacy-smell rules and their tests
    tools/globalmap/                     globalmap.py (tree-sitter), hash-locked dependencies
    templates/                           CLAUDE.md block, permissions, .gitignore lines, Docker stack
    versions.json                        the only place versions and checksums are pinned
  tools/release-watch.sh                 pinned vs latest; pin-bump branches and PRs
  tests/                                 offline test suites and their fixtures
```

## 2. What goes where

| Piece | In the plugin | Written into the project |
| --- | --- | --- |
| Legacy idioms skill | yes | no |
| `CLAUDE.md` | template | yes, filled by the bootstrap |
| Compile hook | yes, reads the project's connection file through `CLAUDE_PROJECT_DIR` | no |
| Lint hook (ascot filter + new smells only) | yes, filter overridable in the kit config | baseline only |
| MCP server (iris-interop-dev, `routines`) | yes | connection file `.iris-agentic-dev.toml` |
| Binaries (iris-interop-dev, ascot and its IRIS declarations, ast-grep, grammars) | installed by a SessionStart hook into `${CLAUDE_PLUGIN_DATA}`, checksums from `versions.json` | no |
| Global map, smell rules | yes | no |
| Permissions (allow tests and read-only, deny production hosts) | template | yes, `.claude/settings.json` |
| Marketplace + plugin enablement for teammates | no | yes, `extraKnownMarketplaces` + `enabledPlugins` in `.claude/settings.json` |
| Project globals skill | the recipe (`map-globals`) | generated per project |
| Docker stack | template | when the project picks Docker |
| Test runner | yes | test package name in the kit config |

Kit config: one small file in the project, `.claude/iris-legacy.json`: source directories,
environment (docker or existing), test package, error trap label (`ERR^APPUTL` style) and log
global, the IRIS container (docker), publish steps, lint switches, codes and declarations. The
namespace lives in the connection file only.

## 3. Bootstrap (`/iris-legacy:bootstrap`)

1. **Find the code:** `.mac/.int/.inc/.cls` with headers; offer conversion for headerless
   `.rtn`/`.m`, `%RO` and Studio XML exports. Refuse to go on without a git repo.
2. **Ask the environment:** Docker (licensed or Community, plus Web Gateway, load and reset
   scripts) or an existing development instance (host, web port, namespace; the password from an
   environment variable, never committed). Refuse a namespace that looks like production.
3. **Write** the connection file, the kit config, `CLAUDE.md` from the template (with what it
   detected: error trap and log global, `U="^"` style conventions, test package),
   `.claude/settings.json` (permissions, marketplace, plugin enabled), `.gitignore` lines.
4. **Prove the loop:** install the tools, check Atelier REST, compile one document, make a
   deliberate compile error in a scratch routine and confirm the hook's message reaches Claude,
   then delete the probe.
5. **Baseline:** global map summary and lint baseline (counts of smells and filtered ascot hits).
6. **Show the diff;** commit nothing.

## 4. Static checks

**ascot** checks the whole of the source dirs after every edit, so a caller broken in another
file shows up. It resolves IRIS's own classes, routines and include files from pre-built
declarations (IRIS Community, `%SYS`) that the kit pins with ascot: they come from ascot's npm
package of the same version, which never changes once published, checked against npm's sha512.
ascot is always given them with `--iris FILE`, so it never downloads anything at edit time.
Projects whose code uses classes `%SYS` lacks (`Ens.*`, `HS.*`) can put a declarations file of
their own first (`lint.ascotIris`, made with `ascot declare`).

Only the codes that were accurate on legacy code and silent on the unchanged OMS tree are
reported (ascot's own `-d` filter): syntax errors, missing labels, routines, classes, members, macros and
include files, unknown functions and special variables, too many arguments, `GOTO` out of a
procedure block, undefined values. A call to a `%` routine is not reported: site routines such as
`^%ZSTART` live on the instance, not in the declarations. `lint.sh --sarif` writes the same
diagnostics as SARIF 2.1.0 for code scanning.

**Legacy smells** (ast-grep rules on the tree-sitter-objectscript grammar) are legal code that is
risky to change. The hook reports only the ones an edit **adds** to a routine, compared with its
committed version; `/iris-legacy:lint` lists them all before a refactor.

## 5. Auto-improve: findings filed upstream

**Capture.** When Claude meets a tool defect (a false positive, a tool that returns wrong data, a
hook that misbehaves), the `report-upstream` skill appends a finding to a local ledger
(`.claude/kit-findings.jsonl`, gitignored): tool, version, symptom, the evidence.

**Process** (on `/iris-legacy:report-upstream`, or at the end of a session):

1. **Route** by tool: iris-interop-dev -> `intersystems-ib/iris-interop-dev`; ascot ->
   `intersystems-community/ascot`; grammar -> `intersystems/tree-sitter-objectscript`; the kit
   itself -> this repo; Claude Code -> `/feedback`.
2. **Repro:** a minimal synthetic file, never project code.
3. **Dedupe:** search open and closed issues and PRs. A score of 0.55 or more is a duplicate; 0.40
   to 0.55 is held until Claude reads the match (`report.sh mark ID duplicate URL`, or
   `file ID --new`); a failed search blocks filing; a title the sanitizer blocks is never sent
   to GitHub search.
4. **Sanitize:** block the post if the body contains anything from the project: names of
   routines, classes and globals found in the source dirs, deny terms, host names, addresses,
   user paths.
5. **File** with `gh issue create`, record the URL in the ledger, at most a few per day, each
   marked "Reported with iris-legacy-kit".

**Whose account posts:** at a customer site, `gh` is logged in as the customer's developer, so the
kit files there only to this repo, sanitized and deduplicated, with the tool named in the title;
the kit owner takes what is confirmed upstream (`IRIS_LEGACY_REPORT_TO=upstream`).

**Release watch:** a weekly job compares every pin with the tool's latest release, installs the
new pin on the runner, runs the offline tests and opens a pin-bump PR with the results. It reads
only the checksums the releases publish (GitHub asset digests, PyPI file digests, npm integrity)
and never guesses one.

## 6. Tests

All offline: the tools are downloaded once into `.test-data/` and kept, a curl stand-in blocks
network fetches, and a gh stand-in answers searches from captured issues. The suites cover the
install and its checksums, the scripted agent mistakes the lint hook must catch on the OMS
fixture (and silence on the unchanged tree), hook routing, the MCP server's tool list, the smell
rules, the bootstrap in both modes, the global map's golden output, the findings loop and its
sanitizer, and the release watch. Checks against a live IRIS run only when one answers.

## 7. Known limits

- Skills run kit scripts by their installed path (`${CLAUDE_PLUGIN_ROOT}/scripts/...`), which a
  project allow list cannot name in advance, so those commands ask for permission.
- Permission policy cannot ship in a plugin; the bootstrap writes it into the project settings.
- Plugins with a top-level `bin/` are rejected on claude.ai and Cowork, so the tools install into
  `${CLAUDE_PLUGIN_DATA}` instead.
- The release watch names platform gaps but does not fill them: a new platform is pinned by hand,
  once its binary has been run there.
- `detect` proposes every top-level folder that holds ObjectScript with headers; the skill shows
  the list and the user chooses (`--source-dir` overrides it).
