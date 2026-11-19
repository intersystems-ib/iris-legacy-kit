# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "tree-sitter==0.26.0",
# ]
# ///
"""globalmap: which code touches which global, and how.

Parses ObjectScript routines (.mac/.int/.inc, routine grammar) and classes (.cls, UDL
grammar) with tree-sitter-objectscript and lists every global reference as

    routine (or class) -> label (or method) -> global reference -> operation

with a subscript pattern for each reference (literal subscripts kept, variables by name)
and the $PIECE used, when the reference sits inside $PIECE.

Usage, through the kit's wrapper (it supplies the pinned grammar and the project's source
directories; run from anywhere in the project):

    scripts/globalmap.sh                     # Markdown for the configured source directories
    scripts/globalmap.sh --json              # the same as JSON
    scripts/globalmap.sh --global CUST       # only ^CUST
    scripts/globalmap.sh --summary           # only the per-global summary
    scripts/globalmap.sh path/to/dir_or_file ...

The grammar (tree-sitter-objectscript) is not a dependency of this script: the wrapper puts the
copy that setup.sh installed and checked on PYTHONPATH, so versions.json stays the only pin.

Operations: set, kill, read, xecute (the node's value is run as code), $order, $data,
$get, $query, $increment, merge-to, merge-from, lock+, lock-, lock (plain LOCK, which
also releases every other lock the process holds).

Naked references (^(...)) are resolved statically against the previous global reference
in the same label, in evaluation order (in a SET, the right-hand side first). The result
is an estimate: the naked indicator is set at run time by whatever global reference
executed last, so a call, XECUTE, GOTO or loop between the two references can change it.
Those cases are reported with confidence "low" and the reason. LOCK and $NAME are
assumed not to move the naked indicator.

Indirect references (@X) cannot be resolved statically; the map lists them with the
global names that appear as string literals in the same label, as candidates.

Static analysis only: it does not see globals reached through local copies
(S X=^G(1) ... $P(X,U,2)), through other routines' parameters, or built at run time.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from pathlib import Path

from importlib import metadata

try:
    import tree_sitter_objectscript_routine as ts_routine
    import tree_sitter_objectscript_udl as ts_udl
except ImportError:
    sys.exit("globalmap: the tree-sitter-objectscript grammar is not on PYTHONPATH; run it through scripts/globalmap.sh")
from tree_sitter import Language, Node, Parser

GRAMMAR = f"tree-sitter-objectscript {metadata.version('tree-sitter-objectscript')}"

ROUTINE_LANG = Language(ts_routine.language_objectscript_routine())
UDL_LANG = Language(ts_udl.language_objectscript_udl())
ROUTINE_EXT = {".mac", ".int", ".inc", ".rtn"}

# Intrinsic functions, keyed by every spelling, mapped to a canonical name.
FN_ALIASES = {
    "O": "$order", "ORDER": "$order",
    "D": "$data", "DATA": "$data",
    "G": "$get", "GET": "$get",
    "Q": "$query", "QUERY": "$query",
    "I": "$increment", "INCREMENT": "$increment",
    "NA": "$name", "NAME": "$name",
    "P": "$piece", "PIECE": "$piece",
    "E": "$extract", "EXTRACT": "$extract",
    "LI": "$list", "LIST": "$list",
    "QS": "$qsubscript", "QSUBSCRIPT": "$qsubscript",
    "QL": "$qlength", "QLENGTH": "$qlength",
}
ACCESS_FNS = {"$order", "$data", "$get", "$query", "$increment"}
WRAPPER_FNS = {"$piece", "$extract", "$list", "$get"}
NO_NAKED_UPDATE = {"lock+", "lock-", "lock", "$name"}
DELIM_VARS: dict[str, set[str]] = defaultdict(set)  # variables set to a one-character string


@dataclass
class Ref:
    file: str
    unit: str            # routine or class name
    label: str           # label, procedure or method ("" before the first label)
    line: int
    col: int
    text: str            # the reference as written
    glob: str            # global name without ^, "" when naked or indirect
    subs: list[str]      # rendered subscripts
    pattern: str         # ^NAME(sub,sub) with variables by name
    shape: str           # ^NAME("lit",*) with variables as *
    op: str
    piece: str = ""      # $PIECE number(s) when wrapped in $PIECE
    delim: str = ""      # the $PIECE delimiter as written
    naked: bool = False
    resolved: str = ""   # for naked refs: the full reference it resolves to
    confidence: str = ""  # for naked refs: high / low
    notes: list[str] = field(default_factory=list)
    source: str = ""     # the source line, trimmed
    value: str = ""      # for a SET of the whole node: the right-hand side as written
    record: list[str] = field(default_factory=list)  # that value split into $PIECE fields


def node_text(src: bytes, n: Node) -> str:
    return src[n.start_byte:n.end_byte].decode("utf-8", "replace")


def fn_name(src: bytes, n: Node) -> str:
    m = re.match(r"\$([A-Za-z]+)", node_text(src, n))
    if not m:
        return ""
    return FN_ALIASES.get(m.group(1).upper(), "$" + m.group(1).lower())


def method_args(n: Node) -> list[Node]:
    return [c for c in n.children if c.type == "method_arg"]


def render_sub(src: bytes, n: Node) -> tuple[str, bool]:
    """(rendered subscript, is_literal)"""
    t = node_text(src, n).strip()
    inner = n
    while inner.type in ("method_arg", "expression") and inner.named_child_count == 1:
        inner = inner.named_children[0]
    if inner.type == "string_literal" and t != '""':
        return t, True
    if len(t) <= 16:
        return t, False
    m = re.match(r"(\$\$?[A-Za-z%^0-9]+)\(", t)
    return (m.group(1) + "(…)" if m else t[:14] + "…"), False


class Mapper:
    def __init__(self) -> None:
        self.refs: list[Ref] = []

    # ---- per file ------------------------------------------------------------
    def map_file(self, path: Path, rel: str) -> None:
        src = path.read_bytes()
        is_cls = path.suffix.lower() == ".cls"
        tree = Parser(UDL_LANG if is_cls else ROUTINE_LANG).parse(src)
        self.src, self.rel, self.lines = src, rel, src.decode("utf-8", "replace").split("\n")
        self.unit = path.stem
        self.label = ""
        self.last: Ref | None = None      # last global reference, for naked resolution
        self.between: list[str] = []      # control transfers since that reference
        self.literals: dict[str, list[str]] = defaultdict(list)  # label -> "^NAME" strings
        self.pending_indirect: list[tuple[Ref, str]] = []
        for n in self.walk_nodes(tree.root_node):
            if n.type == "routine_name" and n.parent and n.parent.type == "routine_definition":
                self.unit = node_text(src, n)
                break
            if n.type == "class_name":
                self.unit = node_text(src, n)
                break
        self.visit(tree.root_node)
        for ref, label in self.pending_indirect:
            cands = sorted(set(self.literals.get(label, [])))
            ref.notes.append("candidates from string literals in this label: " + ", ".join(cands) if cands
                             else "no global named in string literals in this label")

    @staticmethod
    def walk_nodes(n: Node):
        stack = [n]
        while stack:
            x = stack.pop()
            yield x
            stack.extend(reversed(x.children))

    # ---- traversal in evaluation order --------------------------------------
    def visit(self, n: Node) -> None:
        t = n.type
        if t == "tag_statement":
            self.enter_label(node_text(self.src, n.child_by_field_name("tag") or n.named_children[0]), reset=False)
        elif t == "procedure":
            tag = next((c for c in n.children if c.type == "tag"), None)
            self.enter_label(node_text(self.src, tag) if tag else "?", reset=True)
        elif t == "method_definition":
            name = next((c for c in n.children if c.type == "method_name"), None)
            self.enter_label(node_text(self.src, name) if name else "?", reset=True)
        elif t == "string_literal":
            s = node_text(self.src, n)
            if re.fullmatch(r'"\^[%A-Za-z][A-Za-z0-9.]*"', s):
                self.literals[self.label].append(s.strip('"'))
        elif t in ("command_do", "command_goto", "command_xecute", "command_job"):
            kw = n.children[0] if n.children else None
            has_target = any(c.type in ("do_parameter", "goto_argument", "xecute_argument") for c in n.children)
            if has_target:
                self.between.append(f"{node_text(self.src, kw) if kw else t} at line {n.start_point[0] + 1}")
        elif t == "extrinsic_function":
            self.between.append(f"$$ call at line {n.start_point[0] + 1}")
        elif t == "gvn":
            self.record(n)
        elif t == "set_argument":
            tgt = next((c for c in n.children if c.type == "set_target"), None)
            rhs = next((c for c in n.children if c.type == "expression"), None)
            if tgt is not None and rhs is not None and tgt.named_child_count == 1 and tgt.named_children[0].type == "lvn":
                m = re.fullmatch(r'"(.)"', node_text(self.src, rhs).strip())
                if m:
                    DELIM_VARS[node_text(self.src, tgt).strip()].add(m.group(1))
        elif t == "indirection":
            self.indirect(n)

        if t in ("set_argument", "merge_argument"):
            # the right-hand side is evaluated before the assignment to the left-hand side
            kids = [c for c in n.children if c.type != "set_target"] + [c for c in n.children if c.type == "set_target"]
        else:
            kids = n.children
        for c in kids:
            self.visit(c)

    def enter_label(self, name: str, reset: bool) -> None:
        self.label = name
        if reset:
            self.last = None
            self.between = []
        else:
            self.between.append(f"label {name} (entry point)")

    # ---- context of a reference ---------------------------------------------
    def context(self, n: Node) -> tuple[str, str, str, list[str]]:
        """(operation, piece, delimiter, notes) for a gvn or indirection node."""
        chain: list[tuple[str, Node]] = []
        cur = n
        while True:
            p = cur.parent
            if p is None:
                break
            if p.type == "expression":
                cur = p
                continue
            if p.type == "method_arg" and p.parent is not None and p.parent.type == "system_defined_function":
                args = method_args(p.parent)
                if args and args[0].id == p.id:
                    chain.append((fn_name(self.src, p.parent), p.parent))
                    cur = p.parent
                    continue
            break
        ctx = cur.parent
        notes: list[str] = []
        piece = delim = ""
        for fn, fnode in chain:
            if fn == "$piece":
                a = method_args(fnode)
                delim = node_text(self.src, a[1]).strip() if len(a) > 1 else ""
                piece = node_text(self.src, a[2]).strip() if len(a) > 2 else "1"
                if len(a) > 3:
                    piece += ":" + node_text(self.src, a[3]).strip()
                break
            if fn not in WRAPPER_FNS:
                break
        op = ""
        for fn, fnode in chain:
            if fn in ACCESS_FNS or fn == "$name":
                op = fn
                a = method_args(fnode)
                if fn in ("$order", "$query") and len(a) > 1 and node_text(self.src, a[1]).strip() == "-1":
                    notes.append("reverse direction")
                if fn == "$order" and len(a) > 2:
                    notes.append("also reads the value (3-argument $ORDER)")
                break
            if fn not in WRAPPER_FNS:
                op = "read"
                break
        if not op:
            if ctx is not None and ctx.type == "set_target":
                op = "merge-to" if ctx.parent is not None and ctx.parent.type == "merge_argument" else "set"
            elif ctx is not None and ctx.type == "kill_target":
                op = "kill"
            elif ctx is not None and ctx.type == "lock_arg":
                arg = ctx.parent
                mode = ""
                for c in arg.children:
                    if not c.is_named and node_text(self.src, c) in ("+", "-"):
                        mode = node_text(self.src, c)
                op = "lock" + mode
                if mode != "-":
                    has_to = any(c.type == "timeout" for c in arg.children)
                    notes.append("timeout" if has_to else "NO TIMEOUT")
            elif ctx is not None and ctx.type == "xecute_argument":
                op = "xecute"
            elif ctx is not None and ctx.type == "merge_argument":
                op = "merge-from"
            else:
                op = "read"
        return op, piece, delim, notes

    # ---- recording ------------------------------------------------------------
    def record(self, n: Node) -> None:
        src = self.src
        text = node_text(src, n)
        ident = next((c for c in n.children if c.type == "identifier"), None)
        args_node = next((c for c in n.children if c.type == "method_args"), None)
        subs_nodes = method_args(args_node) if args_node else []
        rendered = [render_sub(src, s) for s in subs_nodes]
        subs = [r for r, _ in rendered]
        glob = node_text(src, ident) if ident else ""
        naked = ident is None and text.startswith("^(")
        if not glob and not naked:
            m = re.match(r"\^(?:\|[^|]*\||\[[^\]]*\])?([%A-Za-z][A-Za-z0-9.]*)", text)
            glob = m.group(1) if m else ""
        op, piece, delim, notes = self.context(n)
        line = n.start_point[0] + 1
        ref = Ref(file=self.rel, unit=self.unit, label=self.label, line=line, col=n.start_point[1] + 1,
                  text=text, glob=glob, subs=subs, pattern="", shape="", op=op, piece=piece, delim=delim,
                  naked=naked, notes=notes, source=self.lines[line - 1].strip()[:160])
        if op == "set" and not piece:
            tgt = n.parent
            arg = tgt.parent if tgt is not None and tgt.type == "set_target" else None
            if arg is not None and arg.type == "set_argument":
                rhs = next((c for c in arg.children if c.type == "expression"), None)
                if rhs is not None:
                    ref.value = node_text(src, rhs)
        if naked:
            self.resolve_naked(ref, rendered)
        else:
            ref.pattern = f"^{glob}" + (f"({','.join(subs)})" if subs else "")
            ref.shape = f"^{glob}" + (f"({','.join(r if lit else '*' for r, lit in rendered)})" if subs else "")
            ref._shape_parts = [(r, lit) for r, lit in rendered]  # type: ignore[attr-defined]
        if re.match(r"\^(\||\[)", text):
            ref.notes.append("extended reference (names a namespace or database)")
        if subs and subs[0] == "$J":
            ref.notes.append("per-process node (first subscript $J)")
        self.refs.append(ref)
        if op not in NO_NAKED_UPDATE and (subs or naked):
            self.last = ref
            self.between = []

    def resolve_naked(self, ref: Ref, rendered: list[tuple[str, bool]]) -> None:
        prev = self.last
        if prev is None or not (prev.glob or prev.resolved):
            ref.confidence = "low"
            ref.notes.append("no earlier global reference in this label: depends on the caller")
            ref.pattern = ref.shape = ref.text
            return
        base_parts = getattr(prev, "_shape_parts", [])
        keep = base_parts[: max(len(base_parts) - 1, 0)]
        parts = keep + rendered
        ref.glob = prev.glob
        ref._shape_parts = parts  # type: ignore[attr-defined]
        ref.resolved = f"^{prev.glob}(" + ",".join(r for r, _ in parts) + ")"
        ref.pattern = ref.resolved
        ref.shape = f"^{prev.glob}(" + ",".join(r if lit else "*" for r, lit in parts) + ")"
        ref.notes.append(f"previous reference: {prev.pattern} ({prev.op}, line {prev.line})")
        if self.between:
            ref.confidence = "low"
            ref.notes.append("between them: " + "; ".join(self.between))
        else:
            ref.confidence = "high"

    def indirect(self, n: Node) -> None:
        p = n.parent
        # D @X, G @X, $$@X: routine calls, not data
        if p is not None and p.type in ("line_ref", "routine_tag_call", "do_parameter", "goto_argument"):
            return
        op, piece, delim, notes = self.context(n)
        line = n.start_point[0] + 1
        text = node_text(self.src, n)
        ref = Ref(file=self.rel, unit=self.unit, label=self.label, line=line, col=n.start_point[1] + 1,
                  text=text, glob="", subs=[], pattern=text, shape="@", op=op, piece=piece, delim=delim,
                  notes=notes + ["indirect: the name is computed at run time"],
                  source=self.lines[line - 1].strip()[:160])
        self.refs.append(ref)
        self.pending_indirect.append((ref, self.label))
        self.last = None
        self.between = []


# ---- reporting -------------------------------------------------------------------
def delim_char(text: str) -> str:
    m = re.fullmatch(r'"(.)"', text)
    if m:
        return m.group(1)
    chars = DELIM_VARS.get(text, set())
    return next(iter(chars)) if len(chars) == 1 else ""


def concat_operands(expr: str) -> list[str]:
    """Split an expression on the concatenation operator _ at the top level."""
    out, depth, cur, in_str = [], 0, "", False
    for ch in expr:
        if ch == '"':
            in_str = not in_str
        elif not in_str and ch in "([{":
            depth += 1
        elif not in_str and ch in ")]}":
            depth -= 1
        elif not in_str and depth == 0 and ch == "_":
            out.append(cur.strip())
            cur = ""
            continue
        cur += ch
    out.append(cur.strip())
    return out


def split_record(value: str, delim_texts: set[str]) -> list[str]:
    if not delim_texts:
        # no $PIECE on this global: fall back to one-character literals / delimiter variables
        # used as operands of the concatenation, if they all name the same character
        delim_texts = {op for op in concat_operands(value) if delim_char(op)}
    chars = {delim_char(d) for d in delim_texts} - {""}
    if len(chars) != 1:
        return []
    c = chars.pop()
    names = {d for d in delim_texts if delim_char(d) == c}
    ops = concat_operands(value)
    if len(ops) < 2:
        return []
    fields, cur, split = [], [], False
    for op in ops:
        if op in names or op == f'"{c}"':
            fields.append(" _ ".join(cur))
            cur, split = [], True
        elif op.startswith('"') and op.endswith('"') and c in op[1:-1]:
            parts = op[1:-1].split(c)
            if parts[0]:
                cur.append(f'"{parts[0]}"')
            for mid in parts[1:]:
                fields.append(" _ ".join(cur))
                cur, split = ([f'"{mid}"'] if mid else []), True
        else:
            cur.append(op)
    fields.append(" _ ".join(cur))
    return fields if split else []


def finish(refs: list[Ref]) -> None:
    delims: dict[str, set[str]] = defaultdict(set)
    for r in refs:
        if r.glob and r.delim:
            delims[r.glob].add(r.delim)
    for r in refs:
        if r.value and r.glob:
            r.record = split_record(r.value, delims[r.glob])
    def norm(r: Ref) -> tuple:
        # subscripts as written, numbers as a wildcard: ^X(A,1) and ^X(A,2) count as the same
        parts = getattr(r, "_shape_parts", [])
        return (r.glob,) + tuple("#" if re.fullmatch(r"[+-]?\d+(\.\d+)?", p) else p for p, _ in parts)
    full = {norm(r) for r in refs if r.glob and not r.naked}
    for r in refs:
        if r.naked and r.resolved and norm(r) not in full:
            r.notes.append("no full (non-naked) reference anywhere uses this pattern")


def summary(refs: list[Ref]) -> dict:
    by_glob: dict[str, dict[str, dict]] = defaultdict(dict)
    for r in refs:
        if not r.glob:
            continue
        s = by_glob[r.glob].setdefault(r.shape, {"ops": Counter(), "vars": set(), "read_pieces": set(),
                                                   "set_pieces": set(), "where": set(), "naked": 0})
        s["ops"][r.op] += 1
        for sub, lit in getattr(r, "_shape_parts", []):
            if not lit:
                s["vars"].add(sub)
        if r.piece:
            (s["set_pieces"] if r.op == "set" else s["read_pieces"]).add(r.piece)
        s["where"].add(f"{r.unit}:{r.label}" if r.label else r.unit)
        s["naked"] += r.naked
    out = {}
    for g in sorted(by_glob):
        out[g] = []
        for shape in sorted(by_glob[g], key=lambda x: (x.count(","), x)):
            s = by_glob[g][shape]
            out[g].append({"shape": shape, "ops": dict(s["ops"]), "variables": sorted(s["vars"]),
                           "pieces_read": sorted(s["read_pieces"], key=piece_key),
                           "pieces_set": sorted(s["set_pieces"], key=piece_key),
                           "naked_refs": s["naked"], "where": sorted(s["where"])})
    return out


def piece_key(p: str):
    m = re.match(r"\d+", p)
    return (0, int(m.group()), p) if m else (1, 0, p)


def md_escape(s: str) -> str:
    return s.replace("|", "\\|")


def to_markdown(refs: list[Ref], files: list[str], only_summary: bool) -> str:
    out = ["# Global reference map", "",
           f"Generated by the kit's global map ({GRAMMAR}) from {len(files)} file(s), "
           f"{len(refs)} reference(s). Static analysis: see the script's docstring for what it cannot see.", ""]
    out += ["## Globals", "",
            "Node shapes: string-literal subscripts as written, `*` for anything else (variable, number, expression). "
            "Pieces are `$PIECE` positions used directly on the node.", "",
            "| Global | Node shape | Subscripts seen | Operations | Pieces read | Pieces set | Where (routine:label) |",
            "|---|---|---|---|---|---|---|"]
    for g, shapes in summary(refs).items():
        for s in shapes:
            ops = ", ".join(f"{k}×{v}" for k, v in sorted(s["ops"].items()))
            out.append(f"| `^{g}` | `{md_escape(s['shape'])}` | {md_escape(', '.join(s['variables']))} | {ops} | "
                       f"{', '.join(s['pieces_read'])} | {', '.join(s['pieces_set'])} | {', '.join(s['where'])} |")
    naked = [r for r in refs if r.naked]
    out += ["", "## Naked references", ""]
    if naked:
        out += ["| Where | Line | As written | Resolves to (static estimate) | Confidence | Notes |", "|---|---|---|---|---|---|"]
        for r in naked:
            out.append(f"| {r.unit}:{r.label} | {r.line} | `{md_escape(r.text)}` | `{md_escape(r.resolved or '?')}` | "
                       f"{r.confidence} | {md_escape('; '.join(r.notes))} |")
    else:
        out.append("None.")
    recs = [r for r in refs if r.record]
    out += ["", "## Whole-record SETs", "",
            "A SET of a whole node whose value is built by concatenation, split on the delimiter its "
            "`$PIECE` calls use. Field *n* is `$PIECE` *n*.", ""]
    if recs:
        width = max(len(r.record) for r in recs)
        out += ["| Node shape | Where | Line | " + " | ".join(f"{i}" for i in range(1, width + 1)) + " |",
                "|---|---|---|" + "---|" * width]
        for r in sorted(recs, key=lambda r: (r.shape, r.unit, r.line)):
            cells = [f"`{md_escape(x)}`" if x else "" for x in r.record] + [""] * (width - len(r.record))
            out.append(f"| `{md_escape(r.shape)}` | {r.unit}:{r.label} | {r.line} | " + " | ".join(cells) + " |")
    else:
        out.append("None.")
    ind = [r for r in refs if r.shape == "@"]
    out += ["", "## Indirect references", ""]
    if ind:
        out += ["| Where | Line | As written | Operation | Notes |", "|---|---|---|---|---|"]
        for r in ind:
            out.append(f"| {r.unit}:{r.label} | {r.line} | `{md_escape(r.text)}` | {r.op} | {md_escape('; '.join(r.notes))} |")
    else:
        out.append("None.")
    locks = [r for r in refs if r.op in ("lock", "lock+")]
    out += ["", "## Locks", ""]
    if locks:
        out += ["| Where | Line | Node | Operation | Timeout |", "|---|---|---|---|---|"]
        for r in locks:
            out.append(f"| {r.unit}:{r.label} | {r.line} | `{md_escape(r.pattern)}` | {r.op} | "
                       f"{'yes' if 'timeout' in r.notes else '**no**'} |")
    else:
        out.append("None.")
    if only_summary:
        return "\n".join(out) + "\n"
    out += ["", "## By routine and label", ""]
    by_unit: dict[str, list[Ref]] = defaultdict(list)
    for r in refs:
        by_unit[r.unit].append(r)
    for unit in sorted(by_unit):
        out += [f"### {unit}", "", "| Label | Line | Reference | Pattern | Operation | Piece | Notes |", "|---|---|---|---|---|---|---|"]
        for r in by_unit[unit]:
            notes = [x for x in r.notes if not x.startswith("previous reference")]
            pat = (r.resolved or r.text) if r.naked else r.pattern
            out.append(f"| {r.label} | {r.line} | `{md_escape(r.text)}` | `{md_escape(pat)}` | {r.op} | "
                       f"{r.piece} | {md_escape('; '.join(notes))} |")
        out.append("")
    return "\n".join(out) + "\n"


def main(argv: list[str] | None = None) -> int:
    sys.setrecursionlimit(20000)  # deeply nested expressions in long legacy lines
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="*", default=["src"], help="files or directories (default: src)")
    ap.add_argument("--json", action="store_true", help="JSON instead of Markdown")
    ap.add_argument("--global", dest="glob", help="only this global (with or without ^)")
    ap.add_argument("--summary", action="store_true", help="Markdown: only the per-global, naked, indirect and lock sections")
    ap.add_argument("--no-classes", action="store_true", help="skip .cls files")
    a = ap.parse_args(argv)

    files: list[Path] = []
    for p in map(Path, a.paths):
        if p.is_dir():
            files += sorted(f for f in p.rglob("*") if f.suffix.lower() in ROUTINE_EXT | {".cls"})
        elif p.exists():
            files.append(p)
        else:
            print(f"globalmap: no such path: {p}", file=sys.stderr)
            return 2
    if a.no_classes:
        files = [f for f in files if f.suffix.lower() != ".cls"]
    m = Mapper()
    for f in files:
        m.map_file(f, str(f))
    refs = m.refs
    finish(refs)
    if a.glob:
        g = a.glob.lstrip("^")
        refs = [r for r in refs if r.glob == g or (r.shape == "@" and f"^{g}" in " ".join(r.notes))]
    if a.json:
        data = {"tool": "globalmap", "grammar": GRAMMAR, "files": [str(f) for f in files],
                "summary": summary(refs), "references": [asdict(r) for r in refs]}
        json.dump(data, sys.stdout, indent=1)
        print()
    else:
        sys.stdout.write(to_markdown(refs, [str(f) for f in files], a.summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
