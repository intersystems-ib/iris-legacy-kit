---
name: lint
description: Run the kit's static checks on the project's ObjectScript on demand - filtered ascot diagnostics (broken calls, missing labels and routines, wrong argument counts) and legacy-smell hits (naked global references, LOCK without timeout, GOTO LABEL+n, QUIT inside an open transaction, $ZU). Use before refactoring a routine, to list the hazards in it, or when asked to lint or check the code.
---

# Static checks on demand

The edit hooks already report what each edit **adds**. This skill shows the whole picture, which
is what you want before a refactor: every `GOTO LABEL+n` and naked reference in the routine is a
hazard to pin with a characterization test first.

- Everything (ascot, then smells), for the project's source dirs:

  ```bash
  CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}" "${CLAUDE_PLUGIN_ROOT}/scripts/lint.sh"
  ```

- The ascot part as SARIF 2.1.0, for a code-scanning upload or a CI job (exit 0 clean, 1 findings,
  2 ascot did not run):

  ```bash
  CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}" "${CLAUDE_PLUGIN_ROOT}/scripts/lint.sh" --sarif > ascot.sarif
  ```

- Legacy smells only, for one routine or folder:

  ```bash
  CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}" "${CLAUDE_PLUGIN_ROOT}/scripts/lint.sh" --smells src/rtn/NAME.mac
  ```

Reading the results:

- ascot lines are filtered to codes that were accurate on legacy code. Treat them as real.
- ascot knows IRIS's own classes and routines from the declarations the kit pins (IRIS Community,
  `%SYS`), and the project's from its source dirs. Calls to `%` routines are not reported (site
  routines such as `^%ZSTART` live on the instance only). A class `%SYS` lacks, such as `Ens.*` or
  `HS.*`, is reported missing (A8061); for such projects, point `lint.ascotIris` at a declarations
  file made with `ascot declare` against the development instance, or drop A8061 from the codes.
- "Static check incomplete: ascot did not run" is a tool problem, not the code's: run
  `/iris-legacy:setup`.
- Smells are legal code that is risky to change, not bugs to fix. Do not clean up smells outside
  the task; fix the ones your change touches, and pin the rest with tests before a refactor.
- A smell scan reads the routine's syntax only. It cannot say whether a naked reference resolves
  to the right node; read the code (and the global map) for that.

The project's `.claude/iris-legacy.json` lists the source dirs and can switch either check off
(`"lint": {"ascot": false}` or `"smells": false`), replace the ascot code list (`"ascotCodes"`)
or add declarations files asked before the kit's (`"ascotIris": ["path/to/file.d.json"]`). If the
script says the tools are missing, use `/iris-legacy:setup`.
