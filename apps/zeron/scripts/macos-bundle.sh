#!/usr/bin/env bash
# Assemble <prefix>/Zeron.app from the zeron binary `zig build zeron` just
# installed. Run through `zig build zeron-app-bundle [-Dtarget=aarch64-macos|x86_64-macos]`,
# which passes: <repo root> <install prefix> <arch> <version>.
#
# Each run keeps its arch's binary in <prefix>/zeron-macos-<arch>/zeron. When
# both aarch64 and x86_64 are there and `lipo` exists, the bundle gets a
# universal binary; otherwise the binary of this run's arch.
#
#   Zeron.app/Contents/Info.plist          apps/zeron/dist/macos/Info.plist (__VERSION__ filled in)
#   Zeron.app/Contents/MacOS/zeron         the client (fonts + icons are @embedFile'd, no resources needed)
#   Zeron.app/Contents/Resources/zeron.icns
#   Zeron.app/Contents/Resources/licenses/ font + third-party notices
#
# The engine is found at runtime from Contents/MacOS/zeron-engine, $ZERON_BIN,
# $PATH or the usual install locations (apps/zeron/src/engine_bin.zig); a
# packager can drop the engine binary in as Contents/MacOS/zeron-engine.
# Env: CODESIGN_IDENTITY="Developer ID Application: …" signs with hardened
# runtime + entitlements; otherwise the bundle is ad-hoc signed (when codesign exists).
set -euo pipefail
root=$1 prefix=$2 arch=$3 version=$4
dist=$root/apps/zeron/dist/macos
app=$prefix/Zeron.app
bin=$prefix/bin/zeron

if [[ ! -f $bin ]] || ! file "$bin" 2>/dev/null | grep -q Mach-O; then
  echo "error: $bin is not a macOS executable." >&2
  echo "       zeron-app-bundle needs a macOS host: linking the AppKit/Metal frameworks requires the macOS SDK" >&2
  echo "       (from Linux, \`zig build zeron -Dtarget=$arch-macos\` only type-checks to zig-out/zeron-mac-check.o)." >&2
  exit 1
fi

mkdir -p "$prefix/zeron-macos-$arch"
cp -f "$bin" "$prefix/zeron-macos-$arch/zeron"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/licenses/fonts"
arm=$prefix/zeron-macos-aarch64/zeron x86=$prefix/zeron-macos-x86_64/zeron
if [[ -f $arm && -f $x86 ]] && command -v lipo >/dev/null; then
  echo "zeron-app-bundle: universal binary (lipo aarch64 + x86_64)"
  lipo -create -output "$app/Contents/MacOS/zeron" "$arm" "$x86"
else
  [[ -f $arm && -f $x86 ]] && echo "zeron-app-bundle: lipo not found; bundling $arch only"
  cp "$prefix/zeron-macos-$arch/zeron" "$app/Contents/MacOS/zeron"
fi
chmod 755 "$app/Contents/MacOS/zeron"
sed "s/__VERSION__/$version/g" "$dist/Info.plist" >"$app/Contents/Info.plist"
printf 'APPL????' >"$app/Contents/PkgInfo"
cp "$dist/zeron.icns" "$app/Contents/Resources/zeron.icns"
cp "$root"/apps/zeron/assets/fonts/licenses/* "$app/Contents/Resources/licenses/fonts/"
cp "$root/apps/zeron/assets/LICENSE.zeron" "$root/apps/zeron/assets/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/licenses/"

if command -v plutil >/dev/null; then plutil -lint "$app/Contents/Info.plist"; fi
if command -v codesign >/dev/null; then
  if [[ -n ${CODESIGN_IDENTITY:-} ]]; then
    codesign --force --options runtime --timestamp --entitlements "$dist/zeron.entitlements" --sign "$CODESIGN_IDENTITY" "$app"
  else
    # Ad-hoc: lets the app launch on Apple silicon (Gatekeeper still asks on first open).
    codesign --force --sign - "$app"
  fi
fi
if command -v lipo >/dev/null; then lipo -info "$app/Contents/MacOS/zeron"; fi
# Self-update payload (apps/zeron/src/lifecycle/update.zig, same name as the Rust
# release's): zeron-<ver>-macos-<arm64|x86_64>-app.tar.gz with Zeron.app at its root.
tarch=$arch; [[ $arch == aarch64 ]] && tarch=arm64
tar -czf "$prefix/zeron-$version-macos-$tarch-app.tar.gz" -C "$prefix" Zeron.app
echo "zeron-app-bundle: $prefix/zeron-$version-macos-$tarch-app.tar.gz"
echo "zeron-app-bundle: $app (version $version)"
find "$app" -type f | sed "s|^$prefix/||" | sort
