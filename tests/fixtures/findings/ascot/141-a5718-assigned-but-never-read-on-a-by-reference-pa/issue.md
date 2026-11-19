## Summary

A label or method can take an array by reference and start with `KILL x` to clear it before filling it. ascot then reports A5718 "Variable 'x' is assigned but never read" at the parameter declaration. The caller reads the result, so nothing goes unread. A routine label has no `Output` keyword, so no declaration avoids the warning.

## Repro

`src/DEMOOUT.mac`:

```objectscript
ROUTINE DEMOOUT
FILL(&x) public {
    kill x
    set x("a") = 1
    quit
}
FILLNOKILL(&x) public {
    set x("a") = 1
    quit
}
USE() public {
    do FILL(.r), FILLNOKILL(.s)
    write r("a"), s("a"),!
    quit
}
```

`src/Demo.Out.cls`:

```objectscript
Class Demo.Out [ Abstract ]
{

ClassMethod FillByRef(ByRef x As %String)
{
    kill x
    set x("a") = 1
}

ClassMethod FillOutput(Output x As %String)
{
    kill x
    set x("a") = 1
}

}
```

Command:

```
ascot analyze src/
```

## Actual (v0.4.3)

```
warning: src/DEMOOUT.mac:2:7-8 - Variable 'x' is assigned but never read [A5718]
warning: src/Demo.Out.cls:4:23-41 - Variable 'x' is assigned but never read [A5718]
2 diagnostic(s) across 2 file(s)
```

v0.2.0 gives the same output. Only the `KILL` triggers it. `FILLNOKILL` and `FillOutput` are not reported, and neither is a by-ref parameter overwritten with `set x = 5`.

## Expected

No A5718 for a by-reference parameter, because its value goes back to the caller. In a routine label there is nothing to report. In a method, a hint that `Output` fits better than `ByRef` would be accurate. "Assigned but never read" is not.

## Why it matters

Legacy routines often clear an output array with `KILL` before filling it. An agent that acts on this warning may remove the `KILL`, and the caller's old nodes then stay in the result. The warning also stays after following A5579's advice to add `&`.

## Version note

Reproduced on ascot v0.4.3 (macOS, universal binary) and v0.2.0.

The code is unchanged on main (aedf33f): `Flow::run` in `src/check/flow.rs` enters a `ByRef` parameter in the unread list as not read, and `handle_kill` drops pending writes without marking them read.
