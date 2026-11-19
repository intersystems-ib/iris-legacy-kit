## Summary

`analyze` and `analyze-workspace` print text only. One diagnostic can span many lines: related information and the token list of a syntax error. On a terminal the `error:`/`warning:` prefix is replaced by a color, so the layout also depends on whether stdout is a TTY. Scripts and CI have to parse that text.

## Repro

`src/DEMO.mac`:

```objectscript
ROUTINE DEMO
DEMO ; sample legacy routine
 Q
SHOW(V) ; print a value
 W V,!
 Q
RUN ; caller passes by reference to a normal parameter
 S X=1
 D SHOW(.X)
 Q
```

`src/DEMOB.mac`:

```objectscript
ROUTINE DEMOB
DEMOB ; sample routine with an unbalanced parenthesis
 K ^TMP(1
 Q
```

```sh
ascot analyze --format json src      # also tried --json, --output-format sarif, --message-format json
ascot analyze src > stdout.txt 2> stderr.txt
```

## Actual (v0.4.3 output; v0.2.0 prints the same)

```text
$ ascot analyze --format json src
error: unexpected argument '--format' found
exit=2
$ ascot analyze src > stdout.txt 2> stderr.txt
exit=1
--- stdout:
warning: src/DEMO.mac:9:9-11 - The parameter 'V' is declared as a normal parameter but got a by-ref argument [A5579]
- src/DEMO.mac:4:6-7: Parameter declared here — add `&` (routine label) or `ByRef` (method) to declare it by-ref.
warning: src/DEMOB.mac:4:2-3 - Syntax error, looking for:
parse error at byte 32, expected:
	- "#"
	- "'"
	- ")"
	- ","
	- "?"
	- "\n"
	- Char of not line breaking whitespace
	- LineComment
	- Operator
	- RangeComment
 [A1727]
--- stderr:
2 diagnostic(s) across 2 file(s)
```

Two diagnostics take 15 lines. Only one of them matches the one-line form `severity: file:line:col-col - message [code]`. Under a pseudo-terminal (`script -q /dev/null ascot analyze src/DEMO.mac`), the line starts with `ESC[38;5;214m` instead of `warning: `.

## Expected

- `--format json`: one JSON document on stdout with the same records the MCP `check` tool returns (`files[].uri`, `files[].diagnostics[]` with code, code description, range, severity, message and related information).
- `--format sarif`: SARIF 2.1.0, so a CI job can upload it as code-scanning results.
- The text format stays the default, and exit codes do not change.

## Why it matters

CI gates, editor problem matchers and coding-agent hooks need to filter by code and by file, especially while ascot has no way to select or suppress codes itself. Today they need a parser that joins continuation lines and depends on the current text layout. A layout change would silently break the gate.

## Version note

Reproduced on ascot v0.4.3 (macOS, universal binary) and v0.2.0.

In v0.4.3, `ascot help` and the `--help` of `analyze` and `analyze-workspace` list no output-format option. On main (aedf33f, 2026-10-30), `report_diagnostics` in `src/main.rs` still prints the uri plus `Diagnostic::describe()` (`src/bindings.rs`), colored on a terminal. `Diagnostic` already derives `serde::Serialize` (the `wit_bindgen` `additional_derives` in `src/bindings.rs`), and `src/mcp.rs` serializes it as `DiagnosticsResult`, so the JSON shape already exists.
