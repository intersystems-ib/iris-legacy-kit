## Summary

When a `GOTO` or `DO` target has an offset (`LABEL+n`), ascot does not look the label up.

- `G NOPE+3` and `D NOPE+1` are not reported. `G NOPE` is reported (A6851).
- `G LBL+99`, past the end of the routine, is not reported.
- `references` on a label (LSP and MCP) does not list `G LBL+3`, `D LBL+2` or `D LBL+1^DEMO`.
- `definition` at those call sites returns null.

## Repro

`src/DEMO.mac`:

```
ROUTINE DEMO
DEMO ; label+offset demo
 Q
LBL ; four lines
 S X=1
 S X=2
 S X=3
 Q
OK0 ; plain call (control)
 D LBL
 Q
OK1 ; valid offset, GOTO
 G LBL+3
OK2 ; valid offset, DO
 D LBL+2
 Q
BAD1 ; no such label, GOTO with offset
 G NOPE+3
BAD2 ; no such label, DO with offset
 D NOPE+1
 Q
BAD3 ; offset past the end of the routine
 G LBL+99
CONTROL ; no such label, no offset (control)
 G NOPE
```

CLI:

```
ascot analyze src/
```

LSP (`ascot lsp`, workspace root `src/`) and MCP (`ascot mcp`, after `create_workspace` and `insert` of the file), positions zero-based:

- `references` at line 3, character 0 (the label `LBL`)
- `definition` at line 12, character 3 (`G LBL+3`) and line 14, character 3 (`D LBL+2`)

Cross-routine, add `src/DEMO2.mac`:

```
ROUTINE DEMO2
DEMO2 ;
 D LBL^DEMO
 D LBL+1^DEMO
 D NOPE+1^DEMO
 D NOPE^DEMO
 Q
```

## Actual (v0.4.3)

v0.2.0 gives the same output for every check below.

CLI on `DEMO.mac`: only the control line is reported.

```
error: src/DEMO.mac:25:2-8 - Cannot find label 'NOPE' in this routine [A6851]
1 diagnostic(s) across 1 file(s)
```

Each of `G NOPE+3`, `D NOPE+1`, `G LBL+99` and `D NOPE+1^DEMO` alone in a label gives 0 diagnostics, so one error is not hiding another.

LSP and MCP give the same answers:

```
references at LBL      -> DEMO.mac 10:4 (D LBL), DEMO.mac 4:1 (declaration)
definition at G LBL+3  -> null
definition at D LBL+2  -> null
```

With `DEMO2.mac` added:

```
error: src/DEMO.mac:25:2-8 - Cannot find label 'NOPE' in this routine [A6851]
error: src/DEMO2.mac:6:4-13 - Cannot find label 'NOPE' in routine 'DEMO' [A6851]
2 diagnostic(s) across 2 file(s)
```

Line 5 (`D NOPE+1^DEMO`) is not reported. `references` at `LBL` lists `DEMO2.mac` line 3, `DEMO.mac` line 10 and the declaration, not `DEMO2.mac` line 4. `definition` at `D LBL+1^DEMO` returns null.

## Expected

- `G NOPE+3`, `D NOPE+1` and `D NOPE+1^DEMO`: the same A6851 as without the offset. IRIS raises `<NOLINE>` at run time when the label does not exist, with or without an offset. The label part can be checked whatever the offset expression is.
- `G LBL+99`: a diagnostic when a literal offset goes past the last line of the routine (also `<NOLINE>` at run time). IRIS counts offsets in the compiled `.int`, so this may only be safe where ascot can count lines exactly. An offset that lands in a later label is legal and should not be an error.
- `references` on `LBL` includes `G LBL+3`, `D LBL+2` and `D LBL+1^DEMO`.
- `definition` at `G LBL+3` goes to `LBL` (or to the line it reaches).

## Why it matters

`GOTO LABEL+n` and `DO LABEL+n` are common in legacy routines. After a label is renamed or deleted, these call sites break without a diagnostic. The MCP `references` tool says to call it "before renaming or removing a member/label to see every call site that would break", so an agent acting on its result misses these callers.

## Version note

Reproduced on ascot v0.4.3 (macOS, universal binary) and v0.2.0.

The release notes up to v0.4.3 do not mention label+offset. "Goto targets" in #120 is about the returns of a label reached by `Goto` inside a method.

Likely cause, in the source on main (aedf33f, 2026-10-30) and in v0.2.0:

- `resolve_label` in `src/check/env.rs` returns `TyProcedureOrAny::Any` when an offset is present, without looking the label up. For `label+offset^routine` it checks only the routine.
- `call_label` in `src/check/mod.rs` records a reference only when it gets a `Procedure` back, so `references` and `definition` skip these call sites.
