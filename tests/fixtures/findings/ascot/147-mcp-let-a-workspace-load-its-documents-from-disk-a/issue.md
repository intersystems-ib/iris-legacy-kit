## Summary

The MCP `insert` tool needs the full text of every document in `src`. `uri` is only a name: ascot does not read the file. The `insert` description says to "insert every related file, not just the one you're editing", because cross-file references are resolved only against the workspace. So, for cross-file checks, an agent has to read every routine and class in the project and paste them into tool arguments. The CLI (`analyze-workspace`) and the LSP already read the workspace from disk.

`tools/list` is also large: about 28 kB of JSON. Of that, 15.4 kB is the `Style` definition inlined into `create_workspace`, with one property per command and function keyword (195 in all).

## Repro

Any `.mac` file, here `src/DEMO.mac`:

```
ROUTINE DEMO
DEMO ;
 G NOPE
```

Start `ascot mcp` from the folder that holds `src/`, then call:

```
tools/list
create_workspace {"workspace":"demo"}
insert {"workspace":"demo","files":[{"uri":"src/DEMO.mac"}]}
insert {"workspace":"demo","files":[{"uri":"src/DEMO.mac","src":""}]}
check  {"workspace":"demo","uris":["src/DEMO.mac"]}
```

## Actual (v0.4.3)

```
tools/list          -> 28,253 bytes. create_workspace input schema 17,120, of which $defs.Style 15,434.
                       All input schemas 21,085; output schemas 3,974; descriptions 2,518.
insert without src  -> "failed to deserialize parameters: missing field `src`" (isError: true)
insert with src ""  -> {"affected":["src/DEMO.mac"]}
check               -> A1727 "Syntax error ... parse error at byte 0, expected: RoutineHeader"
```

The file on disk is never read. Only pasting its text as `src` gives the real diagnostics (here A6851 for `G NOPE`). v0.2.0 behaves the same; its `tools/list` is 28,418 bytes.

## Expected

Either of these would remove the paste step:

- `create_workspace` takes a `root` and loads every `.cls`/`.mac`/`.int`/`.inc` under it, as `analyze-workspace` and `lsp` do.
- `insert` accepts `path` in place of `src`. Calling `insert` again with the same path re-reads the file after the agent edits it.

Either could be limited to a root given when the server starts (for example `ascot mcp --root DIR`), if reading arbitrary paths is a concern.

For `tools/list`: describe `style` as a plain object, with a link to the style documentation or one short example, instead of inlining all 195 keyword properties. Or take the path of a style file, as `--style` does for the CLI and LSP.

## Why it matters

An agent pays for every byte of source it pastes. For a legacy code base with hundreds of routines, pasting is impractical, so the cross-file checks that make ascot useful to an agent are out of reach over MCP. In clients that load tool schemas up front, 28 kB of schema (roughly 7,000 tokens) also takes up context in every session, even one that never calls ascot.

## Version note

Reproduced on ascot v0.4.3 (macOS, universal binary) and v0.2.0.

The release notes for v0.3.0 to v0.4.3 do not mention MCP inputs. In v0.4.3, `ascot mcp` still takes no options (`ascot mcp --root DIR` gives "unexpected argument '--root' found"), and `FileToInsert` in `src/mcp.rs` on main (aedf33f) still has only `uri` and `src`. #66 (closing #65) documented the tools but did not change their inputs. #123 lets a host swap a workspace's style or server, through the library and JS API only.
