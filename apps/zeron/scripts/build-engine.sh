#!/usr/bin/env bash
# Build the bundled engine `zeron-engine` (apps/zeron/engine-host: zeron's `headless` /
# `mcp` / `login` / `logout` / `status` without the gpui UI) from a zeron checkout.
#
#   build-engine.sh <zeron-src> <out-file> [rust-target-triple]
#
# <zeron-src> must be the commit tools/upstream/map.json pins (the protocol the Zig
# client was ported against); a mismatch is reported, not fatal (local dev trees).
# The crate is staged in $ZERON_ENGINE_STAGE (default <repo>/zig-out/engine-host) with
# upstream's Cargo.lock, so shared dependencies build at the versions zeron pins.
# Env: ZERON_ENGINE_PROFILE=release|debug (default release); on macOS
# MACOSX_DEPLOYMENT_TARGET defaults to 12.0 (Info.plist LSMinimumSystemVersion).
set -euo pipefail
src=$(cd "$1" && pwd) out=$2 triple=${3:-}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
host=$root/apps/zeron/engine-host
stage=${ZERON_ENGINE_STAGE:-$root/zig-out/engine-host}
profile=${ZERON_ENGINE_PROFILE:-release}

[[ -f $src/crates/engine/Cargo.toml && -f $src/apps/zeron/src/paths.rs ]] || {
  echo "error: $src is not a zeron checkout (crates/engine, apps/zeron/src/paths.rs missing)" >&2
  exit 1
}
want=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["upstreams"]["zeron"]["pinned"])' "$root/tools/upstream/map.json" 2>/dev/null || true)
have=$(git -C "$src" rev-parse HEAD 2>/dev/null || true)
if [[ -n $want && -n $have && $want != "$have" ]]; then
  echo "warning: $src is at $have, but tools/upstream/map.json pins zeron $want" >&2
fi
# [workspace.package] version = "x.y.z"
version=$(awk '/^\[workspace.package\]/{p=1;next} /^\[/{p=0} p&&/^version *=/{gsub(/[" ]/,"",$0); sub(/version=/,""); print; exit}' "$src/Cargo.toml")
[[ -n $version ]] || { echo "error: no [workspace.package] version in $src/Cargo.toml" >&2; exit 1; }

mkdir -p "$stage/src"
# Only rewrite the manifest when it changes (keeps cargo's fingerprints warm).
manifest=$(sed -e "s|@ZERON_SRC@|$src|g" -e "s|@VERSION@|$version|g" "$host/Cargo.toml.in")
if [[ ! -f $stage/Cargo.toml ]] || [[ $(cat "$stage/Cargo.toml") != "$manifest" ]]; then
  printf '%s\n' "$manifest" >"$stage/Cargo.toml"
  cp "$src/Cargo.lock" "$stage/Cargo.lock"
fi
[[ -f $stage/Cargo.lock ]] || cp "$src/Cargo.lock" "$stage/Cargo.lock"
cp "$host/src/main.rs" "$stage/src/main.rs"
cp "$src/apps/zeron/src/paths.rs" "$stage/src/paths.rs"
cp "$src/apps/zeron/src/auth_cli.rs" "$stage/src/auth_cli.rs"
# The pinned toolchain (zeron's rust-toolchain.toml: stable).
[[ -f $src/rust-toolchain.toml ]] && cp "$src/rust-toolchain.toml" "$stage/rust-toolchain.toml"

case $(uname -s) in Darwin) export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-12.0} ;; esac
args=(build --manifest-path "$stage/Cargo.toml" --bin zeron-engine)
[[ $profile == release ]] && args+=(--release)
[[ -n $triple ]] && args+=(--target "$triple")
target_dir=${CARGO_TARGET_DIR:-$stage/target}
echo "build-engine: zeron $version ($have) → $out${triple:+ [$triple]} ($profile)"
(cd "$stage" && CARGO_TARGET_DIR=$target_dir cargo "${args[@]}")
built=$target_dir/${triple:+$triple/}$profile/zeron-engine
mkdir -p "$(dirname "$out")"
cp -f "$built" "$out"
chmod 755 "$out"
echo "build-engine: $out ($(du -h "$out" | cut -f1))"
