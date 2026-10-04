#!/usr/bin/env bash
# Write the self-update feed's manifest.json (and latest.txt) for release artifacts,
# in the Rust release workflow's format (crates/update `Manifest`):
#   {"version":"<ver>","files":{"<artifact>":{"sha256":"<hex>"}, ...}}
# Usage: release-manifest.sh <version> <out dir> <artifact>...
# Serve <out dir> (with the artifacts copied next to it) and point the app at it with
# ZERON_RELEASES_URL=<base url> (or build with -Dzeron-releases-url=<base url>).
set -euo pipefail
version=$1 out=$2; shift 2
mkdir -p "$out"
{
  printf '{"version":"%s","files":{' "$version"
  sep=
  for f in "$@"; do
    sum=$( (command -v sha256sum >/dev/null && sha256sum "$f" || shasum -a 256 "$f") | cut -d' ' -f1)
    printf '%s"%s":{"sha256":"%s"}' "$sep" "$(basename "$f")" "$sum"
    sep=,
    [[ $(dirname "$f") -ef $out ]] || cp -f "$f" "$out/"
  done
  printf '}}\n'
} >"$out/manifest.json"
printf '%s\n' "$version" >"$out/latest.txt"
cat "$out/manifest.json"
