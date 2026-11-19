---
name: characterize
description: Pin the current behaviour of a legacy ObjectScript routine with characterization tests (%UnitTest) before changing it - its entry points, the locals it reads, the globals and ^TMP lists it writes, what it prints, what it asks at the terminal - and prove the tests catch a change before relying on them. Use before refactoring, modernizing, fixing or extending a routine, or when asked for characterization, regression or safety-net tests for legacy code.
---

# Characterize, then change

A characterization test records what the code does **today**, bugs included, so a change that
alters it fails a test instead of reaching users. Write them first, see them pass on the
unchanged code, prove they catch a change, and only then edit the routine. The lesson from the OMS demo:
`GOTO PRT+3` looked harmless, compiled, and passed review; only a test of the printed output
showed that moving one line made `RECENT` print the wrong thing and then fail.

## 1. Find the interface

The interface of a legacy routine is wider than its labels' formal parameters.

- **Entry points**: every label called from outside. Search the source directories for `^RTN`
  (`DO LABEL^RTN`, `$$LABEL^RTN`, `GOTO LABEL^RTN`, `JOB`, `$TEXT(LABEL^RTN)`), menus and
  `XECUTE` strings that name it, and the class layer (`do LABEL^RTN` inside methods).
- **Inputs it reads from the caller's symbol table**: locals used before they are set in the
  label and not `NEW`ed (`FROM`, `TO`, `CID`, `N`, and `U="^"` set at sign-on). They are part
  of the interface: keep them working.
- **Outputs**: `$$` return values; globals and `^TMP($J,...)` nodes it sets or kills
  (the `iris-legacy:map-globals` skill lists them per label, from the code); what it `WRITE`s;
  what it `READ`s; errors it logs; locks and transactions.
- **Hazards in it**: `/iris-legacy:lint` with `--smells` on the file lists `GOTO LABEL+n`, naked
  references, `LOCK` without timeout and `QUIT` inside an open transaction. Each one is a place
  where a harmless-looking edit changes behaviour: give it a test. `LABEL+n` counts lines of the
  compiled `.int` (`iris_doc` `RTN.int`), not of the source file.

## 2. Write the tests

Start from `${CLAUDE_PLUGIN_ROOT}/skills/characterize/Template.cls`: copy it into the project's
test package (rename the class and the file), keep its helpers, replace the examples.

- **Pin outcomes, not internals**: the list in `^TMP`, the record written, the text printed.
  A refactor is allowed to change how; the tests say what.
- **Printed output**: `..Capture("LABEL^RTN")` runs the label with output redirected to a file
  and returns it with `|` for each line feed. Assert exact text for short output; for long
  output, a few exact lines plus a fingerprint (`$zcrc(out, 7)`) of the whole.
- **Terminal input**: `..Drive("DriveX", $listbuild(answer1, answer2))` runs a class method of
  the test class as a job whose input is a file of answers. The job does not inherit locals, so
  that method sets `U` and the inputs, then calls the label. Too few answers end the job with
  `<ENDOFFILE>` in the output, not a hang.
- **Data**: run against known data (a reset that regenerates the same data), or have the test
  create its own records and remove them. Check `$TLEVEL=0` and clean `^TMP($JOB)` after.
- **Inputs from the symbol table**: list them in `PublicList` and `NEW` them in the test method,
  as in the template, so the test sets exactly what a caller would.
- Cover each entry point, each branch you can reach with the data, the edge inputs the code
  handles (empty, zero, a bad date), and every hazard from step 1.

## 3. Prove they catch a change

1. Run the tests on the unchanged code (`scripts/test.sh Package.Class`, or `iris_test`). All
   must pass. A test that fails here has the expected value wrong, not the code.
2. Make one deliberate behaviour change in the routine, for example move a line across the
   target of a `LABEL+n`, change a loop bound from `>` to `'<`, or drop a piece. At least one
   test must fail. Undo it (`git checkout -- FILE`; the hook recompiles). Try two or three
   different changes; note which test caught each.
3. If a change goes uncaught, add the missing test before going on.

## 4. Change, one step at a time

- Replace offset jumps first, with the behaviour unchanged: give the target line its own label
  and call that (`GOTO PRT+3` becomes `DO PRTBODY`). Run the tests. Then restructure.
- Keep every entry point and every symbol-table input. Keep the style the task asks for, and only
  that.
- After each step: the hook compiles it; run the characterization tests and the rest of the
  suite. A red test means the step changed behaviour: undo or fix the step, never the test,
  unless the user decided the behaviour should change (then change that test on purpose and
  say so).
- Leave the tests in the suite: they protect the next change too.
