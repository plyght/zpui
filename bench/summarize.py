#!/usr/bin/env python3
"""Aggregate bench results into summary.json + summary.md.

    python3 bench/summarize.py --title "macos-15-intel" --out-dir results \
        results/run-*.json [--static results/static.json]

Every number is the median over runs, with the spread as (min–max) and n. Cold and
warm launches are reported separately for startup; the other phases pool every
completed launch (the page cache only matters until the window is up)."""

import argparse
import json
import os
import statistics


def med(v):
    v = [x for x in v if x is not None]
    if not v:
        return None
    return {"median": statistics.median(v), "min": min(v), "max": max(v), "n": len(v)}


def get(d, *path):
    for p in path:
        if d is None:
            return None
        d = d.get(p) if isinstance(d, dict) else None
    return d


def summarize(res):
    runs = [r for r in res["runs"] if r.get("completed")]
    vps = {json.dumps(r.get("viewport"), sort_keys=True) for r in runs if r.get("viewport")}
    out = {"client": res["client"], "runs_total": len(res["runs"]), "runs_completed": len(runs),
           "viewports": sorted(vps),
           "platform": res.get("platform"), "machine": res.get("machine"), "fixture": res.get("fixture"),
           "params": res.get("params")}
    for kind, sel in (("cold", True), ("warm", False)):
        rs = [r for r in runs if r["cold"] == sel]
        out[f"startup_{kind}"] = {k: med([get(r, "startup_ms", k) for r in rs]) for k in ("window_open", "first_frame", "shell_loaded")}
        # Startup steps (Zig client's boot:<phase> markers), in the order first reached.
        steps = []
        for r in rs:
            for k in (r.get("boot_ms") or {}):
                if k not in steps:
                    steps.append(k)
        if steps:
            out[f"boot_{kind}"] = {k: med([get(r, "boot_ms", k) for r in rs]) for k in steps}
    out["open_long_ms"] = med([r.get("open_long_ms") for r in runs])
    out["memory_mb"] = {}
    for phase in ("idle", "after_open_long", "after_scroll"):
        out["memory_mb"][phase] = {
            "rss": med([(get(r, "memory_kb", phase, "rss_kb") or 0) / 1024 or None for r in runs]),
            "footprint": med([(get(r, "memory_kb", phase, "footprint_kb") or 0) / 1024 or None for r in runs]),
        }
    out["memory_mb"]["peak_rss"] = med([(get(r, "memory_kb", "peak_rss") or 0) / 1024 or None for r in runs])
    out["engine_rss_mb"] = med([(r.get("engine_rss_kb") or 0) / 1024 or None for r in runs])
    out["cpu_pct"] = {p: med([get(r, "cpu_pct", p) for r in runs]) for p in ("idle", "idle_long", "scroll", "idle_after_scroll", "stream")}
    pm = [r.get("powermetrics") for r in runs if r.get("powermetrics") and r["powermetrics"].get("phases")]
    if pm:
        out["powermetrics_cpu_pct"] = {p: med([get(x, "phases", p, "cpu_pct") for x in pm]) for p in ("idle", "idle_long", "scroll", "stream")}
        out["powermetrics_energy"] = {p: med([get(x, "phases", p, "energy_impact") for x in pm]) for p in ("idle", "idle_long", "scroll", "stream")}
    for phase in ("scroll", "stream"):
        out[phase] = {k: med([get(r, phase, k) for r in runs]) for k in (
            "frames", "interval_p50_ms", "interval_p95_ms", "interval_p99_ms", "dropped_frames", "long_frames_pct",
            "draw_p50_ms", "draw_p95_ms", "draw_p99_ms")}
    return out


def fmt(m, digits=0, unit=""):
    if not m:
        return "–"
    f = f"{{:.{digits}f}}"
    s = f.format(m["median"]) + unit
    if m["n"] > 1:
        s += f" ({f.format(m['min'])}–{f.format(m['max'])})"
    return s


ROWS = [
    ("Startup, cold: first frame (ms)", ("startup_cold", "first_frame"), 0),
    ("Startup, cold: interactive shell (ms)", ("startup_cold", "shell_loaded"), 0),
    ("Startup, warm: first frame (ms)", ("startup_warm", "first_frame"), 0),
    ("Startup, warm: interactive shell (ms)", ("startup_warm", "shell_loaded"), 0),
    ("Open long transcript (ms)", ("open_long_ms",), 0),
    ("RSS idle (MB)", ("memory_mb", "idle", "rss"), 0),
    ("RSS after opening long transcript (MB)", ("memory_mb", "after_open_long", "rss"), 0),
    ("RSS after scrolling (MB)", ("memory_mb", "after_scroll", "rss"), 0),
    ("Footprint idle (MB)", ("memory_mb", "idle", "footprint"), 0),
    ("Footprint after opening long transcript (MB)", ("memory_mb", "after_open_long", "footprint"), 0),
    ("Footprint after scrolling (MB)", ("memory_mb", "after_scroll", "footprint"), 0),
    ("Peak RSS (MB)", ("memory_mb", "peak_rss"), 0),
    ("CPU idle, short chat (%)", ("cpu_pct", "idle"), 1),
    ("CPU idle, long transcript (%)", ("cpu_pct", "idle_long"), 1),
    ("CPU while scrolling (%)", ("cpu_pct", "scroll"), 1),
    ("CPU while streaming (%)", ("cpu_pct", "stream"), 1),
    ("Scroll: frame interval p50 (ms)", ("scroll", "interval_p50_ms"), 1),
    ("Scroll: frame interval p95 (ms)", ("scroll", "interval_p95_ms"), 1),
    ("Scroll: frame interval p99 (ms)", ("scroll", "interval_p99_ms"), 1),
    ("Scroll: dropped frames", ("scroll", "dropped_frames"), 0),
    ("Scroll: draw p50 (ms)", ("scroll", "draw_p50_ms"), 2),
    ("Scroll: draw p95 (ms)", ("scroll", "draw_p95_ms"), 2),
    ("Scroll: draw p99 (ms)", ("scroll", "draw_p99_ms"), 2),
    ("Stream: frame interval p50 (ms)", ("stream", "interval_p50_ms"), 1),
    ("Stream: frame interval p95 (ms)", ("stream", "interval_p95_ms"), 1),
    ("Stream: frame interval p99 (ms)", ("stream", "interval_p99_ms"), 1),
    ("Stream: dropped frames", ("stream", "dropped_frames"), 0),
    ("Stream: draw p50 (ms)", ("stream", "draw_p50_ms"), 2),
    ("Stream: draw p95 (ms)", ("stream", "draw_p95_ms"), 2),
    ("Stream: draw p99 (ms)", ("stream", "draw_p99_ms"), 2),
    ("Engine RSS at end (MB)", ("engine_rss_mb",), 0),
]


def table(sums):
    head = "| Metric | " + " | ".join(s["client"] for s in sums) + " |\n"
    head += "|---|" + "---:|" * len(sums) + "\n"
    body = ""
    for label, path, digits in ROWS:
        body += f"| {label} | " + " | ".join(fmt(get(s, *path), digits) for s in sums) + " |\n"
    body += "| Window (logical px, scale) | " + " | ".join(
        "; ".join(f"{json.loads(v).get('w')}x{json.loads(v).get('h')}@{json.loads(v).get('scale')}" for v in s.get("viewports", [])) or "–"
        for s in sums) + " |\n"
    body += "| Completed runs | " + " | ".join(f"{s['runs_completed']}/{s['runs_total']}" for s in sums) + " |\n"
    return head + body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results", nargs="+")
    ap.add_argument("--title", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--static", help="static.json from bench/static_metrics.py")
    a = ap.parse_args()
    # Files with the same client label (one per interleaved run) are pooled.
    merged = {}
    for p in a.results:
        r = json.load(open(p))
        if r["client"] in merged:
            merged[r["client"]]["runs"].extend(r["runs"])
        else:
            merged[r["client"]] = r
    sums = [summarize(r) for r in merged.values()]
    os.makedirs(a.out_dir, exist_ok=True)
    doc = {"title": a.title, "clients": sums}
    md = f"## {a.title}\n\n"
    if sums:
        s0 = sums[0]
        md += f"Platform: `{s0.get('platform')}` ({s0.get('machine')}). Fixture: {json.dumps(s0.get('fixture'))}.\n\n"
        md += "Median over completed runs, (min–max) in brackets.\n\n" + table(sums) + "\n"
    for s in sums:
        for kind in ("cold", "warm"):
            steps = s.get(f"boot_{kind}")
            if steps:
                md += f"Startup steps, {s['client']}, {kind} (ms from spawn): " + ", ".join(
                    f"{k} {fmt(v)}" for k, v in steps.items()) + "\n\n"
    if a.static and os.path.exists(a.static):
        st = json.load(open(a.static))
        doc["static"] = st
        md += "### Static metrics\n\n```json\n" + json.dumps(st, indent=1) + "\n```\n"
    with open(os.path.join(a.out_dir, "summary.json"), "w") as f:
        json.dump(doc, f, indent=1)
    with open(os.path.join(a.out_dir, "summary.md"), "w") as f:
        f.write(md)
    print(md)


if __name__ == "__main__":
    main()
