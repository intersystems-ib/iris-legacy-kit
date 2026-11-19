## Summary

ascot reports the hint A4043 "Type checking not implemented for ..." on a stand-alone `ELSE`,
an argumentless `DO` and a dotted line. After that hint, nothing else in the same label or
procedure is checked. Undefined variables, missing labels and unknown functions after it are not
reported, and neither are `--style` warnings. The next label is checked again.

A stand-alone `ELSE` here is one that does not follow an `IF` on the line before, for example
after a timed `LOCK` or `READ`. Both forms are valid and common in older routines. The same code
written with `if '$test { ... }` is checked.

## Repro

`DEMO.mac`:

```objectscript
ROUTINE DEMO
WithElse(count) public {
    lock +^Demo(count):5
    else  quit 0
    set total = cuont + 1
    quit total
}
WithTest(count) public {
    lock +^Demo(count):5
    if '$test { quit 0 }
    set total = cuont + 1
    quit total
}
```

`DEMOL.mac` (labels without procedure blocks):

```objectscript
ROUTINE DEMOL
AFTERELSE ; stand-alone ELSE after a timed LOCK
 L +^Demo(1):5
 E  Q 0
 D MISSING
 Q 1
AFTERDO ; argumentless DO with a dotted block
 D
 . S X=1
 D MISSING
 Q
AFTERIFDO ; the same behind an IF
 I $D(^Demo) D
 . S X=1
 D MISSING
 Q
CONTROL ; neither
 D MISSING
 Q
```

```
ascot analyze DEMO.mac
ascot analyze DEMOL.mac
```

## Actual

v0.4.3 (v0.2.0 prints the same):

```
$ ascot analyze DEMO.mac
hint: DEMO.mac:4:5-17 - Type checking not implemented for 'Stand-alone Else Command' [A4043]
error: DEMO.mac:11:17-22 - This value is undefined: cuont [A7095]
1 diagnostic(s) across 1 file(s)

$ ascot analyze DEMOL.mac
hint: DEMOL.mac:4:2-8 - Type checking not implemented for 'Stand-alone Else Command' [A4043]
hint: DEMOL.mac:8:2-3 - Type checking not implemented for 'Do without arguments' [A4043]
hint: DEMOL.mac:14:4-9 - Type checking not implemented for 'Dotted block' [A4043]
error: DEMOL.mac:18:4-11 - Cannot find label 'MISSING' in this routine [A6851]
hint: DEMOL.mac:13:14-15 - Type checking not implemented for 'Do without arguments' [A4043]
1 diagnostic(s) across 1 file(s)
```

- `cuont` on line 5 of `DEMO.mac` is not reported. The same line in `WithTest` (line 11) is.
- In `DEMOL.mac`, only the `D MISSING` in `CONTROL` (line 18) is reported. Lines 5, 10 and 15
  are not.
- In `AFTERIFDO`, the `DO` hint does not end the label, but the dotted line 14 does
  ("Dotted block").
- With only `WithElse` in the file, ascot prints the hint and "0 diagnostic(s) across 1 file(s)",
  and exits 0. The file looks clean.
- An `E` on the line right after a line-level `I` is not affected: it gets no hint, and the code
  after it is checked.

## --style

`--style` warnings (A2839) are reported by the same walk, so they stop at the same places. A
`FOR` body loses them too.

`style.json`:

```json
{"command":{"form":"Long"},"function":{"form":"Long"}}
```

`DEMOS.mac`:

```objectscript
ROUTINE DEMOS
DOTTED ; FOR with an argumentless DO and a dotted block
 S T=0
 F I=1:1:3 W I D
 . S T=T+$L(I)
 W T,!
 Q
ELSE ; stand-alone ELSE after a timed LOCK
 L +^Demo(1):5
 E  Q 0
 S T=1
 Q 1
CONTROL ; neither
 S T=$L(2)
 Q
```

v0.4.3 (v0.2.0 prints the same):

```
$ ascot analyze --style style.json DEMOS.mac
hint: DEMOS.mac:4:16-17 - Type checking not implemented for 'Do without arguments' [A4043]
hint: DEMOS.mac:10:2-8 - Type checking not implemented for 'Stand-alone Else Command' [A4043]
warning: DEMOS.mac:3:2-3 - Command keyword `S` should be written `Set` [A2839]
warning: DEMOS.mac:4:2-3 - Command keyword `F` should be written `For` [A2839]
warning: DEMOS.mac:9:2-3 - Command keyword `L` should be written `Lock` [A2839]
warning: DEMOS.mac:10:2-3 - Command keyword `E` should be written `Else` [A2839]
warning: DEMOS.mac:14:2-3 - Command keyword `S` should be written `Set` [A2839]
warning: DEMOS.mac:14:7-8 - Function `$L` should be written `$Length` [A2839]
warning: DEMOS.mac:15:2-3 - Command keyword `Q` should be written `Quit` [A2839]
7 diagnostic(s) across 1 file(s)
```

7 of the 16 short keywords are reported. Not reported: `W` and `D` on line 4, `S` and `$L` on
line 5, `W` on line 6, `Q` on line 7, `Q` on line 10, `S` on line 11 and `Q` on line 12.

- Inside a dotted block, no keyword is reported.
- After a stand-alone `ELSE`, nothing is reported to the end of the label, including the
  commands on the `ELSE` line.
- In a `FOR` body that contains an argumentless `DO`, only the `F` is reported, not the
  keywords before the `DO`. The same happens with an ordinary error: in
  `F I=1:1:3 S X=I W X,$TRX(I)` only the `F` gets a warning, although `S` and `W` come before the
  error.

PR #60 says style after a hard error in the same method or loop body is not reported until the
error is fixed. Here there is no error. The only diagnostic is the A4043 hint, the code is valid,
and the style report never becomes complete.

## Expected

- A4043 marks only the construct it could not check. Checking goes on with the next command, or
  the next line at the same level.
- A stand-alone `ELSE` could be checked like `if '$test`, or as a branch that may or may not run.
- For an argumentless `DO`, skipping the dotted block and going on after it would already help.
  Checking the block would be better.
- In the repro, `cuont` on line 5 of `DEMO.mac` and the `D MISSING` calls on lines 5, 10 and 15
  of `DEMOL.mac` are reported.
- If checking has to stop, the hint says so, for example "the rest of this label was not
  checked".
- With `--style`, an A2839 warning for each of the 16 keywords in `DEMOS.mac`. The README says
  "each command keyword or intrinsic function name written differently is reported as a
  warning". Style depends only on the parse tree, so it could be collected in a pass of its own
  and not depend on how far type checking gets. Fixing the A4043 stop alone would not cover
  dotted lines while they are not type-checked.

## Why it matters

These forms are everywhere in legacy routines, so the oldest code gets the least checking. An
agent or a CI gate that sees no errors and exit code 0 takes the code as checked, when the rest
of the label was skipped.

A style count is a simple way to measure progress when modernising old routines. On those
routines it undercounts by an amount that depends on where the first `ELSE` or dotted block
sits, so before/after counts are not comparable, and an agent that fixes the reported keywords
leaves the rest as they were.

## Version note

Reproduced on ascot v0.4.3 (macOS, universal binary) and v0.2.0. The code paths are unchanged on
`main` (aedf33f, 2026-10-30):

- `src/check/mod.rs`: `Command::Else` and `Command::ElseIf` return
  `Err(QuasiTypeError::unimplemented(...))`. `Do` without arguments does the same through
  `ok_or_else(...)?`. A `CommandLine` with periods returns
  `Err(TypeError::unimplemented("Dotted block", ...))`.
- `ProcedureMain::check` passes the first `Err` up (`line.check(env, flow)?`), and
  `check_block_body` catches it per label. So A4043 takes the hard-error path, although its
  severity is Information.
- `report_style` is called from `Range<T>::check`, just before each command's `inner_check`, so
  a keyword is styled only if the walk reaches its command.
- In a `FOR` body, `Flow::run_loop_passes` (`src/check/flow.rs`) first runs a priming pass with
  soft diagnostics suppressed (`Flow::primed`) and returns on its first `Err`. The style warnings
  of that pass are dropped, so the keywords before the `DO` are lost too.
- The test `bare_do_without_arguments_is_unimplemented` in `src/lib.rs` expects the hint and
  nothing else.
- Related, not duplicates: #34 fixed an earlier A4043 ("Labels and subroutines") that stopped the
  checker, and #14 made a hard error soft because it dropped every later diagnostic in the
  method. That a real error ends the rest of a body is a known trade-off (test comment in
  `src/lib.rs`: "The hard error last, since it stops checking the rest of the body"). This issue
  is only about A4043, where the code is valid and there is nothing to fix.
