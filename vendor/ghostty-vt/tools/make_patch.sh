#!/bin/sh
# Regenerate ../ghostty-zig017.patch: the hand-made delta between
# (upstream Ghostty files listed in FILES.txt + tools/port017.py) and the
# vendored tree. Usage: tools/make_patch.sh /path/to/ghostty
set -eu
GHOSTTY=${1:?usage: make_patch.sh /path/to/ghostty}
HERE=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/a/src/lib/compat" "$TMP/b"
while read -r f; do
  mkdir -p "$TMP/a/src/$(dirname "$f")"
  cp "$GHOSTTY/src/$f" "$TMP/a/src/$f"
done < "$HERE/FILES.txt"
# port017.py needs the shim files present to compute import paths.
cp "$HERE/src/lib/compat/zig017.zig" "$HERE/src/lib/compat/repeat.zig" "$TMP/a/src/lib/compat/"
python3 "$HERE/tools/port017.py" "$TMP/a/src" > /dev/null
rm "$TMP/a/src/lib/compat/zig017.zig" "$TMP/a/src/lib/compat/repeat.zig"
cp -r "$HERE/src" "$TMP/b/src"
(cd "$TMP" && diff -ruN a/src b/src > "$HERE/ghostty-zig017.patch") || true
echo "wrote $HERE/ghostty-zig017.patch ($(grep -c '^diff' "$HERE/ghostty-zig017.patch") files)"
