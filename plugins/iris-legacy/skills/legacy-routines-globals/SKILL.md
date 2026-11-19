---
name: legacy-routines-globals
description: Read, debug and change legacy ObjectScript routines (.mac/.int) and the globals that hold their data. Covers abbreviated commands, dot syntax, $PIECE records, naked references, $ORDER/$DATA/$QUERY loops, LOCK, transactions, $TEST, GOTO/DO LABEL+n, $TEXT tables, XECUTE and indirection, and symbol-table parameters. Use before explaining, fixing or refactoring routine code, or when reading ^globals.
---

# Legacy routines and globals

Legacy routine code is correct only in context: which global node was touched last, which
locals the caller set, which lines sit below a label. Most defects here compile cleanly. Read
for those contexts before changing anything.

## Workflow

1. **Map before you change.** For each global the code touches, list which labels set, kill and
   read it, the record layout (which `$PIECE` is which field) and the index globals that must
   change with it. Comments in routine headers sometimes document a layout; the code is the
   authority. The `iris-legacy:map-globals` skill does this for the whole application.
2. **Reproduce** with the real data: call the label through `iris_execute`, read the error log,
   look at the nodes involved.
3. **Characterize.** Write a `%UnitTest` that pins today's behaviour, including the behaviour
   you are about to fix, and see it pass on the unchanged code (the `iris-legacy:characterize`
   skill: interface, template with output capture and terminal input, proving the tests bite).
4. **Change the minimum**, in the style of the surrounding code.
5. **Verify:** the hook compiles; tests pass; data and indexes are still consistent (for example,
   every index entry points at an existing record, and every record has its index entries).

## Reading the syntax

- Commands abbreviate to their first letter: `S`et, `K`ill, `Q`uit, `D`o, `G`oto, `I`f, `E`lse,
  `F`or, `N`ew, `W`rite, `R`ead, `L`ock, `M`erge, `X`ecute, `H`alt/`H`ang, `TS`tart, `TC`ommit,
  `TRO`llback. Functions too: `$P`iece, `$E`xtract, `$L`ength, `$G`et, `$D`ata, `$O`rder,
  `$Q`uery, `$S`elect, `$J`ustify, `$H`orolog.
- `$T` alone is `$TEST`; `$T(...)` is `$TEXT`.
- Postconditionals: `Q:X=""` means quit if `X=""`; `D:ok LABEL`, `S:cond Y=1`.
- An argumentless command is followed by **two** spaces: `F  S X=$O(^G(X)) Q:X=""  D`.
- **Dot syntax:** an argumentless `D` at the end of a line runs the following lines that have one
  more leading `.`. A `Q` inside the dotted block leaves the block only, not the label.
- **No operator precedence:** strictly left to right. `2+3*4` is 20; write `2+(3*4)`.
  `'` is not, `!` or, `&` and, `_` concatenation, `[` contains, `]` sorts after, `?` pattern
  match, `'<` is "not less than".
- `=` compares as strings: `"1.0"=1` is false, `+"1.0"=1` is true.

## Globals: `$DATA`, `$ORDER`, `$QUERY`

- `$D(node)`: 0 nothing, 1 value only, 10 children only, 11 value and children.
  "Has a value" is `$D(node)#2`, "has children" is `$D(node)\10` (or `>1`). A test such as
  `$D(node)=1` silently rejects nodes that also have children.
- `$O` loop: `S X="" F  S X=$O(^G(X)) Q:X=""  ...`. Reverse with `$O(^G(X),-1)`; `$O(^G(X),1,val)`
  also fetches the value.
- Loop ends: `Q:X=""` stops at the end. `Q:'X` also stops at any subscript whose numeric value
  is 0: subscript 0, or a string that does not start with a non-zero number. So string
  subscripts after the numbers are never visited. For range loops,
  check whether the bound is meant to be inclusive: `Q:X>TO` keeps `TO`, `Q:X'<TO` drops it.
- `$Q(^G)` walks every node with data, depth first; `$QS(ref,n)` takes subscript *n* of the
  returned reference, `$QL(ref)` counts subscripts.
- `$G(node,default)` avoids `<UNDEFINED>`. `K ^G(x)` kills the whole subtree; `ZK` kills one
  node and keeps its children; `M ^A(x)=^B(y)` copies a subtree.
- Subscripts: canonical numbers collate first, in numeric order, then strings. `^G("1")` is the
  same node as `^G(1)`; `^G("01")` and `^G("1.0")` are different string subscripts.

## Naked references

`^(sub)` means "the last global reference this process executed, with its last subscript
replaced by `sub`". Every global reference updates that state, including references inside
`$D`, `$O`, `$G` and `$Q`, and those made by any code called in between. Inserting a line
between the full reference and the naked one silently retargets the naked one, with no compile
error. When you edit near a naked reference, replace it with the full reference.

## `$PIECE` records and indexes

- A record is one string with fields at fixed positions: `$P(^G(id),U,3)`, where the delimiter is
  often the public variable `U="^"`. `S $P(^G(id),U,3)=v` reads, modifies and writes the node:
  under concurrency it needs a lock.
- Index globals (values `""`) are kept in step by hand. Every path that sets, changes or kills a
  record must update every index that mentions it. Check delete paths especially.

## `LOCK`, transactions and `$TEST`

- `L +^G(id):5` waits up to 5 seconds and sets `$T`: always test it (`E  Q 0` or `I '$T`).
  `L +^G(id)` without a timeout waits forever.
- `L ^G(id)` **without `+`** first releases every other lock the process holds. `L` alone
  releases all of them.
- `TS` starts a transaction (`$TLEVEL` goes up). **Every** exit path, including early quits
  after a failed lock and error traps, needs `TC` or `TRO`. An open transaction is rolled back
  when the process ends, so a forgotten one silently loses the work done after it.
- Inside a transaction, `L -^G(id)` takes effect only at `TC`/`TRO`.
- `$T` is set by `I` and by timed `L`, `R`, `O` and `J`. `E` tests whatever set `$T` last.
  `D LABEL` does **not** restore `$T`; an argumentless `D` block and a `$$` call do.

## Line positions: `LABEL+n` and `$TEXT`

- `G LABEL+3`, `D LABEL+3` and `$T(LABEL+3)` address lines by offset. Adding or removing a line
  between `LABEL` and the target changes what runs, again with no compile error. Before
  editing a label's body, search every routine for `LABEL+`. When refactoring, give the target
  its own label.
- Offsets count lines of the compiled `.int`, which drops blank lines, so `.mac` and `.int`
  numbering can differ. An error location such as `LABEL+4^RTN` uses the same count: read it
  against the `.int` (`iris_doc` with `RTN.int`), not the `.mac`.
- `$TEXT` tables keep data in comment lines (`;;CODE;Description`) read in a loop by
  `$T(TABLE+i)`. Editing those lines edits data.

## Parameters through the symbol table

- Labels without a formal list read their inputs from, and leave their outputs in, the caller's
  local variables (often documented as `; in: X  out: ERR`). Read the label to find them.
- Lists are often returned in `^TMP($J,...)`: kill that subtree before filling it, and after
  use.
- Class methods are procedure blocks: their locals are private, so a method that calls such a
  label must list the variables in `[ PublicList = (...) ]` and `new` them.
- Code held in data: `X` (`XECUTE`), `@` indirection and `D @RTN`. A search for callers misses
  these; grep for `X ` and `@` too.

## Characterization tests

The `iris-legacy:characterize` skill has the workflow and a template class with helpers for
printed output and terminal input. In short: run tests against known data (a reset script that
regenerates the same data every time, or records the test creates and removes itself), list the
locals a label reads in the test method's `PublicList` and `NEW` them, and check `$TLEVEL=0`
after calling code that uses transactions.

## Deprecated calls

`$ZU(n)` functions are deprecated (for example `$ZU(5)`, use `$NAMESPACE`). Replace them when
you touch the line, not as a sweep.
