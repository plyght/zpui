#!/usr/bin/env python3
"""Sizes, dynamic library dependencies, build times, lines of code and test counts.

    python3 bench/static_metrics.py --out static.json \
        --bin rust=zeron-src/target/release/zeron --bin zig-fast=zig-out/fast/zeron \
        --bin zig-safe=zig-out/safe/zeron --bin engine=zig-out/zeron-engine \
        --bundle rust=zeron-src/target/package/Zeron.app --bundle zig=zig-out/Zeron.app \
        --bundle-exclude zig=Contents/Helpers/zeron-engine \
        --build-times build-times.json --zeron-src zeron-src --zui-src zui-src --zpui-src .

Lines are non-blank lines (comments included) of .rs / .zig files, excluding
target/, zig-out/, .zig-cache/, vendor/ and generated tables; tests are counted
from the source (`#[test]`-style attributes, Zig `test` blocks), not by running them."""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

IS_MAC = sys.platform == "darwin"
SKIP_DIRS = {"target", "zig-out", ".zig-cache", ".git", "node_modules", "vendor", "generated"}


def size_of(path):
    if os.path.isfile(path):
        return os.path.getsize(path)
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            p = os.path.join(root, f)
            if not os.path.islink(p):
                total += os.path.getsize(p)
    return total


def stripped_size(path):
    with tempfile.TemporaryDirectory() as d:
        c = os.path.join(d, "bin")
        shutil.copy(path, c)
        cmd = ["strip", "-x", c] if IS_MAC else ["strip", c]
        r = subprocess.run(cmd, capture_output=True)
        return os.path.getsize(c) if r.returncode == 0 else None


def dylibs(path):
    if IS_MAC:
        out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout.splitlines()[1:]
        libs = [l.strip().split(" (")[0] for l in out if l.strip()]
        system = [l for l in libs if l.startswith(("/usr/lib/", "/System/"))]
        return {"direct": len(libs), "libs": libs, "non_system": [l for l in libs if l not in system]}
    # Linux: direct DT_NEEDED entries, plus the transitive closure ldd resolves.
    dyn = subprocess.run(["readelf", "-d", path], capture_output=True, text=True).stdout
    libs = re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", dyn)
    ldd = subprocess.run(["ldd", path], capture_output=True, text=True).stdout.splitlines()
    closure = [l.strip().split(" => ")[0].split(" (")[0] for l in ldd if l.strip()]
    return {"direct": len(libs), "libs": libs, "transitive": len(closure)}


def count_tree(root, exts, test_re):
    lines = files = tests = 0
    if not root or not os.path.isdir(root):
        return None
    for dirpath, dirs, fnames in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in fnames:
            if not f.endswith(exts):
                continue
            p = os.path.join(dirpath, f)
            try:
                text = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if len(text) > 2_000_000:  # generated tables
                continue
            files += 1
            lines += sum(1 for l in text.splitlines() if l.strip())
            tests += len(test_re.findall(text))
    return {"files": files, "lines": lines, "tests": tests}


RUST_TEST = re.compile(r"#\[(?:[a-z_]+::)?test(?:\([^)]*\))?\]")
ZIG_TEST = re.compile(r"^\s*test\s*(?:\"|\{|[A-Za-z_])", re.M)

RUST_UI_CRATES = ["ui", "markdown", "syntax", "text", "theme", "update", "voice", "preview"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--bin", action="append", default=[], help="label=path")
    ap.add_argument("--bundle", action="append", default=[], help="label=path (dir or archive)")
    ap.add_argument("--bundle-exclude", action="append", default=[], help="label=relative path inside the bundle")
    ap.add_argument("--build-times")
    ap.add_argument("--zeron-src")
    ap.add_argument("--zui-src")
    ap.add_argument("--zpui-src")
    a = ap.parse_args()
    out = {"binaries": {}, "bundles": {}, "loc": {}}
    for kv in a.bin:
        label, path = kv.split("=", 1)
        if not os.path.exists(path):
            out["binaries"][label] = {"missing": path}
            continue
        out["binaries"][label] = {"bytes": size_of(path), "stripped_bytes": stripped_size(path), "dylibs": dylibs(path)}
    excl = dict(kv.split("=", 1) for kv in a.bundle_exclude)
    for kv in a.bundle:
        label, path = kv.split("=", 1)
        if not os.path.exists(path):
            out["bundles"][label] = {"missing": path}
            continue
        total = size_of(path)
        rec = {"bytes": total}
        if label in excl:
            ex = os.path.join(path, excl[label])
            rec["excluded"] = excl[label]
            rec["excluded_bytes"] = size_of(ex) if os.path.exists(ex) else None
            rec["bytes_without_excluded"] = total - (rec["excluded_bytes"] or 0)
        out["bundles"][label] = rec
    if a.build_times and os.path.exists(a.build_times):
        out["build_times_s"] = json.load(open(a.build_times))
    if a.zeron_src:
        crates = {}
        for c in sorted(os.listdir(os.path.join(a.zeron_src, "crates"))):
            r = count_tree(os.path.join(a.zeron_src, "crates", c), (".rs",), RUST_TEST)
            if r:
                crates[c] = r
        app = count_tree(os.path.join(a.zeron_src, "apps", "zeron"), (".rs",), RUST_TEST)
        ui = {k: sum(crates[c][k] for c in RUST_UI_CRATES if c in crates) for k in ("files", "lines", "tests")}
        rest = {k: sum(v[k] for c, v in crates.items() if c not in RUST_UI_CRATES) for k in ("files", "lines", "tests")}
        out["loc"]["rust_zeron"] = {"ui_side_crates": RUST_UI_CRATES, "ui_side": ui, "engine_and_shared": rest,
                                     "apps_zeron": app, "per_crate": crates}
    if a.zui_src:
        out["loc"]["rust_zui"] = count_tree(os.path.join(a.zui_src, "crates"), (".rs",), RUST_TEST)
    if a.zpui_src:
        out["loc"]["zig_zpui_framework"] = count_tree(os.path.join(a.zpui_src, "src"), (".zig",), ZIG_TEST)
        out["loc"]["zig_zeron_app"] = count_tree(os.path.join(a.zpui_src, "apps", "zeron", "src"), (".zig",), ZIG_TEST)
        out["loc"]["zig_engine_host_rs"] = count_tree(os.path.join(a.zpui_src, "apps", "zeron", "engine-host"), (".rs",), RUST_TEST)
    with open(a.out, "w") as f:
        json.dump(out, f, indent=1)
    print(json.dumps({k: v for k, v in out.items() if k != "loc"} | {"loc": {k: (v if k != "rust_zeron" else {kk: vv for kk, vv in v.items() if kk != "per_crate"}) for k, v in out["loc"].items()}}, indent=1))


if __name__ == "__main__":
    main()
