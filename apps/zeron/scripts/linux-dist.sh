#!/usr/bin/env bash
# Linux tarball, mirroring the Rust app's scripts/package-linux.sh layout:
#   <prefix>/zeron-<version>-linux-<arch>.tar.gz
#     zeron-<version>-linux-<arch>/zeron           the client binary
#     zeron-<version>-linux-<arch>/zeron-engine    the engine (`zeron-engine headless`; found next
#                                                  to the client first, apps/zeron/src/engine_bin.zig)
#     zeron-<version>-linux-<arch>/zeron-webkit    the browser helper (when built)
#     zeron-<version>-linux-<arch>/zeron.desktop   XDG desktop entry (Exec=zeron, Icon=zeron)
#     zeron-<version>-linux-<arch>/zeron.png       512x512 app icon
#     zeron-<version>-linux-<arch>/licenses/       font + third-party notices
#     zeron-<version>-linux-<arch>/lib/libonnxruntime.so  dictation runtime, when
#                                                  ZERON_ONNXRUNTIME names one (optional)
# Run through `zig build zeron-dist`, which passes: <repo root> <install prefix> <arch> <version>.
# The engine: ZERON_ENGINE=/path/to/zeron-engine, else ZERON_SRC=<zeron checkout at the
# tools/upstream pin> builds it (apps/zeron/scripts/build-engine.sh, native target).
# Neither: the tarball has no engine (ZERON_REQUIRE_ENGINE=1 makes that an error).
set -euo pipefail
root=$1 prefix=$2 arch=$3 version=$4
bin=$prefix/bin/zeron
[[ -x $bin ]] || { echo "error: $bin missing (zig build zeron failed?)" >&2; exit 1; }
name=zeron-$version-linux-$arch
stage=$prefix/$name
rm -rf "$stage" "$stage.tar.gz"
mkdir -p "$stage/licenses/fonts"
install -m 755 "$bin" "$stage/zeron"
engine=${ZERON_ENGINE:-}
if [[ -z $engine && -n ${ZERON_SRC:-} ]]; then
  engine=$prefix/zeron-linux-$arch/zeron-engine
  bash "$root/apps/zeron/scripts/build-engine.sh" "$ZERON_SRC" "$engine"
fi
if [[ -n $engine ]]; then
  install -m 755 "$engine" "$stage/zeron-engine"
elif [[ ${ZERON_REQUIRE_ENGINE:-} == 1 ]]; then
  echo "error: no engine (set ZERON_SRC or ZERON_ENGINE)" >&2; exit 1
else
  echo "warning: no bundled engine (set ZERON_SRC or ZERON_ENGINE); the tarball will need an installed zeron" >&2
fi
# The WebKitGTK browser helper (built when webkit2gtk-4.1 dev files were found).
[[ -x $prefix/bin/zeron-webkit ]] && install -m 755 "$prefix/bin/zeron-webkit" "$stage/zeron-webkit"
# Dictation's optional native runtime (apps/zeron/src/voice/ort.zig looks in lib/).
if [[ -n ${ZERON_ONNXRUNTIME:-} ]]; then
  mkdir -p "$stage/lib"
  install -m 644 "$ZERON_ONNXRUNTIME" "$stage/lib/libonnxruntime.so"
fi
install -m 644 "$root/apps/zeron/dist/zeron.desktop" "$stage/zeron.desktop"
install -m 644 "$root/apps/zeron/dist/zeron.png" "$stage/zeron.png"
cp "$root"/apps/zeron/assets/fonts/licenses/* "$stage/licenses/fonts/"
cp "$root/apps/zeron/assets/LICENSE.zeron" "$root/apps/zeron/assets/THIRD_PARTY_NOTICES.md" "$stage/licenses/"
tar -czf "$stage.tar.gz" -C "$prefix" "$name"
rm -rf "$stage"
echo "zeron-dist: $stage.tar.gz"
tar -tzvf "$stage.tar.gz"
