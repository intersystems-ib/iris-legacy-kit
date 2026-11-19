## Summary

With no IRIS connection, ascot reports every call to a routine that is not in the workspace with the A3303 warning. That includes system routines such as `%ETN`, which every namespace has. A `%` class in the same situation is trusted, or gets a hint.

The README ("Connecting to IRIS") says: "Without a connection, such a class or routine is left unconfirmed (a hint, not an error)". For routines this is not what happens: the diagnostic is a warning, and `ascot analyze` exits non-zero on a warning.

## Repro

`DEMO.mac`:

```objectscript
ROUTINE DEMO
DEMO ; sample routine
 Q
TRAP ; error trap
 D ^%ETN
 D LOG^%ETN
 Q
VER() ; a system class, for comparison
 Q ##class(%SYSTEM.Version).GetVersion()
MISS ; a routine that does not exist, for comparison
 D ^NOSUCH
 Q
```

```sh
ascot analyze DEMO.mac
```

No `--iris`. macOS, release binary `ascot-cli-universal-apple-darwin`.

## Actual

```
warning: DEMO.mac:5:4-9 - Cannot find routine '%ETN' in this workspace, with no IRIS connection to check it against [A3303]
warning: DEMO.mac:6:4-12 - Cannot find routine '%ETN' in this workspace, with no IRIS connection to check it against [A3303]
warning: DEMO.mac:11:4-11 - Cannot find routine 'NOSUCH' in this workspace, with no IRIS connection to check it against [A3303]
3 diagnostic(s) across 1 file(s)
```

Exit code 1. The system class call gets no diagnostic. The system routine gets the same warning as the missing one, once per call.

v0.2.0 reported the same calls as errors ("Routine '%ETN' is not defined in the current workspace") and gave the system class call an A9360 hint.

In the source, `resolve_rtn_labels` in `src/check/env.rs` returns A3303 for any routine name when there is no connection. There is no `%` case like the one in `check_declared_class_exists` ("Every `%`-prefixed name is trusted").

## Expected

One of these:

- Treat a `%` routine like a `%` class when there is no connection: a hint, for example "can't be checked without a connection". Keep the warning for other names, where a typo is likely (`^NOSUCH` above).
- Or change the README to say that a routine outside the workspace is a warning without a connection.

## Why it matters

Legacy code calls system routines such as `^%ETN` from many error traps. Without a connection each call is a warning that cannot be fixed in the code and fails `ascot analyze`, so a CI gate or a coding agent that acts on warnings either drops the error trap or filters A3303 out, and then misses a real typo such as `^NOSUCH`.

## Version note

Reproduced on ascot v0.4.3 (macOS, universal binary) and v0.2.0.

- A3303 `CannotFindRoutine` was an error in v0.2.0 and became a warning in #76 (v0.3.0).
- `README.md` at v0.4.3 still says "a hint, not an error".
- With a connection this is already handled, from the source: since #78 (v0.3.0), `ascot declare` lists system routines too, and a routine IRIS has without source, such as `%ETN`, gets the A3794 hint. Not re-run with `--iris` here.
