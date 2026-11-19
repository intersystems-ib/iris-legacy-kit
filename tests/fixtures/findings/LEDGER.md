# Findings ledger (test fixture)

The kit owner's ledger, in the format `report.sh` reads through `IRIS_LEGACY_FINDINGS`, cut down
for `tests/report.sh`. The twelve ascot issues are real and public (filed 2026-10-31, all fixed in
ascot 0.5.0), each with its posted text in `ascot/<number>-<slug>/issue.md`. The open candidate is
invented for the test.

## Filed

| Filed | Tool | Issue | Title | Verified on; fixed in |
| --- | --- | --- | --- | --- |
| 2026-10-31 | ascot | [#136](https://github.com/intersystems-community/ascot/issues/136) | Checking and --style stop for the rest of a label after a stand-alone ELSE or an argumentless DO (A4043) | 0.4.3, 0.2.0; fixed in 0.5.0 |
| 2026-10-31 | ascot | [#137](https://github.com/intersystems-community/ascot/issues/137) | The first diagnostic in a label or method stops the rest of its body from being checked | 0.4.3, 0.2.0; fixed in 0.5.0 |
| 2026-10-31 | ascot | [#138](https://github.com/intersystems-community/ascot/issues/138) | Label+offset targets (`GOTO LABEL+n`, `DO LABEL+n`) are not resolved | 0.4.3, 0.2.0; fixed in 0.5.0 |
| 2026-10-31 | ascot | [#139](https://github.com/intersystems-community/ascot/issues/139) | WRITE `?expr`, `*expr` and `*-expr` arguments are not checked | 0.4.3, 0.2.0; fixed in 0.5.0 |
| 2026-10-31 | ascot | [#140](https://github.com/intersystems-community/ascot/issues/140) | A5579 warns on every `.var` argument to a plain formal parameter | 0.4.3, 0.2.0; fixed in 0.5.0 |
| 2026-10-31 | ascot | [#141](https://github.com/intersystems-community/ascot/issues/141) | A5718 on a by-reference parameter that is killed before it is filled | 0.4.3, 0.2.0; fixed in 0.5.0 |
| 2026-10-31 | ascot | [#142](https://github.com/intersystems-community/ascot/issues/142) | Status macros in a class reported undefined (A2797) without --iris | 0.4.3, 0.2.0; fixed in 0.5.0 |
| 2026-10-31 | ascot | [#143](https://github.com/intersystems-community/ascot/issues/143) | A call to `^%ETN` without IRIS is a warning; the README says hint | 0.4.3, 0.2.0; fixed in 0.5.0 |
| 2026-10-31 | ascot | [#144](https://github.com/intersystems-community/ascot/issues/144) | No diagnostic for superseded $ZUTIL calls | 0.4.3, 0.2.0; fixed in 0.5.0 |
| 2026-10-31 | ascot | [#145](https://github.com/intersystems-community/ascot/issues/145) | Select or suppress diagnostic codes, in the CLI, the LSP and the ascot-lsp plugin | 0.4.3, 0.2.0; fixed in 0.5.0 |
| 2026-10-31 | ascot | [#146](https://github.com/intersystems-community/ascot/issues/146) | Machine-readable output for `ascot analyze` (JSON, SARIF) | 0.4.3, 0.2.0; fixed in 0.5.0 |
| 2026-10-31 | ascot | [#147](https://github.com/intersystems-community/ascot/issues/147) | MCP: load documents from disk, shrink the tools/list schema | 0.4.3, 0.2.0; fixed in 0.5.0 |

## Open candidates

- iris-interop-dev: the MCP server's routine search returns no match for a label that sits on the
  last line of a routine with no line break after it. Invented for the test. Not drafted yet.
