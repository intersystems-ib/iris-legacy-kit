## Summary

In a WRITE command, only plain expression arguments are checked. The expression after `?` (tab), `*` (character code) and `*-` (device control) is skipped. As a result:

- A7155 (left-to-right precedence) is not reported inside `?(...)`.
- An undefined variable or a missing label inside these arguments is not reported.
- A variable read only inside `?(...)` is reported as "assigned but never read" (A5718).

## Repro

`DEMO.mac` (one case per label):

```objectscript
ROUTINE DEMO
DEMO ; WRITE ?expr and *expr arguments, one case per label
    quit
PLAIN(n) public {
    write n - 1 * 12, !
    quit
}
TAB(n) public {
    write ?(n - 1 * 12), "x", !
    quit
}
TABUNDEF() public {
    write ?(undefinedcol), "x", !
    quit
}
TABLABEL() public {
    write ?$$NOSUCH(), "x", !
    quit
}
CHARUNDEF() public {
    write *undefinedchar
    quit
}
OLD(N) W ?(N-1*12),"x",!
    Q
```

```
ascot analyze DEMO.mac
```

## Actual

```
warning: DEMO.mac:5:11-21 - ObjectScript has no operator precedence and evaluates strictly left-to-right; this may not compute what you expect [A7155]
warning: DEMO.mac:8:5-6 - Variable 'n' is assigned but never read [A5718]
warning: DEMO.mac:24:5-6 - Variable 'N' is assigned but never read [A5718]
3 diagnostic(s) across 1 file(s)
```

The same file with `?` and `*` removed (so each expression is a plain WRITE argument) gives A7155 on lines 9 and 24, A7095 on lines 13 and 21, and A6851 on line 17.

`write *-nosuch` and `write /CUP(nosuch, 1)` give no diagnostic either, while `write nosuch` gives A7095.

## Expected

The expressions inside `?`, `*` and `*-` are checked like any other WRITE argument: A7155 on lines 9 and 24, A7095 on lines 13 and 21, A6851 on line 17, and no A5718 on lines 8 and 24.

## Likely cause

In `src/check/mod.rs`, the `Command::Write` arm only handles `WriteArg::Expr`:

```rust
if let cos::WriteArg::Expr(expr) = arg {
    let _ = expr.to_ty(env, flow)?;
}
```

`WriteArg::Fmts` (which holds `WriteFChar::Tab(_, Expr)` and the `/mnemonic(...)` parameters), `WriteArg::Dev` and `WriteArg::Char` are never visited. The `MVP`/`MVC` arm uses the same filter.

## Why it matters

Column arithmetic such as `W ?(COL-1*12)` is common in old report routines, and that is where the left-to-right rule most often matters. An agent that sees "assigned but never read" on a parameter used only in a tab position may remove it.

## Version note

Reproduced on ascot v0.4.3 (macOS, universal binary) and v0.2.0.

The output is the same on both.
