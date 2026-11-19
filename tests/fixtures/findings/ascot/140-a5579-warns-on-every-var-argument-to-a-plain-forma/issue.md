## Summary

Passing a variable by reference (`.x`) to a label or method whose formal parameter has no `&` or `ByRef` is legal. The callee gets the variable by reference and its changes reach the caller. ascot reports A5579 as a warning at every such call, and the related note says to add `&` or `ByRef` "to declare it by-ref".

The documentation describes both markers as having no effect:

- RCOS, Symbols Used in ObjectScript, `&`: "In a formal parameter list, an optional, non-functional variable name prefix that marks a parameter as one that should be passed by reference."
- GOBJ 7.5, Indicating How Arguments Are to Be Passed: "The ByRef and Output keywords provide information for the benefit of anyone using the InterSystems Class Reference. They do not affect the behavior of the code."

The comment above the check in `src/check/mod.rs` says the same: "the caller's `.` alone decides by-reference; `ByRef`/`Output` document intent".

Older routines rarely use `&`, so a helper that takes a counter or seed by reference gives one warning per call site.

## Repro

`DEMO.mac`:

```objectscript
ROUTINE DEMO
DEMO ; by-reference argument passed to a plain formal parameter
    quit
MAIN() public {
    set seed = 42
    set a = $$NEXT(.seed)
    write a, " ", seed, !
    quit
}
NEXT(seed) public {
    set seed = seed + 1
    quit seed
}
OLD ; older style, no procedure block
    S X=1,Y=$$NXT(.X) W X," ",Y,!
    Q
NXT(N) S N=N+1 Q N
```

```
ascot analyze DEMO.mac
```

## Actual

```
warning: DEMO.mac:6:20-25 - The parameter 'seed' is declared as a normal parameter but got a by-ref argument [A5579]
- DEMO.mac:10:6-10: Parameter declared here — add `&` (routine label) or `ByRef` (method) to declare it by-ref.
warning: DEMO.mac:15:19-21 - The parameter 'N' is declared as a normal parameter but got a by-ref argument [A5579]
- DEMO.mac:17:5-6: Parameter declared here — add `&` (routine label) or `ByRef` (method) to declare it by-ref.
2 diagnostic(s) across 1 file(s)
```

With `NEXT(&seed)` and `NXT(&N)` the file gives 0 diagnostics. A class method `Next(seed As %Integer)` called as `..Next(.seed)` gives the same warning.

## Expected

No warning when a by-reference argument is passed to a plain formal parameter, or at most a hint. This matters most for routine labels, where `&` is uncommon. The reverse case (a value passed to a `ByRef` or `Output` parameter) can stay a warning, because the callee's change does not reach the caller.

If the warning stays, the related note could say that the call already passes by reference and that `&`/`ByRef` only documents it.

## Why it matters

In legacy code this warning repeats at every call and hides the warnings that need action. An agent that acts on the message may "fix" the call by removing the `.`, which changes behaviour, or edit many labels for no functional gain.

## Version note

Reproduced on ascot v0.4.3 (macOS, universal binary) and v0.2.0.

The output is the same on both. Related: #14 made mode mismatches soft so checking continues after them. Its notes report about 2,470 more mode-mismatch warnings (both directions) on the `%SYS` corpus.
