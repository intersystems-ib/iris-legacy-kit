<!-- iris-legacy:begin. Written by /iris-legacy:bootstrap, which replaces this block when it runs again; put project notes outside it. -->
## Working on the ObjectScript here

The ObjectScript in __SRC_DIRS__ is the source of truth. It runs in IRIS namespace `__NS__`
__WHERE__.

- Edit the files with the normal file tools. After each edit of a `.mac`/`.int`/`.inc`/`.cls`
  file in those directories, a hook uploads and compiles it in `__NS__` and tells you the
  result. A compile error comes back as a hook error: fix it before moving on. Files elsewhere
  are never sent to IRIS.
- A second hook runs static checks after each edit: ascot errors anywhere in the source
  directories (for example callers of a label you renamed), and legacy smells your edit
  **added** to a routine (naked references, `LOCK` without timeout, `GOTO LABEL+n`, quitting
  inside an open transaction, `$ZU`). Fix the errors; avoid adding the smells.
- Do not write documents straight into IRIS (`iris_doc` put, `iris_compile`) except for
  throwaway probes, and delete those afterwards. Anything that exists only in IRIS is lost.
- New code: a routine starts with a `ROUTINE <NAME>` header line; a class needs its `Class`
  line. The hook names the document from that header, not from the file name.
- Match the style of the routine you are editing (abbreviated or full commands, dot syntax or
  braces). Change what the task needs; do not reformat or modernise the rest.
- **Before changing the behaviour of a legacy routine, pin its current behaviour with a
  characterization test** and check that it passes against the unchanged code
  (`iris-legacy:characterize` skill).
- For routine and global idioms (naked references, `$ORDER`/`$DATA`, `LOCK`, transactions,
  `LABEL+n`), use the `iris-legacy:legacy-routines-globals` skill.

### Running things

| Need | How |
|---|---|
| Run ObjectScript in `__NS__` | `iris_execute`. Output comes back only through `WRITE`. Older labels take their inputs from local variables: set them in the same call__U_NOTE__ |
| Find code in IRIS | `iris_search` needs a document scope, e.g. `documents: ["*.mac"]`; or grep the source directories |
| What IRIS compiled | `iris_doc` with `NAME.int` |
| Read globals | `iris_global` if the server has it (iris-interop-dev 0.27 and later); otherwise `iris_execute` with `$ORDER`/`$DATA`/`$GET`, a few nodes at a time. Do not write or kill application globals unless the task requires it |
<!--docker-->
| Tests | `scripts/test.sh [class or package]` (default `__TEST_PACKAGE__`): PASS/FAIL per method, failed assertions with their location, non-zero exit on failure. `iris_test` also works |
<!--/docker-->
<!--existing-->
| Tests | `iris_test` with the class or package (the project's tests are in `__TEST_PACKAGE__`) |
<!--/existing-->
| Which labels read, set, kill or lock each global (static, from the code) | the `iris-legacy:map-globals` skill |
| Static checks of all the source directories | the `iris-legacy:lint` skill (ascot errors and legacy smells) |
| A tool misbehaves (false positive, wrong data, hook error that is not your code) | the `iris-legacy:report-upstream` skill: record it with a generic repro; never paste project code into an issue |

Tests are `%UnitTest.TestCase` subclasses; only methods named `Test*` run.

### Errors

<!--etn-->
- Code that traps errors with `__ERROR_TRAP__` logs them to the **application error log**,
  global `^ERRORS` in `__NS__`: `^ERRORS(day, n, "*STACK", level, ...)`, with the error text at
  `"*STACK", 0, "V", "$ZE"`. List recent errors with `iris_debug` `error_logs`, or with
  `iris_execute`:

  ```objectscript
  set d=$order(^ERRORS(""),-1) for  { quit:d=""  set n="" for  { set n=$order(^ERRORS(d,n),-1) quit:n=""  write $zdate(d,3)," #",n,"  ",$get(^ERRORS(d,n,"*STACK",0,"V","$ZE")),! } set d=$order(^ERRORS(d),-1) }
  ```

<!--/etn-->
- An error location `LABEL+n^RTN` counts lines in the compiled `RTN.int`, which drops blank
  lines. `iris_debug` `map_int` with the error text (e.g. `<UNDEFINED>LABEL+2^RTN *X`) returns the
  `.int` line and the `.mac` line it came from. By hand, count from `LABEL` in the `.int`
  (`iris_doc` `RTN.int`), not in the source file.

### IRIS for this project

<!--docker-->
A development IRIS in Docker: `scripts/up.sh` starts it and its Web Gateway and loads the
source directories; `scripts/check.sh` checks it; `scripts/load.sh` reloads everything;
`scripts/iris.sh` opens a terminal (for a person: it is interactive). Credentials
`_SYSTEM`/`SYS` are dev only.
<!--/docker-->
<!--existing-->
A shared development instance at `__HOST__` (web port `__WEB_PORT__`), namespace `__NS__`. The
username and password come from `IRIS_USERNAME` and `IRIS_PASSWORD` in each developer's
`.claude/settings.local.json` (gitignored), never from a committed file. Other people use this
namespace too: do not reload or reset it wholesale, and keep probes short-lived.
<!--/existing-->
<!-- iris-legacy:end -->
