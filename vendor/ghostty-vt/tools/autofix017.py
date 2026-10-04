#!/usr/bin/env python3
"""Compiler-error-driven Zig 0.17 fixups for the vendored Ghostty sources.

Reads `zig build` output on stdin and rewrites expressions at the reported
locations for a small set of purely mechanical API changes:

  info.fields / info.decls  (Type.Struct/Enum/Union)  -> zig017.fields(info)
  info.params               (Type.Fn)                 -> zig017.params(info)
  ptr.is_const / is_volatile / alignment / address_space / is_allowzero
                            (Type.Pointer)            -> ptr.attrs.@"..."

Usage: zig build check 2>&1 | python3 vendor/ghostty-vt/tools/autofix017.py
Re-run until it reports 0 fixes; then fix the remainder by hand.
"""
import os
import re
import sys

ERR = re.compile(r"^(\S+\.zig):(\d+):(\d+): error: no field named '(\w+)' in struct 'lang\.Type\.(\w+)'")
COMPAT_REL = "lib/compat/zig017.zig"

PTR_ATTRS = {
    "is_const": '@"const"',
    "is_volatile": '@"volatile"',
    "is_allowzero": '@"allowzero"',
    "address_space": '@"addrspace"',
    "alignment": '@"align"',
}


def receiver_start(line, dot):
    """Index where the postfix expression ending just before `dot` starts."""
    i = dot - 1
    while i >= 0:
        c = line[i]
        if c in ")]":
            depth, close = 0, c
            open_ = "(" if c == ")" else "["
            while i >= 0:
                if line[i] == close:
                    depth += 1
                elif line[i] == open_:
                    depth -= 1
                    if depth == 0:
                        break
                i -= 1
            i -= 1
        elif c == '"':
            # @"ident"
            j = line.rfind('"', 0, i)
            i = j - 2  # skip the '@'
        elif c.isalnum() or c == "_" or c == "@":
            i -= 1
        elif c == ".":
            i -= 1
        else:
            break
    return i + 1


def find_src_root(path):
    d = os.path.dirname(os.path.abspath(path))
    while d != "/":
        if os.path.basename(d) == "src" and os.path.exists(os.path.join(d, "lib_vt.zig")):
            return d
        d = os.path.dirname(d)
    return None


def main():
    fixes = {}
    for raw in sys.stdin:
        m = ERR.match(raw.strip())
        if not m:
            continue
        path, line, col, field, kind = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4), m.group(5)
        fixes.setdefault(os.path.realpath(path), set()).add((line, col, field, kind))
    total = 0
    for path, items in fixes.items():
        with open(path) as fh:
            lines = fh.read().split("\n")
        # process right-to-left within a line so columns stay valid
        for line, col, field, kind in sorted(items, key=lambda t: (t[0], -t[1])):
            L = lines[line - 1]
            start = col - 1
            if L[start:start + len(field)] != field or L[start - 1] != ".":
                print("skip (unexpected text)", path, line, col, field)
                continue
            dot = start - 1
            r = receiver_start(L, dot)
            recv = L[r:dot]
            end = start + len(field)
            if kind in ("Struct", "Enum", "Union") and field in ("fields", "decls"):
                new = "zig017.%s(%s)" % (field, recv)
                L = L[:r] + new + L[end:]
            elif kind == "Fn" and field == "params":
                L = L[:r] + "zig017.params(%s)" % recv + L[end:]
            elif kind == "Pointer" and field in PTR_ATTRS:
                L = L[:start] + "attrs." + PTR_ATTRS[field] + L[end:]
            else:
                print("unhandled", path, line, col, field, kind)
                continue
            lines[line - 1] = L
            total += 1
        src = "\n".join(lines)
        if "zig017." in src and not re.search(r"^const zig017 = @import", src, re.M):
            root = find_src_root(path)
            rel = os.path.relpath(os.path.join(root, COMPAT_REL), os.path.dirname(path))
            src = src.rstrip("\n") + '\n\nconst zig017 = @import("%s"); // zpui: Zig 0.17 port shims\n' % rel
        with open(path, "w") as fh:
            fh.write(src)
    print("fixes applied:", total)


if __name__ == "__main__":
    main()
