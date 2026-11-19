## Summary

There is no way to turn a diagnostic code off, or to report only some codes. `analyze`, `analyze-workspace` and `lsp` take only `--iris`, `--iris-namespace` and `--style`, and the MCP `create_workspace` call takes only `iris`, `iris_namespace` and `style`. There is no config file and no suppression comment.

The `ascot-lsp` Claude Code plugin starts `ascot lsp` with no arguments (`"args": ["lsp"]`), so even those three options cannot reach it.

Diagnostic codes were added (#62, #69, #67) so that clients can filter by kind. Here the clients are the ascot CLI and the bundled plugin, and neither can filter.

## Repro

`src/DEMO.mac`:

```objectscript
ROUTINE DEMO
DEMO ; sample legacy routine
 Q
SHOW(V) ; print a value
 W V,!
 Q
RUN ; caller passes by reference to a normal parameter (legal, and common in old code)
 S X=1
 D SHOW(.X)
 Q
```

```sh
ascot analyze src
ascot analyze --ignore A5579 src     # also tried --disable, --select, --allow
echo '{"ignore":["A5579"]}' > style.json && ascot analyze --style style.json src
```

A trailing comment such as `; ascot-ignore A5579` on line 9 changes nothing.

## Actual (v0.4.3 output; v0.2.0 prints the same)

```text
$ ascot analyze src
warning: src/DEMO.mac:9:9-11 - The parameter 'V' is declared as a normal parameter but got a by-ref argument [A5579]
- src/DEMO.mac:4:6-7: Parameter declared here — add `&` (routine label) or `ByRef` (method) to declare it by-ref.
1 diagnostic(s) across 1 file(s)
exit=1
$ ascot analyze --ignore A5579 src
error: unexpected argument '--ignore' found
exit=2
$ ascot analyze --style style.json src
--style: style.json: unknown field `ignore`
exit=1
```

The LSP has the same gap, and it also reaches files the edit did not touch. A second workspace, `src/DEMO.mac`:

```objectscript
ROUTINE DEMO
DEMO ; sample routine
 Q
GET(ID) ; return a value
 Q ID_"!"
SHOW(V) ; print a value
 W V,!
 Q
```

and `src/Demo/Sample.cls`, which calls it:

```objectscript
Class Demo.Sample
{

ClassMethod Run() As %String
{
    set x = 1
    do SHOW^DEMO(.x)
    quit $$GET^DEMO(x)
}

}
```

A stdio client that opens `Sample.cls`, opens `DEMO.mac`, then sends full-text `didChange` notifications for `DEMO.mac` only, receives:

```text
didOpen   src/Demo/Sample.cls           -> Sample.cls: 1 [A5579]
didChange src/DEMO.mac (comment only)   -> DEMO.mac: 0, Sample.cls: 1 [A5579]
didChange src/DEMO.mac (rename GET)     -> DEMO.mac: 0, Sample.cls: 2 [A6851, A5579]
```

The A6851 (a caller broken in another file) is the useful part. The A5579 comes back after every edit of `DEMO.mac`, and nothing can turn it off.

## Expected

A way to choose which codes are reported, the same for the CLI, the LSP and the MCP `create_workspace` call. For example:

- `--ignore A5579,A4043` and `--select …` on `analyze`, `analyze-workspace` and `lsp`.
- A project file at the workspace root (for example `.ascot.json`) that every command reads. It would hold the code lists, the style rules and a declaration-file path. The plugin could then stay argument-less. Another route for the LSP: read the same settings from `initializationOptions` or `workspace/didChangeConfiguration`. Claude Code `lspServers` entries can send both, and can substitute `${user_config.KEY}` values into `args` and `env`.
- Optionally, a baseline: a file of accepted findings (for example written by `ascot analyze --write-baseline`), after which only new findings are reported. The LSP would apply it to dependent files too.
- Optionally, a per-line comment that accepts one finding.
- In the LSP, it would also help to skip republishing a dependent file whose diagnostics have not changed since the last publish (the comment-only edit above).

## Why it matters

On legacy code some rules fire on legal idioms that nobody will rewrite, so teams need to silence a code, not the whole tool. With the LSP plugin, Claude Code puts the errors and warnings the server reports into a coding agent's context after each edit, and an agent tends to act on what it is told. Today the practical workaround is to skip the plugin and filter the CLI's text output against an allowlist of codes.

## Version note

Reproduced on ascot v0.4.3 (macOS, universal binary) and v0.2.0.

In v0.4.3, `ascot help` and the `--help` of `analyze`, `analyze-workspace` and `lsp` list no option to select or suppress codes, and the plugin manifest (version 0.4.3) is still `"args": ["lsp"]`. On main (aedf33f, 2026-10-30), `src/main.rs` still defines only `IrisArgs` and `StyleArgs`, and `src/lsp.rs` does not read `initializationOptions` or configuration.
