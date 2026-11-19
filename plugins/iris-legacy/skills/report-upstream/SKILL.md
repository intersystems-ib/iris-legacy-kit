---
name: report-upstream
description: Capture a defect in one of the kit's tools (iris-interop-dev MCP tools and compile hook, ascot diagnostics, ast-grep, the tree-sitter-objectscript grammar, or the kit's own hooks, smell rules and scripts) with a generic synthetic repro, check it against known issues and for customer names, and file it where it belongs. Use when a tool gives a false positive or wrong data, crashes, or misbehaves; when the session-start message says findings are not filed yet; or when asked to report or file a tool problem.
---

# Report a tool defect

The kit improves by reporting what goes wrong with its tools. This skill turns a defect you met
into an issue: captured in the project's findings ledger, checked, then filed. Customer code
never leaves the project: the repro is a new, minimal file you write, and a sanitizer refuses
anything that carries this project's names.

**Only tool defects.** A bug in the customer's code is not a finding. Neither is a tool doing
what its documentation says, however inconvenient.

## 1. Pin it down

- Which tool, and which part of it: an MCP tool (`iris_doc`, `iris_execute`, ...) or the compile
  hook is iris-interop-dev; a diagnostic code like `A6851` is ascot; a parse error is the
  grammar (tree-sitter-objectscript); a crash of `ast-grep scan` is ast-grep. The smell rules,
  the ascot code filter, `setup.sh`, `post-edit.sh`, `lint.sh` and these skills are the kit
  itself: tool `kit`. Claude Code's own problems go to `/feedback`, not here.
- Reproduce it twice and note the exact command, what it printed, and what it should have done.

## 2. Write a generic repro

Write the smallest new file that shows the defect, **outside the source dirs** (a scratch
directory, not `src/`), so the edit hooks never upload it to IRIS:

- invented names only: routines `DEMO`, `DEMO2`, labels `LBL`, `OK1`, `BAD1`, globals `^X`,
  `^DEMO`, classes `Demo.Thing`. Never a routine, class, global, label, host, namespace, user
  or data value from this project, and never a copy of customer code with names changed: build
  the shape from scratch.
- one defect per finding; a control case next to it (the same call that works) helps.
- the exact command, with the tool's own invocation (`ascot analyze src/`, the MCP call and its
  arguments, `ast-grep scan ...`), then what it printed and what you expected. Run the kit's
  ascot with the kit's declarations, `"${CLAUDE_PLUGIN_DATA}/bin/ascot" analyze --iris
  "${CLAUDE_PLUGIN_DATA}/ascot/declarations.d.json.gz" ...`: without `--iris` it downloads
  declarations into `~/.ascot`.

The ascot issues the kit filed show the style, for example
[intersystems-community/ascot#138](https://github.com/intersystems-community/ascot/issues/138):
Summary, Repro (files and commands), what is reported, what is expected.

## 3. Add it to the ledger

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}" "${CLAUDE_PLUGIN_ROOT}/scripts/report.sh" add \
  --tool ascot --kind false-positive \
  --title "One sentence that names the defect, as an issue title" \
  --symptom "What happens, with the exact message" \
  --expected "What should happen" \
  --repro-text "The command to run, and its output" \
  --repro-file /path/to/scratch/src/DEMO.mac
```

Kinds: `false-positive`, `wrong-data`, `hook`, `crash`, `missing`, `other`. The tool version is
read from the installed binary. Repro files are copied into `.claude/kit-findings/<id>/`, next to
the ledger `.claude/kit-findings.jsonl`; both stay out of git.

## 4. Check, then file

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}" "${CLAUDE_PLUGIN_ROOT}/scripts/report.sh" check ID
```

The check prints three things:

- **sanitizer:** every project name, host, address or user path found in the draft, and where.
  A block means the repro is not generic yet: rewrite it (`report.sh update ID --repro-text ...
  --repro-file ...`) and check again. Never weaken the check or work around it.
- **duplicates:** similar issues and pull requests, open and closed, in the tool's tracker and
  the kit's repo, and earlier findings. `DUPLICATE` blocks filing. `possible` means read that
  issue: if it is the same defect, `report.sh mark ID duplicate URL`; if not, file with `--new`.
  A failed search blocks filing too, because a duplicate could not be ruled out.
- **verdict:** `ok`, `possible`, `duplicate`, `blocked` or `incomplete`.

When the verdict is `ok` (or `possible`, after reading the match):

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}" "${CLAUDE_PLUGIN_ROOT}/scripts/report.sh" file ID --dry-run
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}" "${CLAUDE_PLUGIN_ROOT}/scripts/report.sh" file ID
```

`file` checks again, refuses a finding that is filed already, and files at most
`report.maxPerDay` (default 3) a day. Tell the user what was filed, with the URL it printed, or
why it was not.

Where it goes: at a customer site everything goes to the kit's repo (public: the sanitizer and the
duplicate check run first), with the tool named in the title, and the kit owner takes it
upstream. Only the kit owner's environment
(`IRIS_LEGACY_REPORT_TO=upstream`) files to the tool's own tracker. `report.sh route TOOL` says
where a finding would go.

## Other commands

- `report.sh list` (unfiled) or `list --all`, `report.sh show ID`
- `report.sh mark ID dropped`: not a defect after all, or not worth filing
- The project's `.claude/iris-legacy.json` can add terms the sanitizer must always refuse, such
  as the customer's name: `"report": {"denyTerms": ["Acme"], "maxPerDay": 3}`.
