## Summary

When a label, procedure or method has two independent defects, only the first is reported. Once a statement produces a diagnostic, the later statements in the same body are not checked. Fix the first, run again, and the second appears. Inside an `if { }` block the stop is limited to that block: statements after the block are still checked.

This also happens when the first diagnostic is only a warning. A7155 (precedence) and A6705 (too few arguments) are warnings, but they still stop the check, so a warning can hide an error such as an undefined variable.

## Repro

`DEMO.mac`:

```objectscript
ROUTINE DEMO
DEMO ; two independent defects in one procedure
    quit
TWO() public {
    set total = $$ADD(1, 2, 3)
    write total, " ", totl, !
    quit
}
WARNFIRST(n) public {
    set x = n - 1 * 12
    write x, totl, !
    quit
}
ONLYUNDEF() public {
    set total = $$ADD(1, 2)
    write total, " ", totl, !
    quit
}
ADD(a, b) public {
    quit a + b
}
```

```
ascot analyze DEMO.mac
```

## Actual

```
error: DEMO.mac:5:29-30 - Too many arguments [A5523]
warning: DEMO.mac:10:13-23 - ObjectScript has no operator precedence and evaluates strictly left-to-right; this may not compute what you expect [A7155]
error: DEMO.mac:16:23-27 - This value is undefined: totl [A7095]
3 diagnostic(s) across 1 file(s)
```

`totl` is undefined on lines 6, 11 and 16, but only line 16 is reported. In `TWO` the A5523 hides it, and in `WARNFIRST` the A7155 warning hides it. With the first defect of `TWO` and `WARNFIRST` removed, A7095 is reported on lines 6 and 11.

The same happens in a class method (`set total = ..Add(1, 2, 3)` then `quit totl`: only A5523). It also happens with A6851 (missing label), A3850 (unknown function), A6705 (too few arguments) and A7095 itself: two undefined variables in one procedure give one diagnostic.

## Expected

Each independent defect is reported in one run. In the repro: A7095 on lines 6, 11 and 16 as well as A5523 and A7155. Warning-level kinds should not hide errors after them.

## Likely cause

In `src/check/mod.rs`, each routine element is checked as one `Result`, and only its `Err` is kept:

```rust
if let Err(err) = result {
    diagnostics.push(err.into());
}
```

Statement checks propagate with `?`, so the first `Err` ends the body. A7155 is raised as `return Err(QuasiTypeError::mixed_precedence())` even though its severity is Warning. Soft diagnostics (for example A5579, A5718) do not stop the check.

## Why it matters

An agent or developer acting on diagnostics needs one run per defect instead of one run in all. A file with only a precedence warning looks safer than it is, because the undefined variable after it is not shown.

## Version note

Reproduced on ascot v0.4.3 (macOS, universal binary) and v0.2.0.

The output is the same on both. Related: #14 fixed this pattern for argument-mode mismatches ("silently dropping every later diagnostic in the method"), and #133 (merged after v0.4.3) does so for A5718. No change makes the general case continue.

Related: #136 is the same mechanism triggered by the A4043 hint on valid legacy code (a stand-alone `ELSE`, an argumentless `DO`, a dotted line). This issue is about any first diagnostic, including warnings.
