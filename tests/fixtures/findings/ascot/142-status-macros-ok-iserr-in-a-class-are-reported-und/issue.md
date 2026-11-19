## Summary

Without `--iris`, every use of a standard status macro in a class with no `Include` is reported as error A2797 "The macro '...' is undefined". IRIS compiles these classes without errors, because every class gets the `%systemInclude` closure implicitly. Without IRIS, ascot cannot read that include, and it reports an error instead of leaving the macro unconfirmed.

This is not #49. That issue was a wrong `--iris-namespace`, fixed by #48's connection check. This one is the default mode with no `--iris`. Per the README, it is also the only mode of the `ascot-lsp` plugin.

## Repro

`Demo/Sample.cls`:

```objectscript
Class Demo.Sample Extends %RegisteredObject
{

ClassMethod A() As %Status
{
    quit $$$OK
}

ClassMethod B(sc As %Status) As %Boolean
{
    quit $$$ISOK(sc)
}

ClassMethod C(sc As %Status) As %Boolean
{
    quit $$$ISERR(sc)
}

ClassMethod D(sc As %Status)
{
    $$$ThrowOnError(sc)
}

ClassMethod E(sc As %Status)
{
    $$$ThrowStatus(sc)
}

ClassMethod F() As %Status
{
    quit $$$ERROR(5001, "demo")
}

}
```

```sh
ascot analyze Demo/Sample.cls
```

## Actual (v0.4.3)

```
error: Demo/Sample.cls:6:10-15 - The macro 'OK' is undefined [A2797]
error: Demo/Sample.cls:11:10-21 - The macro 'ISOK' is undefined [A2797]
error: Demo/Sample.cls:16:10-22 - The macro 'ISERR' is undefined [A2797]
error: Demo/Sample.cls:21:5-24 - The macro 'ThrowOnError' is undefined [A2797]
error: Demo/Sample.cls:26:5-23 - The macro 'ThrowStatus' is undefined [A2797]
error: Demo/Sample.cls:31:10-32 - The macro 'ERROR' is undefined [A2797]
6 diagnostic(s) across 1 file(s)
```

Exit code 1. v0.2.0 gives the same output. Adding `Include %occStatus` does not help offline. It adds `error: ... Include file '%occStatus' is not defined in the current workspace [A7831]` and keeps the A2797.

The false error also hides real ones. Only the first error in a method is reported, so a real mistake after `$$$OK` in the same method is lost:

```objectscript
Class Demo.Masked Extends %RegisteredObject
{

ClassMethod Add(a, b) As %Integer
{
    quit a + b
}

/// A real mistake after $$$OK: Add takes two arguments.
ClassMethod WithMacro() As %Status
{
    set sc = $$$OK
    set x = ..Add(1, 2, 3)
    quit sc
}

/// The same mistake without the macro.
ClassMethod WithoutMacro() As %Status
{
    set sc = 1
    set x = ..Add(1, 2, 3)
    quit sc
}

}
```

```
error: Demo/Masked.cls:12:14-19 - The macro 'OK' is undefined [A2797]
error: Demo/Masked.cls:21:25-26 - Too many arguments [A5523]
2 diagnostic(s) across 1 file(s)
```

Line 13 has the same mistake as line 21, but nothing is reported for it.

## Expected

When there is no IRIS connection to ask, a macro that could come from the implicit class includes should be left unconfirmed: a hint, not an error. That is what the README describes for classes and routines outside the workspace ("left unconfirmed (a hint, not an error)"), and what A1054 does for classes. One option is to bundle the names (or definitions) of the common `%systemInclude` macros. The same reasoning could apply to A7831 for a system include file (`%`-prefixed) when there is no connection. `ascot help analyze` already says this of `--iris`: "Resolves the classes, include files and routines outside the workspace; without it, they are left unconfirmed."

In a routine, `$$$OK` with no `#include` should still be A2797, because a routine gets no implicit includes.

## Why it matters

Almost every class written for IRIS uses `$$$OK`, so offline analysis and the `ascot-lsp` plugin report errors on correct code. Agents that act on diagnostics may "fix" this by adding includes or replacing `$$$OK` with `1`. Filtering A2797 by macro name does not help, because the real errors later in the same method are never reported.

## Version note

Reproduced on ascot v0.4.3 (macOS, universal binary) and v0.2.0.
