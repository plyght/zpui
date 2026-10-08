#!/usr/bin/env python3
"""Add the benchmark timeline hook to a zeron checkout (benchmark build only).

    python3 bench/patch_rust_client.py <zeron-src>

Copies bench/rust/bench_hook.rs to crates/ui/src/bench_hook.rs and makes two edits
to crates/ui/src/lib.rs: declare the module, and call `bench_hook::start` with the
main window right after `run_app` opens it. The hook is inert unless ZERON_BENCH=1,
so the patched binary's size and startup path are otherwise unchanged (one env
lookup). Fails loudly if the anchors moved, rather than benchmarking an unpatched app."""

import os
import shutil
import sys


def main():
    root = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    ui = os.path.join(root, "crates", "ui", "src")
    shutil.copy(os.path.join(here, "rust", "bench_hook.rs"), os.path.join(ui, "bench_hook.rs"))
    lib = os.path.join(ui, "lib.rs")
    src = open(lib).read()
    if "mod bench_hook;" in src:
        print("already patched")
        return
    anchor_mod = "pub mod app_menus;\n"
    anchor_open = "        open_main_window(state, config.boot(), cx);\n"
    for a in (anchor_mod, anchor_open):
        if src.count(a) != 1:
            sys.exit(f"patch_rust_client: anchor not found exactly once in lib.rs: {a!r}")
    src = src.replace(anchor_mod, "mod bench_hook;\n" + anchor_mod)
    src = src.replace(
        anchor_open,
        "        let bench_window = open_main_window(state.clone(), config.boot(), cx);\n"
        "        bench_hook::start(bench_window, state, cx);\n",
    )
    open(lib, "w").write(src)
    print("patched", lib)


if __name__ == "__main__":
    main()
