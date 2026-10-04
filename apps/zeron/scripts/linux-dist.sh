#!/usr/bin/env bash
# Linux tarball, mirroring the Rust app's scripts/package-linux.sh layout:
#   <prefix>/zeron-<version>-linux-<arch>.tar.gz
#     zeron-<version>-linux-<arch>/zeron           the client binary
#     zeron-<version>-linux-<arch>/zeron.desktop   XDG desktop entry (Exec=zeron, Icon=zeron)
#     zeron-<version>-linux-<arch>/zeron.png       512x512 app icon
#     zeron-<version>-linux-<arch>/licenses/       font + third-party notices
# Run through `zig build zeron-dist`, which passes: <repo root> <install prefix> <arch> <version>.
set -euo pipefail
root=$1 prefix=$2 arch=$3 version=$4
bin=$prefix/bin/zeron
[[ -x $bin ]] || { echo "error: $bin missing (zig build zeron failed?)" >&2; exit 1; }
name=zeron-$version-linux-$arch
stage=$prefix/$name
rm -rf "$stage" "$stage.tar.gz"
mkdir -p "$stage/licenses/fonts"
install -m 755 "$bin" "$stage/zeron"
install -m 644 "$root/apps/zeron/dist/zeron.desktop" "$stage/zeron.desktop"
install -m 644 "$root/apps/zeron/dist/zeron.png" "$stage/zeron.png"
cp "$root"/apps/zeron/assets/fonts/licenses/* "$stage/licenses/fonts/"
cp "$root/apps/zeron/assets/LICENSE.zeron" "$root/apps/zeron/assets/THIRD_PARTY_NOTICES.md" "$stage/licenses/"
tar -czf "$stage.tar.gz" -C "$prefix" "$name"
rm -rf "$stage"
echo "zeron-dist: $stage.tar.gz"
tar -tzvf "$stage.tar.gz"
