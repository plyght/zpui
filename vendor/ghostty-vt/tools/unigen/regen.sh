#!/bin/sh
# Regenerate ../../generated/{props.zig,symbols.zig,uucode_tables.zig} from a
# uucode checkout (Zig 0.17 port, e.g. jacobsandlund/uucode 1fb7343) with
# Ghostty's uucode config. Usage: tools/unigen/regen.sh /path/to/uucode
set -eu
UUCODE=${1:?usage: regen.sh /path/to/uucode}
HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$HERE/uucode" && mkdir "$HERE/uucode"
(cd "$UUCODE" && tar cf - --exclude=.zig-cache --exclude=.git --exclude=zig-out .) | tar xf - -C "$HERE/uucode"
(cd "$HERE" && zig build)
cp "$HERE/zig-out/props.zig" "$HERE/zig-out/symbols.zig" "$HERE/../../generated/"
cp "$HERE/zig-out/runtime_tables.zig" "$HERE/../../generated/uucode_tables.zig"
rm -rf "$HERE/uucode" "$HERE/zig-out" "$HERE/.zig-cache"
echo "regenerated generated/*.zig"
