#!/usr/bin/env python3
"""Compare native AppKit text with zpui text (tools/font-compare).

Usage: compare.py cases.json OUT_DIR [ZPUI_DIR] [--label NAME]

Reads OUT_DIR/native.json, native-s{1,2}.png (and native-window.png when present) and
ZPUI_DIR/zpui.json, zpui-s{1,2}.png (ZPUI_DIR defaults to OUT_DIR). Writes:
  OUT_DIR/compare.json   per case: line widths, max glyph x delta, ink ratio, mean abs diff
  OUT_DIR/compare.txt    the same as a table, with PASS/FAIL against the 0.5 px budget
  OUT_DIR/side-by-side-s{1,2}.png   per case: native row, zpui row, |diff| x4
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

BUDGET = 0.5  # px, advances and line widths


def row_height(c):
    import math
    return math.ceil(c["size"] * 1.6) + 8


def lum(px):
    return 0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]


def ink(img, bg):
    """Sum of |luminance - background luminance| over a crop: a stroke weight proxy."""
    b = lum(bg)
    total = 0.0
    for px in img.getdata():
        total += abs(lum(px) - b)
    return total / 255.0


def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    label = "zpui"
    if "--label" in sys.argv:
        label = sys.argv[sys.argv.index("--label") + 1]
        args = [a for a in args if a != label]
    cases_path, out = Path(args[0]), Path(args[1])
    zdir = Path(args[2]) if len(args) > 2 else out
    spec = json.loads(cases_path.read_text())
    native = {c["id"]: c for c in json.loads((out / "native.json").read_text())["cases"]}
    zpui = {c["id"]: c for c in json.loads((zdir / "zpui.json").read_text())["cases"]}

    results = []
    lines = [f"{'case':28} {'native':>9} {'tk':>9} {label:>9} {'dW':>7} {'maxdx':>7} {'ink s2':>7} {'mad s2':>7}"]
    imgs = {}
    for s in (1, 2):
        try:
            imgs[s] = (Image.open(out / f"native-s{s}.png").convert("RGB"), Image.open(zdir / f"zpui-s{s}.png").convert("RGB"))
        except FileNotFoundError:
            pass
    y = 0
    sheets = {s: [] for s in imgs}
    worst = 0.0
    for c in spec["cases"]:
        n, z = native[c["id"]], zpui.get(c["id"])
        h = row_height(c)
        r = {"id": c["id"], "native_width": n["ct_width"], "tk_width": n["tk_width"], "native_font": n["font"]["postscript"],
             "native_variation": n["font"].get("variation")}
        if z:
            r["zpui_width"] = z["width"]
            r["width_delta"] = z["width"] - n["ct_width"]
            nx, zx = n["ct_x"], z["x"]
            r["same_glyphs"] = n["glyphs"] == z["glyphs"]
            r["max_dx"] = max((abs(a - b) for a, b in zip(nx, zx)), default=0.0) if len(nx) == len(zx) else None
            worst = max(worst, abs(r["width_delta"]), r["max_dx"] or 0)
        bg = hex_rgb(c["bg"])
        for s, (ni, zi) in imgs.items():
            box = (0, int(y * s), ni.width, int((y + h) * s))
            nc, zc = ni.crop(box), zi.crop(box)
            n_ink, z_ink = ink(nc, bg), ink(zc, bg)
            diff = ImageChops.difference(nc, zc)
            mad = sum(sum(px) for px in diff.getdata()) / (3.0 * diff.width * diff.height)
            r[f"ink_ratio_s{s}"] = (z_ink / n_ink) if n_ink else None
            r[f"mad_s{s}"] = mad
            # Crop to the text extent (+ margin) for the sheet.
            tw = int((16 + max(n["ct_width"], z["width"] if z else 0) + 24) * s)
            tw = min(tw, ni.width)
            amp = diff.point(lambda v: min(255, v * 4))
            sheets[s].append((c["id"], nc.crop((0, 0, tw, nc.height)), zc.crop((0, 0, tw, zc.height)), amp.crop((0, 0, tw, amp.height))))
        results.append(r)
        fmt = lambda v: "-" if v is None else f"{v:9.3f}"
        lines.append(f"{c['id']:28} {fmt(r['native_width'])} {fmt(r['tk_width'])} {fmt(r.get('zpui_width'))} "
                     f"{r.get('width_delta', 0):+7.3f} {(r.get('max_dx') if r.get('max_dx') is not None else -1):7.3f} "
                     f"{(r.get('ink_ratio_s2') or 0):7.3f} {(r.get('mad_s2') or 0):7.3f}")
        y += h
    lines.append(f"worst advance/width delta: {worst:.3f} px -> {'PASS' if worst <= BUDGET else 'FAIL'} (budget {BUDGET})")
    (out / "compare.json").write_text(json.dumps({"label": label, "worst": worst, "cases": results}, indent=1))
    (out / "compare.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))

    for s, rows in sheets.items():
        label_w = 190 * s // 2 + 60
        width = max(r[1].width for r in rows) + label_w
        height = sum(r[1].height * 3 + 4 * s for r in rows)
        sheet = Image.new("RGB", (width, height), (40, 40, 40))
        d = ImageDraw.Draw(sheet)
        yy = 0
        for cid, a, b, df in rows:
            for k, (img, tag) in enumerate(((a, "native"), (b, label), (df, "diff x4"))):
                sheet.paste(img, (label_w, yy))
                d.text((4, yy + 2), f"{cid}" if k == 0 else tag, fill=(230, 230, 230) if k == 0 else (150, 150, 150))
                yy += img.height
            yy += 4 * s
        sheet.save(out / f"side-by-side-s{s}.png")
        print(f"wrote {out}/side-by-side-s{s}.png")


if __name__ == "__main__":
    main()
