#!/usr/bin/env python3
"""Build apps/zeron/dist/macos/zeron.icns from a 1024x1024 PNG.

    apps/zeron/scripts/make_icns.py <icon-1024.png> <out.icns>

The source is the Rust app's macOS-shaped artwork (zeron/dist/macos/icon-1024.png:
squircle mask, margins and shadow pre-baked). Resizing uses ImageMagick
(`magick` or `convert`); the .icns container is written here with PNG payloads
(the modern `ic04`..`ic14` element types), so no macOS `iconutil` is needed.
On macOS `iconutil -c icns` on an iconset gives an equivalent file.
"""
import os, shutil, struct, subprocess, sys, tempfile

# (OSType, pixel size): 16/32/128/256/512 at 1x and 2x.
ELEMENTS = [
    ("icp4", 16), ("ic11", 32),    # 16, 16@2x
    ("icp5", 32), ("ic12", 64),    # 32, 32@2x
    ("ic07", 128), ("ic13", 256),  # 128, 128@2x
    ("ic08", 256), ("ic14", 512),  # 256, 256@2x
    ("ic09", 512), ("ic10", 1024), # 512, 512@2x
]

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    im = shutil.which("magick") or shutil.which("convert")
    if not im:
        sys.exit("make_icns: ImageMagick (magick/convert) not found")
    cache = {}
    with tempfile.TemporaryDirectory() as tmp:
        for _, size in ELEMENTS:
            if size in cache:
                continue
            p = os.path.join(tmp, f"{size}.png")
            subprocess.run([im, src, "-strip", "-filter", "Lanczos", "-resize", f"{size}x{size}",
                            "-define", "png:compression-level=9", f"PNG32:{p}"], check=True)
            cache[size] = open(p, "rb").read()
    body = b"".join(struct.pack(">4sI", t.encode(), 8 + len(cache[s])) + cache[s] for t, s in ELEMENTS)
    with open(out, "wb") as f:
        f.write(struct.pack(">4sI", b"icns", 8 + len(body)) + body)
    print(f"wrote {out} ({8 + len(body)} bytes, {len(ELEMENTS)} images)")

if __name__ == "__main__":
    main()
