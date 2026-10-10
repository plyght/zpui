# Benchmarks: Rust zeron vs the Zig port

This compares the Rust zeron desktop client (zeronsh/zeron, gpui/zui) with the Zig port in
`apps/zeron` (zpui). The question it answers: is anything here worth proposing to the
zeron maintainers?

- **zeron commit for both apps:** `037f4c10d67a38175b2386e776aba54355b4e941` (v0.2.106, the
  `tools/upstream/map.json` pin). The Rust client, the engine and the Zig client's protocol
  pin all come from this one commit. zui `dce5c1f` (zeron's own Cargo pin).
- **Harness:** `.github/workflows/benchmark.yml` (workflow_dispatch) and `bench/`.
- **Runs:**
  - [37836321752](https://github.com/plyght/zpui/actions/runs/37836321752): macos-26 Apple Silicon, complete. Its Linux and Intel jobs failed for harness reasons, fixed afterwards.
  - [37853859030](https://github.com/plyght/zpui/actions/runs/37853859030): ubuntu-24.04, complete. The macos-15-intel job was still running when this report was written; see "macos-15-intel" below.
- **Artifacts:** `bench-<runner>` holds the raw per-launch JSON (`runs/`), `summary.{md,json}`, `static.json` and the app and engine logs. `benchmark-summary` holds the combined summary.

## TL;DR

| | macOS 26, Apple Silicon (Metal) | Linux (Xvfb + lavapipe, software GPU) |
|---|---|---|
| Client binary (as shipped) | Rust 127 MB, which includes the engine (the engine alone is 39 MB). Zig ReleaseSafe 50 MB | Rust 164 MB, which includes the engine (the engine alone is 43 MB). Zig 130 MB unstripped, 50 MB stripped |
| Bundle without the engine | Rust 129 MB (one Mach-O). Zig 52 MB | Rust 166 MB. Zig 129 MB (unstripped, plus the WebKitGTK helper) |
| Warm start to first frame | Rust 925 ms, Zig 533 ms | Rust 247 ms, Zig 101 ms |
| Warm start to interactive shell | **Rust 1.39 s, Zig 5.58 s** (a Zig bug, since fixed; re-run: Rust 1.07 s, Zig ReleaseSafe 0.91 s; see below) | Rust 422 ms, Zig 347 ms |
| RSS / footprint when idle | Rust 157 / 82 MB, Zig 137 / 82 MB | Rust 232 / 210 MB, Zig 160 / 136 MB (PSS) |
| CPU when idle | Rust 2.8 %, Zig 0.9 % (powermetrics: 4.8 % vs 1.6 %) | Rust 15.6 %, Zig 0.0 % |
| CPU while streaming | **Rust 12 %, Zig 60 %; after the pulse-clock fix (`2993f91`): Rust 12.5 %, Zig 6.5–10 %** | Rust 152 %, Zig 250 % (software GPU) |
| Draws per streamed reply (about 4 s) | **Rust about 50, Zig about 250 (every vsync); fixed in `2993f91` (30/15 Hz pulse clock)** | Rust 55, Zig 118 (GPU-bound) |
| Scroll frame interval p50 / p95 / p99 | Rust 17.7 / 36.8 / 58.7 ms, Zig 16.7 / 25.3 / 37.7 ms | Rust 48 / 64 / 64 ms, Zig 33.5 / 34.9 / 36.5 ms |
| CPU while scrolling | **Rust 54 %, Zig 69–75 %; after the scroll fixes (`9229e41`): Rust 50 %, Zig 24–26 %** (see "Scrolling CPU" below) | Rust 170 %, Zig 257–273 % (not re-measured) |
| Clean release build (both clients) | Rust 18 min (thin LTO), Zig 9.4 min (ReleaseSafe) | Rust 10 min, Zig 8 min |
| Lines of code (UI side) | Rust: zeron UI crates 211 k + zui 137 k. Zig: app 144 k + zpui 89 k | |

**Recommendation:** share the results with the maintainers and offer one small, well-scoped
upstream fix: the zui X11 backend never starts drawing when no window manager is running.
Don't offer the Zig client as an alternative. None of the port fixes this report was asked
to check also exist in Rust. Details are in the last section.

## Methodology

**Same engine and same data for both clients.** Both clients attach over IPC to the same
`zeron-engine headless` binary: the UI-free engine host in `apps/zeron/engine-host`, built in
release mode from the pinned commit. This is the binary that ships inside the Zig bundle.
The Rust app's own probe-then-attach path is used: with `ZERON_IPC_PORT` set it connects to
a running engine instead of embedding one.

**Fixture.** `bench/seed_fixture.py` builds the fixture through the engine's public RPC
(`Mutate createSpace/createChat/renameChat`, `QueueCommand`). It uses the engine's built-in
mock harness (`ZERON_HARNESS=mock`), with `ZERON_MOCK_REPEAT=6` and the code, table and mend
blocks turned on. The result:

- one project with 150 titled chats;
- a long chat of 40 turns: 80 messages and 196 k characters of markdown, with headings,
  lists, tool calls with output, Rust and TypeScript code blocks and GFM tables;
- a short chat that was active most recently, so both apps land on it at boot.

Each launch gets a fresh copy of the same seeded data directory and a fresh engine process.

**Timeline.** Each client runs the same scripted timeline, which is inert unless
`ZERON_BENCH=1`:

- Zig: `apps/zeron/src/bench.zig`.
- Rust: `bench/rust/bench_hook.rs`. `bench/patch_rust_client.py` copies it into
  `crates/ui/src/` for the benchmark build only, with two small edits to `lib.rs`.

Both write `zeron-bench {...}` markers to stderr:

1. `window_open` right after the main window is created. `first_frame` at the second frame
   callback, which is the first present. Frames are then requested until the short chat's
   transcript is on screen, and `shell_loaded` is written at the frame after it landed.
   This is the "interactive loaded shell" figure.
2. 6 s idle with no frames requested. This gives idle CPU and the idle memory snapshot.
3. Select the long chat (`select_chat` / `WorkspaceStore.selectChat`), then `long_loaded`
   once all 80 rows are in. Then a 4 s settle (memory after opening the long transcript).
4. 300 frames with one synthetic pixel-delta wheel event each (40 px; 150 up, 150 down)
   at (800, 420), dispatched through each framework's `dispatch_event`. Then a 4 s settle
   (memory after scrolling).
5. Scroll to the tail, then the harness queues one more mock run with
   `ZERON_MOCK_REPEAT=40` and `ZERON_MOCK_DELAY_MS=12`: about 4 s of streaming. Frames are
   requested from the first streaming row until it completes.

**What is measured.**

- **Frame interval:** time between frame callbacks, from requesting frames continuously.
- **Draw time:** draw plus present per drawn frame. Rust uses gpui's own
  `ZED_MEASUREMENTS=1` "frame duration" line. Zig uses the same span, through a two-line
  `Window.frame_observer` hook in zpui.
- **Dropped frames:** the sum over intervals of `round(dt/16.67) - 1`.
- **CPU:** `ps` cumulative CPU time sampled every 200 ms. This is % of one core and can
  exceed 100. On macOS, `sudo powermetrics --samplers tasks` gives a second reading.
- **Memory:** RSS. Footprint is macOS `footprint` (phys_footprint) and Linux PSS.
- **Startup:** relative to the harness's `Popen`. Each run is one cold launch, after
  `sudo purge` on macOS or `drop_caches` on Linux, then one warm launch.

**Builds.**

- Rust: `cargo build --release -p zeron`, the release profile with thin LTO and stripped
  symbols, as upstream ships it.
- Zig: ReleaseFast, and ReleaseSafe as shipped.
- Clean build: an empty target or cache directory, after `cargo fetch`; the Zig global
  cache was also empty. Incremental build: append a comment to one client UI source file
  and rebuild.

**Fairness.**

- Same runner, same window request (1320×880, the default for both; the macOS VM's
  1024×768 display clamps both to 1024×674), and the default dark theme.
- Five interleaved rounds (rust, zig-fast, zig-safe, zig-safe-plain, then the next round),
  each with one cold and one warm launch. All 10 launches of every configuration completed.
- `zig-safe-plain` is ReleaseSafe with Liquid Glass off (`ZERON_LIQUID_GLASS=0`) and
  zpui-drawn controls instead of AppKit ones (`ZERON_BENCH_NATIVE_CONTROLS=0`). It only
  matters on macOS.
- Tables report the median, with min–max in brackets.

## Results: macos-26, Apple Silicon (macOS 26.6.2, arm64, Metal)

Run 37836321752. On this VM, Reduce Transparency was on, so AppKit draws the glass solid.
That narrows the gap between the Liquid Glass default and `-plain`.

| Metric | rust | zig-fast | zig-safe | zig-safe-plain |
|---|---:|---:|---:|---:|
| Startup, cold: first frame (ms) | 4409 (3781–8693) | 4724 (3238–5411) | 3689 (3007–3987) | 4005 (3459–5225) |
| Startup, cold: interactive shell (ms) | 5668 (4336–9799) | 8869 (8035–9023) | 7993 (7487–8317) | 8467 (7862–9145) |
| Startup, warm: first frame (ms) | 925 (469–1079) | 807 (464–1015) | 533 (437–864) | 714 (351–1076) |
| Startup, warm: interactive shell (ms) | 1390 (796–1737) | 5613 (970–5831) | 5578 (5418–5628) | 5819 (5609–5930) |
| Open long transcript (ms) | 109 (48–143) | 73 (48–159) | 71 (54–138) | 58 (42–139) |
| RSS idle (MB) | 157 (155–161) | 134 (133–135) | 137 (135–140) | 134 (134–136) |
| RSS after opening long transcript (MB) | 157 (155–162) | 135 (133–135) | 137 (135–141) | 134 (134–136) |
| RSS after scrolling (MB) | 162 (159–164) | 137 (136–137) | 139 (137–143) | 136 (135–137) |
| Footprint idle (MB) | 82 (79–88) | 80 (77–80) | 82 (80–86) | 78 (76–80) |
| Footprint after opening long transcript (MB) | 82 (78–88) | 80 (77–80) | 82 (81–86) | 78 (76–80) |
| Footprint after scrolling (MB) | 82 (80–88) | 81 (81–81) | 84 (82–88) | 79 (77–80) |
| Peak RSS (MB) | 168 (165–170) | 139 (138–140) | 141 (140–143) | 138 (137–140) |
| CPU idle, short chat (%) | 2.8 (2.1–3.7) | 0.9 (0.8–1.3) | 0.9 (0.6–1.0) | 0.6 (0.0–1.0) |
| CPU idle, long transcript (%) | 2.2 (1.6–3.0) | 0.2 (0.0–1.0) | 0.0 (0.0–0.7) | 0.0 (0.0–1.0) |
| CPU while scrolling (%) | 52.7 (48.2–54.9) | 63.1 (49.9–75.1) | 62.0 (53.0–78.4) | 63.3 (49.8–69.0) |
| CPU while streaming (%) | 12.4 (8.9–14.1) | 58.5 (40.4–64.0) | 60.2 (48.4–78.5) | 55.5 (42.6–75.6) |
| Scroll: frame interval p50 (ms) | 17.7 (16.6–21.3) | 16.8 (16.7–19.0) | 16.7 (16.6–20.2) | 16.8 (16.7–17.2) |
| Scroll: frame interval p95 (ms) | 36.8 (20.5–50.2) | 24.4 (19.7–50.4) | 25.3 (19.2–49.5) | 20.2 (19.8–34.4) |
| Scroll: frame interval p99 (ms) | 58.7 (33.4–68.9) | 42.9 (26.5–78.3) | 37.7 (22.7–116.9) | 30.2 (20.8–51.8) |
| Scroll: dropped frames | 101 (8–173) | 22 (8–121) | 22 (6–134) | 8 (1–49) |
| Scroll: draw p50 (ms) | 17.36 (15.64–20.88) | 15.22 (10.17–18.72) | 15.26 (10.05–19.99) | 16.56 (15.71–16.74) |
| Scroll: draw p95 (ms) | 36.42 (20.22–49.87) | 24.30 (18.91–50.34) | 25.00 (18.25–49.38) | 20.04 (19.65–33.53) |
| Scroll: draw p99 (ms) | 58.42 (33.23–64.39) | 42.75 (26.40–78.16) | 37.46 (22.66–116.65) | 30.08 (20.73–51.62) |
| Stream: frame interval p50 (ms) | 16.7 (16.6–16.7) | 16.7 (16.6–17.4) | 16.7 (16.7–17.6) | 16.7 (16.6–17.4) |
| Stream: frame interval p95 (ms) | 20.8 (20.0–23.8) | 20.7 (18.9–44.1) | 21.1 (18.8–34.1) | 21.2 (18.8–44.0) |
| Stream: frame interval p99 (ms) | 27.1 (21.8–32.8) | 26.8 (19.7–69.0) | 25.1 (19.6–59.6) | 32.0 (19.3–65.8) |
| Stream: dropped frames | 4 (0–12) | 4 (0–50) | 4 (0–40) | 7 (0–61) |
| Stream: draw p50 (ms) | 5.67 (3.57–7.66) | 12.30 (9.25–16.92) | 10.55 (9.54–17.19) | 16.57 (8.93–16.94) |
| Stream: draw p95 (ms) | 25.67 (17.45–28.59) | 20.23 (12.45–44.03) | 20.31 (12.53–33.63) | 20.34 (11.93–43.53) |
| Stream: draw p99 (ms) | 30.82 (19.38–58.92) | 26.69 (14.21–68.91) | 24.74 (13.76–59.51) | 31.75 (13.02–65.68) |
| Engine RSS at end (MB) | 56 (51–64) | 58 (52–62) | 56 (53–64) | 55 (50–60) |
| Window (logical px, scale) | 1024x674@1 | 1024x674@1 | 1024x674@1 | 1024x674@1 |
| Completed runs | 10/10 | 10/10 | 10/10 | 10/10 |

powermetrics, macOS's own per-process CPU accounting (% of one core, median of 10):

| | rust | zig-fast | zig-safe | zig-safe-plain |
|---|---:|---:|---:|---:|
| idle, short chat | 4.8 | 2.9 | 1.6 | 1.5 |
| idle, long transcript | 5.9 | 4.6 | 2.1 | 7.9 |
| scrolling | 51.0 | 60.0 | 58.5 | 56.8 |
| streaming | 13.4 | 54.5 | 59.6 | 53.8 |
| energy impact while streaming | 8.1 | 31.9 | 36.2 | 32.2 |

Draws per streamed reply: Rust 46–53. Zig 216–253, which is a draw on every vsync.

## Results: ubuntu-24.04 (x86_64; Xvfb, openbox, Vulkan lavapipe)

Run 37853859030. Rendering here is in software on the CPU, so frame and CPU numbers mostly
measure how much each renderer asks lavapipe to rasterize. They are not GPU numbers.

| Metric | rust | zig-fast | zig-safe |
|---|---:|---:|---:|
| Startup, cold: first frame (ms) | 1129 (1069–1733) | 432 (386–575) | 437 (419–529) |
| Startup, cold: interactive shell (ms) | 1358 (1297–2213) | 696 (642–939) | 709 (653–806) |
| Startup, warm: first frame (ms) | 247 (246–248) | 99 (99–100) | 101 (100–102) |
| Startup, warm: interactive shell (ms) | 422 (377–423) | 301 (265–326) | 347 (309–349) |
| Open long transcript (ms) | 152 (119–209) | 54 (53–54) | 79 (77–81) |
| RSS idle (MB) | 232 (226–242) | 159 (156–169) | 160 (158–171) |
| RSS after opening long transcript (MB) | 240 (233–249) | 172 (170–182) | 180 (176–188) |
| RSS after scrolling (MB) | 244 (237–273) | 176 (174–196) | 185 (178–209) |
| Footprint idle (MB) | 210 (203–219) | 135 (132–144) | 136 (134–146) |
| Footprint after opening long transcript (MB) | 218 (211–226) | 148 (145–158) | 156 (152–164) |
| Footprint after scrolling (MB) | 222 (215–251) | 152 (150–172) | 161 (154–185) |
| Peak RSS (MB) | 272 (266–310) | 177 (174–205) | 192 (182–212) |
| CPU idle, short chat (%) | 15.6 (14.3–17.9) | 0.0 (0.0–0.0) | 0.0 (0.0–0.0) |
| CPU idle, long transcript (%) | 16.4 (16.4–19.6) | 0.0 (0.0–0.0) | 0.0 (0.0–2.5) |
| CPU while scrolling (%) | 169.6 (169.1–170.3) | 272.8 (252.4–273.8) | 257.1 (243.0–258.1) |
| CPU while streaming (%) | 151.9 (149.7–155.0) | 265.2 (263.9–266.0) | 250.4 (245.4–251.2) |
| Scroll: frame interval p50 (ms) | 48.0 (48.0–48.0) | 30.3 (30.1–31.1) | 33.5 (33.2–34.1) |
| Scroll: frame interval p95 (ms) | 64.0 (64.0–64.0) | 31.6 (31.4–39.2) | 34.9 (34.6–42.1) |
| Scroll: frame interval p99 (ms) | 64.0 (64.0–64.0) | 32.8 (32.0–41.5) | 36.5 (35.4–44.4) |
| Scroll: dropped frames | 700 (698–703) | 300 (300–300) | 300 (300–318) |
| Scroll: draw p50 (ms) | 38.10 (37.94–38.20) | 29.62 (29.46–30.44) | 33.47 (33.14–34.00) |
| Scroll: draw p95 (ms) | 51.09 (50.75–52.39) | 30.97 (30.82–38.39) | 34.85 (34.56–41.28) |
| Scroll: draw p99 (ms) | 52.71 (51.67–53.33) | 32.15 (31.29–40.37) | 36.39 (35.30–44.31) |
| Stream: frame interval p50 (ms) | 64.0 (64.0–64.0) | 27.9 (27.7–28.0) | 31.1 (30.8–31.4) |
| Stream: frame interval p95 (ms) | 64.0 (64.0–64.2) | 29.4 (28.8–30.0) | 33.1 (32.8–34.0) |
| Stream: frame interval p99 (ms) | 81.6 (78.1–138.2) | 30.4 (29.8–31.7) | 34.5 (33.4–36.2) |
| Stream: dropped frames | 170 (167–171) | 132 (131–133) | 118 (116–120) |
| Stream: draw p50 (ms) | 48.93 (48.67–50.46) | 27.33 (27.10–27.45) | 31.00 (30.79–31.35) |
| Stream: draw p95 (ms) | 51.49 (50.96–53.45) | 28.71 (28.16–29.32) | 33.10 (32.73–33.92) |
| Stream: draw p99 (ms) | 71.22 (66.44–125.43) | 29.69 (29.05–30.75) | 34.25 (33.36–35.56) |
| Engine RSS at end (MB) | 46 (44–46) | 45 (43–46) | 45 (43–46) |
| Window (logical px, scale) | 1320x880@1 | 1320x880@1 | 1320x880@1 |
| Completed runs | 10/10 | 10/10 | 10/10 |

Draws per streamed reply: Rust 55–57. Zig 118–119. Both are bound by the software
rasterizer, not by vsync.

## macos-15-intel

The first attempt could not build the Rust client: `ort-sys` (ONNX Runtime, used for voice)
ships no `x86_64-apple-darwin` binaries. Upstream only ships Apple Silicon macOS builds.
The workflow now links Homebrew's `onnxruntime` dynamically on Intel Macs. That makes the
Rust bundle depend on `/usr/local/opt/onnxruntime` there, so treat its size numbers with
care. The retry is job 113573248913 in run 37853859030 and was still running when this
report was written. Its `bench-macos-15-intel` artifact holds the same tables.

## Static metrics

**Binaries and bundles.** Rust's single binary links the engine in. `engine` is the
UI-free engine host on its own, so Rust minus engine roughly approximates the Rust UI's
share; dependencies are shared, so it is only an approximation.

| | macOS arm64 | Linux x86_64 |
|---|---:|---:|
| Rust `zeron` (release, already stripped) | 127.2 MB | 163.7 MB |
| Zig `zeron` ReleaseSafe (stripped) | 49.7 MB (47.5) | 129.6 MB (50.0) |
| Zig `zeron` ReleaseFast (stripped) | 50.5 MB (48.6) | 143.9 MB (51.7) |
| `zeron-engine` (engine host) | 38.9 MB | 43.0 MB |
| Rust bundle (Zeron.app / tarball stage) | 129.0 MB | 165.5 MB |
| Zig bundle without its bundled engine | 51.9 MB | 128.8 MB (unstripped, plus `zeron-webkit`) |

**Direct dynamic dependencies.**

- macOS: Rust links 32 (AppKit, Metal, MPS, WebKit, JavaScriptCore, AVFoundation, CoreML,
  CloudKit, CoreLocation, UserNotifications and others). Zig links 13 (AppKit, Carbon,
  CoreFoundation, CoreGraphics, CoreText, CoreVideo, Foundation, Metal,
  MetalPerformanceShaders, QuartzCore, CoreServices, libSystem, libobjc). Zig loads WebKit
  and the rest at runtime.
- Linux: Rust has 9 (it dlopens Vulkan, Wayland and fontconfig). Zig has 18 (Vulkan,
  Wayland, X11, xkbcommon, freetype, harfbuzz and fontconfig, all linked).
- Engine: 8 on macOS, 4 on Linux.

**Build times** (seconds; GitHub-hosted runners, so single samples):

| | macOS arm64 | Linux x86_64 |
|---|---:|---:|
| Rust client, clean release | 1092 | 601 |
| Rust client, incremental (one `crates/ui` file) | 350 | 308 |
| Zig client, clean ReleaseFast | 714 | 601 |
| Zig client, incremental ReleaseFast (one app file) | 381 | 434 |
| Zig client, clean ReleaseSafe | 563 | 480 |
| Zig client, incremental ReleaseSafe | 355 | 317 |
| Engine host, release (warm cargo cache) | 305 | 251 |

The Zig "incremental" build is close to a full compile of the app module, because release
modes are whole-program builds. Rust's incremental figure is dominated by the thin-LTO link.

**Lines of code** (non-blank lines) **and tests** (source-counted `#[test]`-style
attributes and Zig `test` blocks):

| | lines | tests |
|---|---:|---:|
| zeron UI-side crates (ui, markdown, syntax, text, theme, update, voice, preview) | 210,625 | 1,901 |
| zeron engine and shared crates (not ported; used by both) | 187,351 | 1,742 |
| zui (gpui fork) crates | 136,581 | 530 |
| Zig app, `apps/zeron/src` | 143,673 | 892 |
| zpui, `src/` | 89,339 | 418 |

## Caveats

- **Hosted VMs, not desks.**
  - macOS: a 1024×768 virtual display, paravirtual Metal and Reduce Transparency on, so
    Liquid Glass draws solid.
  - Linux: Xvfb and lavapipe, so the "GPU" is the CPU. Linux frame and CPU numbers rank
    the renderers but say nothing about real hardware.
  - The runs are single-runner samples. Spread is shown in brackets, and on macOS the p99
    figures and dropped-frame counts vary a lot from run to run.
- **Different allocators.** Upstream links mimalloc on macOS and glibc malloc with a
  malloc_trim thread on Linux. Zig uses its own allocator. RSS comparisons therefore
  include allocator policy.
- **Rust's binary carries the engine.** Rust's binary and bundle cannot be split into
  client and engine. "Rust minus engine host" is an estimate only.
- **The Rust build is patched.** It includes the 300-line benchmark hook module, which is
  inert unless `ZERON_BENCH=1`. Its size effect is negligible but non-zero.
- **The fixture is mock-harness markdown.** It is not a real agent session: no images,
  diffs, subagents or terminals. Neither client opened the browser, terminal or files
  panes.
- **Timeline differences.**
  - Rust's own `boot_select_chat` lands on the short chat. In the runs above, the Zig
    client had no boot landing yet (a parity gap), so its driver selected the short chat
    once chats synced. Both drivers do the same thing when nothing is selected. The Zig
    client now has the landing too (`d405d65`), so its driver's selection is only a
    fallback, as in Rust.
  - Both drivers request a frame every vsync during scroll and stream, so the frame
    interval is a ceiling on smoothness. Draws only happen when a window is dirty.
- **The Linux runs use openbox** (see the X11 finding below). The Zig client renders
  without a window manager either way.
- **Intel macOS:** Rust there links Homebrew ONNX Runtime dynamically, which upstream does
  not ship (see above).

## What the numbers say

1. **Size and dependencies: Zig is smaller, Rust ships one file.** On macOS the Zig client
   is 50 MB against 127 MB for Rust. Even after subtracting the 39 MB engine that Rust
   links in, the Zig client is about 40 % smaller. It also links 13 frameworks against 32.
   But Rust ships one self-contained binary, while the Zig bundle still needs the Rust
   engine binary next to it (91 MB in total).

2. **Startup to first frame: Zig is faster everywhere.** Warm launches reach the first
   frame in 533 ms against 925 ms on macOS, and 101 ms against 247 ms on Linux. Cold
   launches are dominated by page-in, roughly 3–9 s on the macOS VM for both.

3. **Interactive shell on macOS: Zig was about 5 s late. This was a Zig bug, not a speed
   result.**
   - Every macOS Zig launch reaches `shell_loaded` almost exactly 5.0 s after its first
     frame. The chat list arrives 5 s late. Linux takes 0.25 s for the same step.
   - **Root cause (fixed in `fd8dd41`):** the `ws.zig` handshake watchdog. It slept for
     the 5 s `handshake_timeout` on its own thread and was stopped with
     `Future.cancel`. `std.Io.Threaded` interrupts a sleeping thread by sending it
     `SIGIO`. Worker threads inherit their creator's signal mask, and zpui's macOS
     background executor runs on libdispatch workers, which block `SIGIO`. So the
     cancel never reached the sleep and waited out all 5 s, after the handshake had
     already succeeded. Linux's executor threads don't block `SIGIO`. The watchdog
     (and the engine reap watchdogs) now stop through a futex (`StopTimer`), which needs
     no signal.
   - Re-measured after the fix on macos-26, with 3 rounds
     ([37865225918](https://github.com/plyght/zpui/actions/runs/37865225918), zeron
     037f4c1):
     - Warm interactive shell: Rust 1068 ms; Zig 574 ms (fast), 907 ms (safe),
       702 ms (safe-plain). The runs above measured 5.6–5.8 s for Zig.
     - Cold: Rust 5246 ms; Zig 3781 / 4099 / 5395 ms.
     - First frame to `shell_loaded` is about 160–190 ms. The Zig driver no longer
       selects the chat itself: no `boot_select` marker appears, because the client's own
       boot landing picks the short chat.

4. **Memory: Zig uses less resident memory, with equal footprint on macOS.**
   - macOS: RSS 137 MB against 157 MB, and physical footprint about 82 MB for both.
     Rust's extra RSS is likely clean, shared and file-backed pages.
   - Linux: Zig's PSS is about 70 MB lower (136 MB against 210 MB).
   - Opening the 80-message transcript and scrolling it adds only a few MB in either
     client.

5. **Idle CPU: Zig is quieter.** On macOS Zig idles at 1–2 % against 3–5 % for Rust,
   measured by either `ps` or powermetrics. On Linux Rust idles at about 16 %: gpui's X11
   backend drives a 60 Hz refresh timer while the window is visible even when nothing
   changes. zpui only wakes on demand and idles at 0 %.

6. **Streaming: fixed, Zig now at or below Rust.**
   - Originally, while a reply streamed, Rust drew about 50 frames per reply and the Zig
     port redrew on every vsync (about 250), using 4–5 times the CPU (60 % against 12 %)
     and energy impact (36 against 8).
   - Cause: the Working spinner, the streaming veil fade and the sidebar Working glyphs each
     requested a frame on every render. Rust drives these from `motion.rs`'s `PulseClock`
     (a shared 33 ms timer leased while a loader paints). `2993f91` ports that clock and
     `bdfe093` its reduced-motion behaviour.
   - After the fix (runs 37865225918 and 38007438600): Zig 6.5–10 % CPU while streaming
     against Rust's 10.6–12.5 %. A port gap only; nothing to propose upstream.

7. **Scrolling: Zig now uses about half Rust's CPU, with an equal or better tail.**
   The runs above had Zig at 63 % CPU against Rust's 53 % while scrolling. Frame pacing
   was similar or better. The re-measurement and fixes are in "Scrolling CPU" below.
   After `9229e41`, Zig scrolls at 24–26 % against 50 % for Rust on macos-26, with
   p95/p99 frame intervals of 19.5/20.5–22.1 ms against 19.8/27.0 ms. On lavapipe
   (not re-measured), Zig draws a frame in 33 ms against 38 ms for Rust.

8. **Liquid Glass and native controls cost little here.** With Reduce Transparency on,
   the effect of turning glass and AppKit controls off is within noise: slightly fewer
   dropped frames, and the same CPU and memory. A rerun on a display with transparency
   would be needed before claiming more.

9. **Build times are close.** A clean build takes 8–12 min for Zig and 10–18 min for Rust.
   Neither has a fast incremental release build: about 5–7 min for both.

## Scrolling CPU (macos-26, before and after the fixes)

Three macos-26 runs with 3 rounds each (6 launches per configuration), all at zeron
037f4c1. Same harness and timeline as above; scroll = 300 frames with one 40 px wheel
event each over the 80-message transcript.

- **Before**: [37865225918](https://github.com/plyght/zpui/actions/runs/37865225918) at
  `d405d65`.
- **Sidebar cached**: [38002834235](https://github.com/plyght/zpui/actions/runs/38002834235)
  at `56c8fa8`.
- **Scene building**: [38007438600](https://github.com/plyght/zpui/actions/runs/38007438600)
  at `9229e41`.

| Metric | Run | rust | zig-fast | zig-safe | zig-safe-plain |
|---|---|---:|---:|---:|---:|
| CPU while scrolling (%) | before | 54.1 (48.5–62.6) | 68.6 (57.0–75.6) | 74.9 (72.6–79.1) | 68.6 (63.3–71.7) |
| | sidebar cached | 48.7 (38.9–56.6) | 41.4 (32.4–44.1) | 36.9 (29.2–50.6) | 37.1 (34.4–39.9) |
| | scene building | 50.0 (48.1–54.9) | 23.9 (19.6–30.3) | 26.1 (22.7–33.5) | 26.3 (21.4–32.1) |
| Scroll: frame interval p50 / p95 / p99 (ms) | before | 16.9 / 26.5 / 31.6 | 16.7 / 20.6 / 37.4 | 17.8 / 32.6 / 53.0 | 16.7 / 20.5 / 35.2 |
| | sidebar cached | 25.2 / 49.3 / 65.8 | 16.6 / 22.0 / 38.4 | 16.7 / 19.6 / 30.3 | 16.8 / 24.7 / 37.2 |
| | scene building | 16.7 / 19.8 / 27.0 | 16.7 / 19.5 / 20.5 | 16.6 / 19.5 / 22.1 | 16.7 / 19.7 / 20.9 |
| Scroll: draw p50 / p95 / p99 (ms) | before | 16.50 / 26.34 / 31.08 | 14.68 / 20.29 / 37.04 | 17.06 / 32.22 / 52.84 | 15.95 / 20.30 / 35.05 |
| | sidebar cached | 24.53 / 48.03 / 62.79 | 16.10 / 21.89 / 38.28 | 13.02 / 18.98 / 29.86 | 16.59 / 24.17 / 37.17 |
| | scene building | 16.39 / 19.55 / 26.83 | 10.58 / 18.44 / 20.15 | 10.75 / 18.27 / 21.07 | 16.59 / 19.57 / 20.26 |
| Scroll: dropped frames | before | 22 (6–138) | 18 (4–33) | 50 (4–86) | 9 (5–22) |
| | sidebar cached | 192 (6–364) | 16 (7–38) | 8 (4–272) | 18 (1–45) |
| | scene building | 7 (2–30) | 3 (3–5) | 4 (3–7) | 3 (0–6) |
| CPU while streaming (%) | before | 10.6 (9.5–13.8) | 10.6 (6.7–12.8) | 12.8 (10.3–16.5) | 10.1 (9.6–13.7) |
| | sidebar cached | 12.8 (9.7–17.4) | 9.8 (8.4–11.2) | 10.4 (9.2–11.8) | 8.7 (6.5–9.6) |
| | scene building | 12.5 (9.7–14.3) | 9.1 (8.0–10.6) | 10.1 (6.0–12.9) | 6.5 (5.7–10.0) |

Rust's numbers move between runs only with runner noise. In the middle run the Rust
client's scroll tail was unusually poor, so its median frame interval is not
representative.

**Root causes.** They were found with a headless scroll test of the full shell on the
bench fixture (`apps/zeron/src/ui/shell/scroll_test.zig`: 150 chats, the 40-turn mock
transcript, a 1024×674 window), profiled with callgrind:

1. **The sidebar was rebuilt every scroll frame (`56c8fa8`).** A scroll notifies the
   transcript view, which re-renders its ancestors, including the whole shell. The
   sidebar was an uncached child, so every frame re-sorted, rebuilt and laid out all 150
   chat rows. Rust wraps the sidebar in a cached view (`sidebar_pane.cached(..)`) that
   follows only the shell's own notifications. The Zig sidebar is now a cached view too,
   notified whenever the shell is, as Rust's `SidebarPane` observes the shell. In Debug
   this took a headless scroll frame from 138 ms to 31 ms.
2. **Scene building was about half of what remained (`9229e41`).**
   - `Scene.finish` sorted the primitive lists with `std.mem.sort`, a block sort that
     moves the large primitive structs O(n log n) times. Rust's adaptive `sort_by_key` is
     near-linear on this mostly ordered data. The lists are now checked for order first,
     else sorted as (key, index) words with each primitive moved once. The result is the
     same stable order.
   - The bounds tree's search pushed every visited node through a non-inlined
     `ArrayList.append`. Its stack is now reserved once per search.
   - On macOS, `drawLayered` replayed the whole scene into the base plane, a second
     bounds-tree build and sort, every frame once any native view existed, even with
     nothing on the upper planes. It now draws the scene as is in that case.

   ReleaseFast headless scroll frame: 3.27 ms → 2.1 ms.

What was ruled out:

- The transcript list virtualizes, laying out only the visible rows plus overdraw, as
  Rust does.
- Line layouts hit the cache; only rows scrolling in are shaped.
- Markdown is parsed once per message, and highlights are cached by content.

The streaming numbers above also include the earlier pulse-clock fixes (`2993f91`,
`bdfe093`). They already put Zig's streaming CPU at Rust's level before these changes.

## Fixes found during the port: do any also exist in Rust?

| Port fix | Exists in Rust zeron/zui? | Verdict |
|---|---|---|
| Frame-arena strings built in hover handlers outside a draw (`1875716`: Settings crash) | No. gpui hover handlers own `SharedString`s, and lifetimes prevent arena-borrowed data from escaping a frame. The element arena is only reachable while drawing. | Port-only |
| Nested frame requests during a CA flush (`28537d3`) | No. `gpui_macos` takes `request_frame_callback` out of the window state while it runs, so a re-entrant `display_layer` or `step` finds `None`. | Port-only |
| Focus restore after blur or unmount (`8fc1502`) | No. Rust has `shell::restore_mounted_focus`; the Zig shell had not ported it. | Port-only |
| Files explorer focus target while the workspace can't load (`8099771`) | No. `restore_mounted_focus` covers the stale handle generically. | Port-only |
| PTY teardown hang on ⌘Q (`1665c57`: SIGTERM then a blocking `waitpid` that interactive shells ignore) | No. Rust PTYs live in the engine (`crates/engine/src/terminals.rs`, `portable_pty` `ChildKiller`), and quitting the UI never blocks on a shell. | Port-only |
| Malformed RFC 3339 reset dates panicking (`28537d3`) | No. Rust parses them with chrono and gets `Result`s. | Port-only |
| **New:** gpui X11 never starts its refresh loop without a window manager | **Yes, in zui.** Under a bare Xvfb the Rust window is mapped and viewable but stays black, and the calloop main loop sits in `epoll_wait`. One synthetic unmap/map (`xdotool windowunmap windowmap`) makes it draw. That fits a `MapNotify` that `update_refresh_loop` never sees: it is probably buffered by xcb during a reply, so the fd never becomes readable. With openbox it works. Reproduced on zui `667d0aa` and `dce5c1f`. | **Upstream candidate (zui)** |

Also noted, but not upstream bugs:

- Rust zeron does not build for `x86_64-apple-darwin` at this pin, because `ort-sys` has no
  prebuilt binaries for it. That is consistent with upstream shipping Apple Silicon only.
- gpui's 60 Hz X11 refresh timer while idle is a design choice. A 16 % idle CPU on lavapipe
  is mostly a CI artifact; on real Linux hardware it would be small.

## Recommendation

Of the four options, **share the results, plus one narrow zui fix.** In order of value
against maintainer cost:

1. **Nothing**, the default: always acceptable. The port is a private parity exercise, and
   the maintainers owe it no attention.

2. **Share the results.** Recommended, framed as a data point rather than a pitch. The
   parts maintainers can use without adopting anything:
   - Rust's streaming path is about 5× cheaper than a straightforward port. The doc-cadence
     coalescing and cached transcript views are worth keeping as they are.
   - The macOS bundle drags in 32 frameworks, including CoreML, CloudKit, CoreLocation and
     WebKit, and Rust idles at 3–5 % CPU.
   - On Linux X11 the refresh timer keeps running while idle.
   - The Intel macOS build fails at `ort-sys`.

   Cost to them: reading a page.

3. **Upstream specific fixes.**
   - None of the named port fixes apply. The arena crash, focus restore and PTY hang are
     all classes Rust's design already prevents.
   - The one real cross-cutting finding is the zui X11 "black window without a WM" refresh
     loop. It is small, self-contained and testable in CI with Xvfb, but it matters only
     for X11 sessions without a WM (CI, kiosks, some remote setups).
   - Worth offering as an issue with the reproduction above, or as a minimal patch:
     process pending xcb events after `map_window`, or seed `is_mapped` from
     `get_window_attributes`. Only after confirming the root cause in a debug build. Per
     instructions, nothing has been opened on zeronsh repos.

4. **Offer the Zig client as an alternative.** Not recommended now.
   - It was not at parity in these runs: no boot landing, the 5 s macOS shell delay
     (both fixed since), and streaming that redraws every vsync. Behaviour-for-behaviour parity is still being chased in
     `docs/PARITY.md`.
   - It still depends on the Rust engine.
   - It would ask the maintainers to review and own about 233 k lines in a second language
     and toolchain (Zig 0.17, pre-1.0), plus a second UI framework, for wins that are
     modest where they exist: about 40 % smaller binary, faster first frame, lower idle
     CPU, better scroll tail. Meanwhile it loses clearly on streaming efficiency.
   - The maintenance cost and the parity risk outweigh the speed.

Revisit option 4 only after the Zig client is at parity, beats Rust on streaming, and the
gap is measured on real hardware rather than hosted VMs.

## Reproducing

    gh workflow run benchmark.yml -f runs=5 -f platforms=macos-26,ubuntu-24.04
    # optional: -f zeron_ref=<full sha> (default: the map.json pin); macos-15-intel / macos-26-intel also accepted

Jobs run one at a time (`max-parallel: 1`). macOS runners are shared.

To run locally (Linux, Xvfb with a window manager):

    ENGINE=zig-out/zeron-engine ZIG_SAFE=zig-out/bin/zeron RUST_APP=<patched zeron> RUNS=1 OUT=/tmp/b bench/run_all.sh
