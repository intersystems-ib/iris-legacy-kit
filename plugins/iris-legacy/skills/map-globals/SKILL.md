---
name: map-globals
description: Map how a legacy IRIS application stores its data in globals - every application global, its $PIECE fields, sub-nodes, index globals and the code that keeps them in step - from a static global map of the source, checked against the live data, and written down as a project skill that later sessions start from. Use when asked how data is stored, which code reads or writes a global, to document the data model, before changing code that sets, kills or indexes globals, or to refresh an existing globals skill after code changes.
---

# Map the globals, then write them down

A legacy system's data model lives in its code: `SET ^CUST(ID)=NAME_U_COUNTRY_...` is the
schema. This skill turns the code and the live data into a project skill, so every later
session starts with the model instead of re-reading the routines.

## 1. The static map

From the project root:

```bash
CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR}" "${CLAUDE_PLUGIN_ROOT}/scripts/globalmap.sh" --summary
```

It lists, for the project's source directories: every global with its node shapes (literal
subscripts kept, `*` for the rest), the operations on it and the `$PIECE` positions read and
set, with the routine:label or class:method of each; naked references with what each resolves
to (and how sure it is); indirect references; locks. `--global NAME` gives one global with every
reference, `--json` everything. Needs `uv`; the grammar comes from the kit's checked install.

The map is static: it does not see a global reached through a local copy
(`S X=^G(1) ... $P(X,U,2)`), through another routine's parameters, or built at run time
(`@NAME`, `XECUTE`). Read the code for those, starting from the labels the map names.

## 2. Read the writers

For each application global, read the labels that `set` and `kill` it: they define what the
nodes mean. Note for each record node:

- what each piece holds, its type and format (a `$H` date, an amount, a code from a table, an id
  from a counter), and its allowed values (status codes and what sets them);
- the sub-nodes (`^ORD(id,"L",n)`) and what each holds;
- the index globals, their key shape, and **which labels keep them in step** (nothing in the
  database does it: each writer updates its indexes itself, or forgets to);
- the counters (`$INCREMENT`, `$$NEXT`-style labels) and whether ids are reused;
- locks and transactions around the writes.

Leave out what the application only uses in passing (`^TMP`, `^CacheTemp*`, `^%*`, `^ROUTINE`,
`^rOBJ`, `^ERRORS`), unless the task is about them.

## 3. Check it against the live data

Read a few nodes of each global with `iris_global` if the server has it, otherwise
`iris_execute` with `$ORDER`, `$GET` and `$DATA`, a few nodes at a time, read only:

```objectscript
set id="" for i=1:1:3 { set id=$order(^GLOBAL(id),1,v) quit:id=""  write id," = ",v,! }
```

- Confirm every piece position and format from step 2 on real records.
- Count, and compare: records against index entries, in both directions (every index entry
  points at a record; every record has its entries). A difference is either a bug or a rule you
  have not found yet.
- List the codes that actually occur in a status piece.
- Never write or kill application data to find out.

## 4. Write the project skill

Write `.claude/skills/<app>-globals/SKILL.md` (Claude Code asks permission for files under
`.claude/`: say what you are writing and why). The shape that works:

- Front matter: `name`, and a `description` that names every global and says when to use it
  (before reading or writing the data, before changing code that sets, kills or indexes them,
  when writing tests against the data).
- A short preamble: when and against what data it was checked, and that the code is the
  authority. Point back to this skill to refresh it.
- **Conventions**: delimiter (`U="^"`), date format, amounts (stored as strings with trailing
  zeros? compare with `+x=+y`), id counters, how to test existence (`$D(x)#2`).
- One section per global or group: a node table (node, value as `p1 ... ^ p2 ...`), the codes
  per piece, the sub-nodes, the indexes, the writers with what each one changes, the readers.
- **What each event changes**: creating, updating, cancelling, deleting one record, as a list of
  every node touched, so a change that forgets an index is visible.
- **Questions and suspected defects**: what does not add up (an index a delete forgets, a
  status no code sets, a piece written in two formats). Mark them as suspected; do not fix them
  here.

Keep it to what a later session needs to read or change the data correctly. When the code
changes, re-run `--global NAME` for the globals it touches and update their sections.
