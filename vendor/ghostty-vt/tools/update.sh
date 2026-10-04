#!/bin/sh
# Re-vendor a newer Ghostty: copy FILES.txt from upstream, re-apply the
# mechanical 0.17 rewrites, then the hand-made patch. See ../PORTING.md.
# Usage: tools/update.sh /path/to/ghostty
set -eu
GHOSTTY=${1:?usage: update.sh /path/to/ghostty}
HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"
rm -rf src && mkdir -p src
while read -r f; do
  mkdir -p "src/$(dirname "$f")"
  cp "$GHOSTTY/src/$f" "src/$f"
done < FILES.txt
python3 tools/port017.py src > /dev/null
# The patch also creates the shim files (lib/compat/zig017.zig, repeat.zig).
patch -p1 -N --no-backup-if-mismatch < ghostty-zig017.patch || {
  echo "some hunks failed: fix the *.rej files by hand"; exit 1; }
echo "now: zig build ghostty-vt-test; for new 0.16-isms run"
echo "  zig build ghostty-vt-test 2>&1 | python3 tools/autofix017.py   (repeat)"
echo "then: tools/make_patch.sh $GHOSTTY"
