#!/usr/bin/env bash
# Screenshot the zeron app under Xvfb + lavapipe.
#   apps/zeron/scripts/shot.sh <out.png> [zeron args...]
# Env: SHOT_SIZE (screen, default 1600x1000), SHOT_DELAY (s, default 3),
#      SHOT_ACTIONS (a shell snippet run with DISPLAY set before capture, e.g. xdotool),
#      SHOT_CROP (WxH+X+Y crop of the root window).
set -euo pipefail
out=$1; shift
root=$(cd "$(dirname "$0")/../../.." && pwd)
bin=$root/zig-out/bin/zeron
size=${SHOT_SIZE:-1600x1000}
n=$((100 + RANDOM % 50)); while [ -e /tmp/.X$n-lock ]; do n=$((n + 1)); done; disp=:$n
Xvfb $disp -screen 0 ${size}x24 -nolisten tcp >/dev/null 2>&1 &
xpid=$!
trap 'kill $apid 2>/dev/null || true; kill $xpid 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do [ -e /tmp/.X11-unix/X${disp#:} ] && break; sleep 0.1; done
export DISPLAY=$disp VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json
"$bin" "$@" >/tmp/zeron-shot.log 2>&1 &
apid=$!
sleep ${SHOT_DELAY:-3}
if [ -n "${SHOT_ACTIONS:-}" ]; then eval "$SHOT_ACTIONS"; sleep ${SHOT_SETTLE:-1}; fi
if [ -n "${SHOT_CROP:-}" ]; then
  import -window root -crop "$SHOT_CROP" +repage "$out"
else
  import -window root "$out"
fi
echo "saved $out"
