#!/usr/bin/env bash
# Seed the fixture once, then benchmark every client configuration, interleaved
# (run 1 of each config, then run 2 of each, ...) so slow drift on the runner hits
# all of them alike. Used by .github/workflows/benchmark.yml; runs locally too.
#
#   ENGINE=zeron-engine RUST_APP=zeron-src/target-clean/release/zeron \
#   ZIG_FAST=zig-out/fast/bin/zeron ZIG_SAFE=zig-out/safe/bin/zeron \
#   RUNS=5 OUT=bench-results PLAIN=1 bench/run_all.sh
#
# Env: ENGINE (required), RUST_APP / ZIG_FAST / ZIG_SAFE (each optional: a missing
# one is skipped), RUNS (default 5), OUT (default bench-results), PLAIN=1 adds
# zig-safe-plain (ZERON_LIQUID_GLASS=0 + zpui-drawn instead of AppKit controls),
# CHATS / TURNS / SEED_REPEAT (fixture size), TITLE (summary heading).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${ENGINE:?ENGINE=<zeron-engine binary>}"
RUNS=${RUNS:-5} OUT=${OUT:-bench-results} CHATS=${CHATS:-150} TURNS=${TURNS:-40} SEED_REPEAT=${SEED_REPEAT:-6}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/zeron-bench.XXXXXX")
fixture=$work/fixture

# --- 1. fixture: many chats + one long transcript, through the engine's own RPC ---
echo "::group::seed fixture ($CHATS chats, $TURNS turns x repeat $SEED_REPEAT)"
ZERON_DATA_DIR=$fixture ZERON_IPC_PORT=27990 ZERON_HARNESS=mock ZERON_MOCK_REPEAT=$SEED_REPEAT \
  ZERON_MOCK_CODE=1 ZERON_MOCK_TABLE=1 ZERON_MOCK_MEND=1 "$ENGINE" headless >"$OUT/seed-engine.log" 2>&1 &
seed_pid=$!
python3 "$here/seed_fixture.py" --port 27990 --chats "$CHATS" --turns "$TURNS" \
  --space-path "$work/project" --out "$fixture/bench-fixture.json"
kill "$seed_pid"; wait "$seed_pid" || true
rm -f "$fixture/engine.lock" "$fixture/device-id.lock"
du -sh "$fixture"
cp "$fixture/bench-fixture.json" "$OUT/fixture.json"
echo "::endgroup::"

# --- 2. interleaved runs ---
configs=()
[[ -n ${RUST_APP:-} && -x ${RUST_APP:-/nonexistent} ]] && configs+=("rust|$RUST_APP|")
[[ -n ${ZIG_FAST:-} && -x ${ZIG_FAST:-/nonexistent} ]] && configs+=("zig-fast|$ZIG_FAST|")
[[ -n ${ZIG_SAFE:-} && -x ${ZIG_SAFE:-/nonexistent} ]] && configs+=("zig-safe|$ZIG_SAFE|")
[[ ${PLAIN:-0} == 1 && -n ${ZIG_SAFE:-} && -x ${ZIG_SAFE:-/nonexistent} ]] &&
  configs+=("zig-safe-plain|$ZIG_SAFE|ZERON_LIQUID_GLASS=0 ZERON_BENCH_NATIVE_CONTROLS=0")
port=28100
for ((i = 1; i <= RUNS; i++)); do
  for c in ${configs[@]+"${configs[@]}"}; do
    IFS='|' read -r label app envs <<<"$c"
    echo "::group::$label run $i/$RUNS"
    extra=()
    for kv in $envs; do extra+=(--env "$kv"); done
    mkdir -p "$OUT/logs"
    TMPDIR="$OUT/logs" python3 "$here/run_bench.py" --client "$label" --app "$app" --engine "$ENGINE" --fixture "$fixture" \
      --runs 1 --port-base "$port" --out "$OUT/runs/$label-$i.json" ${extra[@]+"${extra[@]}"} ${BENCH_ARGS:-} || echo "::warning::$label run $i failed"
    port=$((port + 10))
    echo "::endgroup::"
  done
done

# --- 3. summary ---
python3 "$here/summarize.py" --title "${TITLE:-$(uname -sm)}" --out-dir "$OUT" \
  ${STATIC:+--static "$STATIC"} "$OUT"/runs/*.json
