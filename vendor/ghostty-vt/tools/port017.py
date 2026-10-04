#!/usr/bin/env python3
"""Mechanical Zig 0.16 -> 0.17 rewrites for the vendored Ghostty sources.

Idempotent: safe to run repeatedly over vendor/ghostty-vt/src. Every rewrite
here is a pure syntactic substitution; anything needing judgement is done by
hand and recorded in PORTING.md / ghostty-zig017.patch.

Usage: python3 vendor/ghostty-vt/tools/port017.py [SRC_DIR]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "src")
SRC = os.path.abspath(SRC)
COMPAT = os.path.join(SRC, "lib", "compat", "zig017.zig")
REPEAT = os.path.join(SRC, "lib", "compat", "repeat.zig")

# Balanced-paren expression (2 levels), identifier path, or number.
PAREN = r"\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)"
N = r"(" + PAREN + r"|[A-Za-z_][\w.]*|\d[\d_]*)"

SIMPLE = [
    # std.meta.Int was removed; @Int is the builtin replacement.
    (re.compile(r"\bstd\.meta\.Int\("), "@Int("),
    (re.compile(r"\bstd\.heap\.stackFallback\("), "zig017.stackFallback("),
    (re.compile(r"\bstd\.fmt\.bufPrintZ\("), "zig017.bufPrintZ("),
    # Static bit sets / EnumSet: initEmpty()/initFull() -> decl literals.
    (re.compile(r"\.initEmpty\(\)"), ".empty"),
    (re.compile(r"\.initFull\(\)"), ".full"),
    # The 0.17 CRC-32/ISCSI alias is the SSE4.2 wrapper on x86_64, whose raw
    # `.crc` state differs; Ghostty's tests compare raw state, so use the
    # table-driven Generic with the same parameters (what Crc32Iscsi was).
    (re.compile(r"\bstd\.hash\.crc\.Crc32Iscsi\b"), "std.hash.crc.Generic(u32, .{ .polynomial = 0x1edc6f41, .initial = 0xffffffff, .reflect_input = true, .reflect_output = true, .xor_output = 0xffffffff })"),
    (re.compile(r"\bstd\.meta\.fields\("), "zig017.metaFields("),
    # std.builtin.OptimizeMode tags were renamed (std.lang.Optimize).
    (re.compile(r"(?<![\w\]])\.Debug\b"), ".debug"),
    (re.compile(r"(?<![\w\]])\.ReleaseSafe\b"), ".safe"),
    (re.compile(r"(?<![\w\]])\.ReleaseFast\b"), ".fast"),
    (re.compile(r"(?<![\w\]])\.ReleaseSmall\b"), ".small"),
    (re.compile(r"\bstd\.ascii\.indexOfIgnoreCase\b"), "std.ascii.findIgnoreCase"),
    (re.compile(r"\bstd\.ascii\.indexOfIgnoreCasePos\b"), "std.ascii.findIgnoreCasePos"),
    (re.compile(r"\.dupeZ\(u8, ((?:[^()]|\((?:[^()]|\([^()]*\))*\))*)\)"), r".dupeSentinel(u8, \1, 0)"),
    (re.compile(r"\bstd\.builtin\.Type\.StructField\b"), "zig017.StructField"),
    (re.compile(r"\bstd\.builtin\.Type\.EnumField\b"), "zig017.EnumField"),
    (re.compile(r"\bstd\.builtin\.Type\.UnionField\b"), "zig017.UnionField"),
]

# @typeInfo(X).@"struct".fields -> zig017.fields(@typeInfo(X).@"struct")
TYPEINFO_FIELDS = re.compile(
    r'(@typeInfo' + PAREN + r'\.@"(?:struct|enum|union)")\.(fields|decls)\b'
)
TYPEINFO_PARAMS = re.compile(r'(@typeInfo' + PAREN + r'\.@"fn")\.params\b')

ARR_REPEAT = re.compile(r"\[_\](\w+)\{([^{}]+)\} \*\* " + N)
STR_REPEAT = re.compile(r'("(?:[^"\\\n]|\\.)*") \*\* ' + N)


def code_only(line):
    """Return the index where a // comment starts (outside strings) or len."""
    i, n, q = 0, len(line), False
    while i < n:
        c = line[i]
        if q:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                q = False
        else:
            if c == '"':
                q = True
            elif c == "'" and i + 2 < n:
                # char literal: skip
                j = line.find("'", i + 1 + (1 if line[i + 1] == "\\" else 0) + 1)
                if j != -1:
                    i = j + 1
                    continue
            elif line.startswith("//", i):
                return i
        i += 1
    return n


def rewrite_line(line):
    cut = code_only(line)
    code, comment = line[:cut], line[cut:]
    for rx, rep in SIMPLE:
        code = rx.sub(rep, code)
    code = TYPEINFO_FIELDS.sub(lambda m: "zig017.%s(%s)" % (m.group(2), m.group(1)), code)
    code = TYPEINFO_PARAMS.sub(lambda m: "zig017.params(%s)" % m.group(1), code)
    code = ARR_REPEAT.sub(lambda m: "@as([%s]%s, @splat(%s))" % (m.group(3), m.group(1), m.group(2)), code)
    code = STR_REPEAT.sub(lambda m: "zpui_repeat.str(%s, %s)" % (m.group(1), m.group(2)), code)
    return code + comment


def ensure_import(src, name, target, dirpath, note):
    if not re.search(r"\b%s\." % name, src):
        return src
    if re.search(r"^const %s = @import" % name, src, re.M):
        return src
    rel = os.path.relpath(target, dirpath)
    return src.rstrip("\n") + '\n\nconst %s = @import("%s"); // %s\n' % (name, rel, note)


def main():
    changed = 0
    for dp, _, files in os.walk(SRC):
        for f in files:
            if not f.endswith(".zig"):
                continue
            p = os.path.join(dp, f)
            if p in (COMPAT, REPEAT):
                continue
            with open(p) as fh:
                orig = fh.read()
            s = "\n".join(rewrite_line(l) for l in orig.split("\n"))
            s = ensure_import(s, "zig017", COMPAT, dp, "zpui: Zig 0.17 port shims")
            s = ensure_import(s, "zpui_repeat", REPEAT, dp, "zpui: `**` removed in 0.17")
            if s != orig:
                with open(p, "w") as fh:
                    fh.write(s)
                changed += 1
                print("rewrote", os.path.relpath(p, SRC))
    print("files changed:", changed)


if __name__ == "__main__":
    main()
