## Summary

ascot accepts `$ZU(...)` and `$ZUTIL(...)` calls without any diagnostic. Many of these calls have documented replacements, for example `$ZU(5)` is `$NAMESPACE` and `$ZU(68,40,n)` is `$SYSTEM.Process.SetZEOF(n)`. ascot does report an unknown function such as `$ZFOO`, so the gap is only for `$ZUTIL`.

## Repro

`DEMO.mac`:

```objectscript
ROUTINE DEMO
DEMO ; superseded $ZUTIL calls
 quit
NS() ; current namespace
 quit $ZU(5)
NS2() ; the same, long form
 quit $ZUTIL(5)
ZEOF() ; process end-of-file handling
 new old
 set old=$ZU(68,40,1)
 quit old
BAD() ; an unknown function, for contrast
 quit $ZFOO(1)
```

```sh
ascot analyze DEMO.mac
```

No IRIS connection is needed.

## Actual (v0.4.3)

```
error: DEMO.mac:13:7-15 - $ZFOO is not a recognized function; did you mean: ZF, F, ZBOOLEAN, ZCOS, ZCOT? [A3850]
1 diagnostic(s) across 1 file(s)
```

Lines 5, 7 and 10 get nothing. If you remove the `$ZFOO` line, the file reports `0 diagnostic(s)` and exits 0. v0.2.0 gives the same output. A class method that returns `$ZUTIL(5)` also gets nothing.

## Expected

A warning or hint on each `$ZU`/`$ZUTIL` call that has a documented replacement, with the replacement in the message, for example:

- `$ZU(5)`: use `$NAMESPACE`
- `$ZU(68,40,n)`: use `$SYSTEM.Process.SetZEOF(n)`

The mapping could follow the published `$ZUTIL` replacement list. The InterSystems Language Server uses that list for its diagnostic ("`$ZUTIL` functions that are deprecated or have been superseded", intersystems/language-server#254). A call with no known replacement could get a generic "undocumented in IRIS" hint, or nothing. The IRIS ObjectScript Reference lists `$ZU` only as "`$ZUTIL` function (see the Caché/Ensemble documentation)".

## Why it matters

Legacy routines still contain many `$ZU` calls, and moving them to the supported API is a normal part of maintaining them. A coding agent or CI job that acts on ascot's diagnostics treats silence as "fine", so these calls are never reported, while the editor's Language Server reports them.

## Version note

Reproduced on ascot v0.4.3 (macOS, universal binary) and v0.2.0.
