#!/usr/bin/env python3
"""Run one client through the benchmark timeline N times and write JSON results.

    python3 bench/run_bench.py --client zig --app zig-out/bin/zeron \
        --engine zig-out/zeron-engine --fixture $FIXTURE --runs 5 --out results/zig.json

Per launch: copy the seeded fixture data dir, start the engine (`<engine> headless`,
mock harness) on it, wait for IPC, optionally drop the OS file cache (`--cold`),
spawn the client with ZERON_BENCH=1 (apps/zeron/src/bench.zig, or the Rust hook
bench/rust/bench_hook.rs) and follow its stderr markers. Meanwhile a sampler thread
reads the client's RSS and cumulative CPU time every --sample-ms; at each phase end
the harness also records the footprint (macOS `footprint`, Linux PSS). When the app
prints `stream_ready` the harness queues a mock run on the long chat over RPC.

Result per launch: startup times relative to spawn (first frame, interactive shell,
long transcript loaded), memory per phase, CPU% per phase, frame intervals and
draw durations (scroll, stream). bench/summarize.py aggregates runs."""

import argparse
import json
import os
import platform
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from zeron_rpc import Rpc, wait_ready  # noqa: E402

IS_MAC = sys.platform == "darwin"
CLK_TCK = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100


def log(*a):
    print("run_bench:", *a, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- process stats
def parse_ps_time(s):
    # [[dd-]hh:]mm:ss[.cc]
    s = s.strip()
    days = 0
    if "-" in s:
        d, s = s.split("-", 1)
        days = int(d)
    parts = [float(p) for p in s.split(":")]
    secs = 0.0
    for p in parts:
        secs = secs * 60 + p
    return days * 86400 + secs


def proc_sample(pid):
    """(rss_kb, cpu_seconds) or None when the process is gone."""
    if IS_MAC:
        try:
            out = subprocess.run(["ps", "-o", "rss=,time=", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout.split()
        except subprocess.TimeoutExpired:
            return None
        if len(out) < 2:
            return None
        return int(out[0]), parse_ps_time(out[1])
    try:
        with open(f"/proc/{pid}/stat") as f:
            st = f.read().rsplit(")", 1)[1].split()
        with open(f"/proc/{pid}/status") as f:
            rss = next((int(l.split()[1]) for l in f if l.startswith("VmRSS:")), 0)
        return rss, (int(st[11]) + int(st[12])) / CLK_TCK
    except (OSError, IndexError, ValueError):
        return None


def memory_report(pid, path):
    """macOS: a memory breakdown of the idle client (footprint categories, vmmap regions,
    malloc zones and the largest allocation classes) for the first warm launch's logs."""
    if not IS_MAC:
        return
    with open(path, "w") as f:
        for cmd in (["footprint", "-v", str(pid)], ["vmmap", "-summary", str(pid)], ["heap", "-s", str(pid)]):
            f.write(f"$ {' '.join(cmd)}\n")
            f.flush()
            try:
                out = subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
            except (OSError, subprocess.TimeoutExpired) as e:
                out = f"{e}\n"
            if cmd[0] == "heap":  # the zone summary and the 60 largest classes
                out = "\n".join(out.splitlines()[:120])
            f.write(out + "\n")


def footprint_kb(pid):
    """macOS phys_footprint (what Activity Monitor shows as Memory); Linux PSS."""
    if IS_MAC:
        try:
            out = subprocess.run(["footprint", str(pid)], capture_output=True, text=True, timeout=20).stdout
        except (OSError, subprocess.TimeoutExpired):
            return None
        for line in out.splitlines():
            m = re.search(r"Footprint:\s*([0-9.]+)\s*(KB|MB|GB)", line, re.I)
            if m:
                return float(m.group(1)) * {"KB": 1, "MB": 1024, "GB": 1024 * 1024}[m.group(2).upper()]
        return None
    try:
        with open(f"/proc/{pid}/smaps_rollup") as f:
            for line in f:
                if line.startswith("Pss:"):
                    return int(line.split()[1])
    except OSError:
        return None
    return None


class Sampler(threading.Thread):
    def __init__(self, pid, interval):
        super().__init__(daemon=True)
        self.pid, self.interval = pid, interval
        self.samples = []  # (t, rss_kb, cpu_s)
        self.stop = threading.Event()

    def run(self):
        while not self.stop.is_set():
            s = proc_sample(self.pid)
            if s is None:
                break
            self.samples.append((time.time(), s[0], s[1]))
            self.stop.wait(self.interval)

    def at(self, t):
        best = None
        for s in self.samples:
            if s[0] <= t:
                best = s
            else:
                break
        return best

    def cpu_pct(self, t0, t1):
        inside = [s for s in self.samples if t0 <= s[0] <= t1]
        if len(inside) < 2:
            return None
        a, b = inside[0], inside[-1]
        return 100.0 * (b[2] - a[2]) / max(1e-6, b[0] - a[0])

    def rss_max(self, t0, t1):
        inside = [s[1] for s in self.samples if t0 <= s[0] <= t1]
        return max(inside) if inside else None


class PowerMetrics:
    """Best effort: `sudo -n powermetrics --samplers tasks` (per-process CPU ms/s)."""

    def __init__(self, out_path, interval_ms):
        self.path = out_path
        self.proc = None
        if not IS_MAC or os.environ.get("BENCH_POWERMETRICS", "1") == "0":
            return
        if subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode != 0:
            return
        try:
            self.proc = subprocess.Popen(
                ["sudo", "-n", "powermetrics", "--samplers", "tasks", "--show-process-energy",
                 "-i", str(interval_ms), "-f", "plist", "-o", out_path],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            self.proc = None

    def finish(self, pid, phases):
        if self.proc is None:
            return None
        subprocess.run(["sudo", "-n", "kill", "-INT", str(self.proc.pid)], capture_output=True)
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            subprocess.run(["sudo", "-n", "kill", "-KILL", str(self.proc.pid)], capture_output=True)
        try:
            import plistlib
            raw = open(self.path, "rb").read()
        except OSError:
            return None
        samples = []
        for chunk in raw.split(b"\0"):
            chunk = chunk.strip()
            if not chunk:
                continue
            try:
                p = plistlib.loads(chunk)
            except Exception:
                continue
            t = p.get("timestamp")
            ts = t.timestamp() if hasattr(t, "timestamp") else None
            for task in p.get("tasks", []):
                if task.get("pid") == pid:
                    samples.append((ts, task.get("cputime_ms_per_s"), task.get("energy_impact")))
        if not samples:
            return {"available": True, "samples": 0}
        out = {"available": True, "samples": len(samples), "phases": {}}
        for name, (t0, t1) in phases.items():
            inside = [s for s in samples if s[0] is not None and t0 <= s[0] <= t1]
            if inside:
                out["phases"][name] = {
                    "cpu_pct": statistics.mean(s[1] or 0 for s in inside) / 10.0,
                    "energy_impact": statistics.mean(s[2] or 0 for s in inside),
                }
        return out


# ---------------------------------------------------------------- stderr follower
DURATION_RE = re.compile(r"frame duration: ([0-9.]+)(ns|µs|us|ms|s)\b")
UNIT = {"ns": 1e-6, "µs": 1e-3, "us": 1e-3, "ms": 1.0, "s": 1000.0}


class Follower(threading.Thread):
    def __init__(self, stream, logf, on_marker):
        super().__init__(daemon=True)
        self.stream, self.logf, self.on_marker = stream, logf, on_marker
        self.markers = {}
        self.boot = {}  # "boot:<phase>" startup steps, first occurrence (apps/zeron/src/bench.zig)
        self.order = []
        self.phase = "boot"
        self.draws = {}  # phase -> [ms]

    def run(self):
        for raw in iter(self.stream.readline, b""):
            line = raw.decode("utf-8", "replace")
            m = DURATION_RE.search(line)
            if m:
                self.draws.setdefault(self.phase, []).append(float(m.group(1)) * UNIT[m.group(2)])
                continue
            self.logf.write(line)
            i = line.find("zeron-bench {")
            if i < 0:
                continue
            try:
                ev = json.loads(line[i + len("zeron-bench "):])
            except ValueError:
                continue
            name = ev.get("ev")
            ev["t_s"] = ev["t"] / 1e6
            if name.startswith("boot:"):
                self.boot.setdefault(name[5:], ev["t_s"])
                continue
            self.markers[name] = ev
            self.order.append(name)
            self.phase = {"scroll_start": "scroll", "scroll_end": "after_scroll", "stream_start": "stream",
                          "stream_end": "after_stream", "open_long": "open_long", "long_loaded": "settle1",
                          "idle_start": "idle"}.get(name, self.phase)
            self.on_marker(name, ev)


# ---------------------------------------------------------------- stats helpers
def pct(v, p):
    if not v:
        return None
    s = sorted(v)
    k = (len(s) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def frame_stats(intervals, draws, nominal_ms):
    out = {"frames": len(intervals)}
    if intervals:
        out.update({
            "interval_p50_ms": pct(intervals, 50), "interval_p95_ms": pct(intervals, 95),
            "interval_p99_ms": pct(intervals, 99), "interval_max_ms": max(intervals),
            # Missed vsyncs: an interval of k nominal periods hides k-1 frames.
            "dropped_frames": int(sum(max(0, round(dt / nominal_ms) - 1) for dt in intervals)),
            "long_frames_pct": 100.0 * sum(1 for dt in intervals if dt > 1.5 * nominal_ms) / len(intervals),
        })
    if draws:
        out.update({"draws": len(draws), "draw_p50_ms": pct(draws, 50), "draw_p95_ms": pct(draws, 95),
                    "draw_p99_ms": pct(draws, 99), "draw_max_ms": max(draws)})
    return out


# ---------------------------------------------------------------- one launch
def drop_caches():
    if IS_MAC:
        r = subprocess.run(["sudo", "-n", "purge"], capture_output=True)
    else:
        subprocess.run(["sync"])
        r = subprocess.run(["sudo", "-n", "sh", "-c", "echo 3 > /proc/sys/vm/drop_caches"], capture_output=True)
    return r.returncode == 0


def launch(a, fixture, run_ix, cold, workdir):
    data = os.path.join(workdir, f"data-{run_ix}-{'cold' if cold else 'warm'}")
    shutil.copytree(a.fixture, data, symlinks=True)
    for stale in ("engine.lock", "device-id.lock"):
        try:
            os.remove(os.path.join(data, stale))
        except OSError:
            pass
    port = a.port_base + run_ix * 2 + (0 if cold else 1)
    env = dict(os.environ)
    env.update({"ZERON_DATA_DIR": data, "ZERON_IPC_PORT": str(port), "ZERON_HARNESS": "mock",
                "ZERON_MOCK_REPEAT": str(a.stream_repeat), "ZERON_MOCK_DELAY_MS": str(a.stream_delay_ms),
                "ZERON_MOCK_CODE": "1", "ZERON_MOCK_TABLE": "1", "ZERON_MOCK_MEND": "1",
                "ZERON_DISABLE_NOTIFICATIONS": "1", "ZERON_DISABLE_SOUND": "1", "ZERON_AUTO_UPDATE": "0"})
    eng_log = open(os.path.join(workdir, f"engine-{run_ix}-{cold}.log"), "wb")
    engine = subprocess.Popen([a.engine, "headless"], env=env, stdout=eng_log, stderr=subprocess.STDOUT)
    rpc = None
    try:
        rpc = wait_ready(port, timeout=90)
        if cold:
            cache_dropped = drop_caches()
            time.sleep(1.0)
        else:
            cache_dropped = None
        cenv = dict(env)
        cenv.update({"ZERON_BENCH": "1", "ZED_MEASUREMENTS": "1",
                     "ZERON_BENCH_LONG_CHAT": fixture["longChat"], "ZERON_BENCH_SHORT_CHAT": fixture["shortChat"],
                     "ZERON_BENCH_LONG_MIN": str(fixture["longChatMessages"]),
                     "ZERON_BENCH_IDLE_S": str(a.idle_s), "ZERON_BENCH_SETTLE_S": str(a.settle_s),
                     "ZERON_BENCH_SCROLL_FRAMES": str(a.scroll_frames), "ZERON_BENCH_SCROLL_PX": str(a.scroll_px),
                     "RUST_LOG": "warn"})
        for kv in a.env:
            k, v = kv.split("=", 1)
            cenv[k] = v
        app_log = open(os.path.join(workdir, f"app-{run_ix}-{cold}.log"), "w")
        pm = PowerMetrics(os.path.join(workdir, f"powermetrics-{run_ix}-{cold}.plist"), 500)
        done = threading.Event()
        snapshots = {}
        proc_holder = {}

        def on_marker(name, ev):
            pid = proc_holder["p"].pid
            if name in ("idle_end", "settle1_end", "settle2_end", "done", "shell_loaded"):
                snapshots[name] = {"footprint_kb": footprint_kb(pid), "rss_kb": (proc_sample(pid) or (None,))[0]}
            if name == "idle_start" and run_ix == 0 and not cold:
                # Inside the idle window (other tools only read the process; its CPU is unaffected).
                rep_path = os.path.join(workdir, f"memory-{run_ix}.log")
                threading.Timer(2.0, memory_report, args=(pid, rep_path)).start()
            if name == "stream_ready":
                threading.Thread(target=queue_stream, args=(port, fixture), daemon=True).start()
            if name in ("done", "error"):
                done.set()

        t_spawn = time.time()
        proc = subprocess.Popen([a.app] + a.app_args, env=cenv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        proc_holder["p"] = proc
        sampler = Sampler(proc.pid, a.sample_ms / 1000.0)
        sampler.start()
        follower = Follower(proc.stderr, app_log, on_marker)
        follower.start()
        ok = done.wait(timeout=a.timeout_s)
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        sampler.stop.set()
        follower.join(timeout=5)
        app_log.close()

        mk = follower.markers
        res = {"run": run_ix, "cold": cold, "cache_dropped": cache_dropped, "exit": proc.returncode,
               "completed": ok and "done" in mk, "error": mk.get("error")}

        def rel(name):
            return (mk[name]["t_s"] - t_spawn) * 1000.0 if name in mk else None

        ff = mk.get("first_frame") or {}
        res["viewport"] = {k: ff.get(k) for k in ("w", "h", "scale")}
        res["startup_ms"] = {"window_open": rel("window_open"), "first_frame": rel("first_frame"),
                             "shell_loaded": rel("shell_loaded")}
        # Startup steps (Zig client only): ms from the spawn, in the order reached.
        res["boot_ms"] = {k: (t - t_spawn) * 1000.0 for k, t in sorted(follower.boot.items(), key=lambda kv: kv[1])}
        if "open_long" in mk and "long_loaded" in mk:
            res["open_long_ms"] = (mk["long_loaded"]["t_s"] - mk["open_long"]["t_s"]) * 1000.0

        def span(a_, b_):
            return (mk[a_]["t_s"], mk[b_]["t_s"]) if a_ in mk and b_ in mk else None

        phases = {"idle": span("idle_start", "idle_end"), "idle_long": span("long_loaded", "settle1_end"),
                  "scroll": span("scroll_start", "scroll_end"), "idle_after_scroll": span("scroll_end", "settle2_end"),
                  "stream": span("stream_start", "stream_end")}
        cpu = {}
        for name, sp in phases.items():
            if sp:
                t0, t1 = sp
                if name.startswith("idle"):
                    t0 += 1.0  # let the last frame and any trailing work settle
                cpu[name] = sampler.cpu_pct(t0, t1)
        res["cpu_pct"] = cpu
        res["memory_kb"] = {
            "idle": snapshots.get("idle_end"), "after_open_long": snapshots.get("settle1_end"),
            "after_scroll": snapshots.get("settle2_end"), "end": snapshots.get("done"),
            "peak_rss": max((s[1] for s in sampler.samples), default=None),
        }
        nominal = a.nominal_ms
        res["scroll"] = frame_stats((mk.get("scroll_end") or {}).get("intervals_ms") or [], follower.draws.get("scroll", []), nominal)
        res["stream"] = frame_stats((mk.get("stream_end") or {}).get("intervals_ms") or [], follower.draws.get("stream", []), nominal)
        res["powermetrics"] = pm.finish(proc.pid, {k: v for k, v in phases.items() if v})
        eng_s = proc_sample(engine.pid)
        res["engine_rss_kb"] = eng_s[0] if eng_s else None
        return res
    finally:
        if rpc:
            rpc.close()
        engine.send_signal(signal.SIGTERM)
        try:
            engine.wait(timeout=15)
        except subprocess.TimeoutExpired:
            engine.kill()
            engine.wait()
        eng_log.close()
        # Keep the clients' and engine's own logs ({data}/logs) with the run's logs.
        try:
            shutil.copytree(os.path.join(data, "logs"), os.path.join(workdir, f"datalogs-{run_ix}-{cold}"), dirs_exist_ok=True)
        except OSError:
            pass
        if not a.keep:
            shutil.rmtree(data, ignore_errors=True)


def queue_stream(port, fixture):
    try:
        r = Rpc(port)
        r.call("QueueCommand", {"chatId": fixture["longChat"], "command": {
            "kind": "run", "messageId": str(uuid.uuid4()),
            "request": {"prompt": "Bench: stream one more long reply.", "model": None, "reasoning": None,
                        "cwd": fixture["spacePath"], "sandbox": "workspace-write", "autoApprove": True, "resume": None}}})
        r.close()
    except Exception as e:  # noqa: BLE001
        log("queue_stream failed:", e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--client", required=True, help="label: rust | zig-fast | zig-safe | zig-plain …")
    ap.add_argument("--app", required=True)
    ap.add_argument("--app-arg", dest="app_args", action="append", default=[])
    ap.add_argument("--engine", required=True)
    ap.add_argument("--fixture", required=True, help="seeded data dir (contains bench-fixture.json)")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--no-cold", action="store_true")
    ap.add_argument("--env", action="append", default=[], help="extra client env K=V")
    ap.add_argument("--out", required=True)
    ap.add_argument("--port-base", type=int, default=28100)
    ap.add_argument("--idle-s", type=float, default=6)
    ap.add_argument("--settle-s", type=float, default=4)
    ap.add_argument("--scroll-frames", type=int, default=300)
    ap.add_argument("--scroll-px", type=float, default=40)
    ap.add_argument("--stream-repeat", type=int, default=40)
    ap.add_argument("--stream-delay-ms", type=int, default=12)
    ap.add_argument("--sample-ms", type=int, default=200)
    ap.add_argument("--nominal-ms", type=float, default=1000.0 / 60)
    ap.add_argument("--timeout-s", type=float, default=240)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    fixture = json.load(open(os.path.join(a.fixture, "bench-fixture.json")))
    # The space path recorded at seed time must exist where the copy runs.
    os.makedirs(fixture["spacePath"], exist_ok=True)
    workdir = tempfile.mkdtemp(prefix=f"zeron-bench-{a.client}-")
    results = []
    for i in range(a.runs):
        for cold in ([False] if a.no_cold else [True, False]):
            log(f"{a.client}: run {i + 1}/{a.runs} {'cold' if cold else 'warm'}")
            r = launch(a, fixture, i, cold, workdir)
            log(f"{a.client}: -> completed={r['completed']} startup={r['startup_ms']} cpu={r['cpu_pct']}")
            results.append(r)
    out = {"client": a.client, "app": os.path.abspath(a.app), "platform": platform.platform(),
           "machine": platform.machine(), "fixture": {k: fixture[k] for k in ("turns", "longChatMessages", "longChatTextChars") if k in fixture} | {"chats": len(fixture["chats"])},
           "params": {k: getattr(a, k) for k in ("idle_s", "settle_s", "scroll_frames", "scroll_px", "stream_repeat", "stream_delay_ms", "sample_ms", "nominal_ms")} | {"env": a.env},
           "logs": workdir, "runs": results}
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(out, f, indent=1)
    log("wrote", a.out)


if __name__ == "__main__":
    main()
