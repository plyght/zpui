//! zpui benchmark timeline driver — NOT part of upstream zeron. Copied into
//! crates/ui/src/ by zpui's bench/patch_rust_client.py for the benchmark build only,
//! and inert unless `ZERON_BENCH=1`. The Zig client runs the identical timeline
//! (zpui apps/zeron/src/bench.zig); bench/run_bench.py reads the markers.
//!
//! Every marker is one stderr line: `zeron-bench {"ev":"…","t":<epoch µs>,…}`.
//! Draw cost per frame comes from gpui's own `ZED_MEASUREMENTS=1` lines
//! (`frame duration: …`, window.rs `measure`), which the harness sets.
//!
//! Timeline (the harness samples RSS/CPU from outside and slices by marker):
//!  1. boot: `window_open`; frames forced until the boot-selected short chat's
//!     transcript is on screen → `first_frame` (2nd frame callback = 1st present),
//!     `shell_loaded` (the frame after the transcript landed);
//!  2. `idle_start` … `idle_end`: no frames requested for BENCH_IDLE_S;
//!  3. `open_long`: select the long chat → `long_loaded` once ≥ BENCH_LONG_MIN rows;
//!  4. settle (no frames) → `settle1_end`;
//!  5. `scroll_start`: BENCH_SCROLL_FRAMES frames, one wheel event each (half up,
//!     half down), frame intervals in `scroll_end`;
//!  6. settle → `settle2_end`, then `stream_ready` (the harness queues a mock run);
//!     frames forced until a streaming row appears (`stream_start`) and is done
//!     (`stream_end`, intervals);
//!  7. settle → `done`, quit.
use std::{
    cell::RefCell,
    rc::Rc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use gpui::{App, AppContext as _, Entity, Window, WindowHandle, point, px};

use crate::{shell::Shell, state::AppState};

fn env_num(name: &str, default: f64) -> f64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn now_us() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_micros()).unwrap_or(0)
}

fn emit(ev: &str, extra: &str) {
    if extra.is_empty() {
        eprintln!("zeron-bench {{\"ev\":\"{ev}\",\"t\":{}}}", now_us());
    } else {
        eprintln!("zeron-bench {{\"ev\":\"{ev}\",\"t\":{},{extra}}}", now_us());
    }
}

fn ms_list(v: &[f64]) -> String {
    let items: Vec<String> = v.iter().map(|x| format!("{x:.3}")).collect();
    format!("[{}]", items.join(","))
}

#[derive(Clone, Copy)]
enum Phase {
    Boot,
    OpenLong,
    Scroll,
    Stream,
    Idle,
}

struct Bench {
    state: Entity<AppState>,
    long_chat: String,
    short_chat: String,
    long_min: usize,
    idle: Duration,
    settle: Duration,
    scroll_frames: usize,
    scroll_px: f32,
    scroll_x: f32,
    scroll_y: f32,
    phase: Phase,
    frames: u64,
    ready_seen: bool,
    phase_started: Instant,
    last_frame: Option<Instant>,
    intervals: Vec<f64>,
    scroll_i: usize,
    stream_seen: bool,
}

type Shared = Rc<RefCell<Bench>>;

pub fn start(window: WindowHandle<Shell>, state: Entity<AppState>, cx: &mut App) {
    if std::env::var("ZERON_BENCH").ok().as_deref() != Some("1") {
        return;
    }
    emit("window_open", "");
    let b = Rc::new(RefCell::new(Bench {
        state,
        long_chat: std::env::var("ZERON_BENCH_LONG_CHAT").unwrap_or_default(),
        short_chat: std::env::var("ZERON_BENCH_SHORT_CHAT").unwrap_or_default(),
        long_min: env_num("ZERON_BENCH_LONG_MIN", 2.0) as usize,
        idle: Duration::from_secs_f64(env_num("ZERON_BENCH_IDLE_S", 6.0)),
        settle: Duration::from_secs_f64(env_num("ZERON_BENCH_SETTLE_S", 4.0)),
        scroll_frames: env_num("ZERON_BENCH_SCROLL_FRAMES", 300.0) as usize,
        scroll_px: env_num("ZERON_BENCH_SCROLL_PX", 40.0) as f32,
        scroll_x: env_num("ZERON_BENCH_SCROLL_X", 800.0) as f32,
        scroll_y: env_num("ZERON_BENCH_SCROLL_Y", 420.0) as f32,
        phase: Phase::Boot,
        frames: 0,
        ready_seen: false,
        phase_started: Instant::now(),
        last_frame: None,
        intervals: Vec::new(),
        scroll_i: 0,
        stream_seen: false,
    }));
    let _ = window.update(cx, |_, window, _| schedule(b, window));
}

fn schedule(b: Shared, window: &mut Window) {
    window.on_next_frame(move |window, cx| frame(b, window, cx));
}

fn begin_frames(b: &Shared, phase: Phase, window: &mut Window) {
    {
        let mut s = b.borrow_mut();
        s.phase = phase;
        s.phase_started = Instant::now();
        s.last_frame = None;
        s.intervals.clear();
        s.ready_seen = false;
    }
    window.refresh();
    schedule(b.clone(), window);
}

/// Run `then` on the main window after `delay` with no frames requested meanwhile.
fn after(b: Shared, delay: Duration, cx: &mut App, then: fn(Shared, &mut Window, &mut App)) {
    b.borrow_mut().phase = Phase::Idle;
    cx.spawn(async move |cx| {
        cx.background_executor().timer(delay).await;
        cx.update(|cx| {
            let window = cx.windows().into_iter().find_map(|w| w.downcast::<Shell>());
            if let Some(window) = window {
                let _ = window.update(cx, |_, window, cx| then(b, window, cx));
            }
        });
    })
    .detach();
}

fn transcript_info(b: &Bench, cx: &App) -> (Option<String>, usize, bool, bool) {
    let st = b.state.read(cx);
    let streaming = st
        .transcript
        .iter()
        .any(|e| e.status == Some(zeron_doc::MessageStatus::Streaming));
    (st.selected_chat.clone(), st.transcript.len(), st.transcript_replayed, streaming)
}

fn frame(b: Shared, window: &mut Window, cx: &mut App) {
    let now = Instant::now();
    let phase = {
        let mut s = b.borrow_mut();
        s.frames += 1;
        if let Some(last) = s.last_frame {
            let dt = now.duration_since(last).as_secs_f64() * 1000.0;
            s.intervals.push(dt);
        }
        s.last_frame = Some(now);
        s.phase
    };
    let timeout = b.borrow().phase_started.elapsed() > Duration::from_secs(90);
    match phase {
        Phase::Idle => {}
        Phase::Boot => {
            if b.borrow().frames == 2 {
                let vp = window.viewport_size();
                emit(
                    "first_frame",
                    &format!(
                        "\"w\":{},\"h\":{},\"scale\":{}",
                        f32::from(vp.width),
                        f32::from(vp.height),
                        window.scale_factor()
                    ),
                );
            }
            // `Shell::boot_select_chat` lands on the most recent chat (the short one)
            // by itself; select it only if nothing is selected once chats synced, as
            // the Zig driver does (its boot landing is not ported yet).
            let (synced, none_selected, short) = {
                let s = b.borrow();
                let st = s.state.read(cx);
                (st.chats_synced, st.selected_chat.is_none(), s.short_chat.clone())
            };
            if synced && none_selected && !short.is_empty() {
                emit("boot_select", "");
                let state = b.borrow().state.clone();
                state.update(cx, |s, cx| s.select_chat(Some(short), cx));
            }
            let (selected, rows, replayed, _) = transcript_info(&b.borrow(), cx);
            let want = b.borrow().short_chat.clone();
            let ok = replayed && rows > 0 && (want.is_empty() || selected.as_deref() == Some(want.as_str()));
            if b.borrow().ready_seen {
                emit("shell_loaded", &format!("\"selected\":\"{}\",\"rows\":{rows}", selected.unwrap_or_default()));
                emit("idle_start", "");
                let idle = b.borrow().idle;
                return after(b, idle, cx, open_long);
            }
            if ok {
                b.borrow_mut().ready_seen = true;
            }
            if timeout {
                emit("error", &format!("\"phase\":\"boot\",\"selected\":\"{}\",\"rows\":{rows}", selected.unwrap_or_default()));
                return cx.quit();
            }
            schedule(b, window);
        }
        Phase::OpenLong => {
            let (selected, rows, replayed, _) = transcript_info(&b.borrow(), cx);
            let (want, min) = (b.borrow().long_chat.clone(), b.borrow().long_min);
            if b.borrow().ready_seen {
                emit("long_loaded", &format!("\"rows\":{rows}"));
                let settle = b.borrow().settle;
                return after(b, settle, cx, start_scroll);
            }
            if replayed && rows >= min && selected.as_deref() == Some(want.as_str()) {
                b.borrow_mut().ready_seen = true;
            }
            if timeout {
                emit("error", &format!("\"phase\":\"open_long\",\"rows\":{rows}"));
                return cx.quit();
            }
            schedule(b, window);
        }
        Phase::Scroll => {
            let (i, n, step, x, y) = {
                let s = b.borrow();
                (s.scroll_i, s.scroll_frames, s.scroll_px, s.scroll_x, s.scroll_y)
            };
            if i >= n {
                let intervals = ms_list(&b.borrow().intervals);
                emit("scroll_end", &format!("\"intervals_ms\":{intervals}"));
                let settle = b.borrow().settle;
                return after(b, settle, cx, settle2_done);
            }
            // Positive y scrolls toward older content (up), as a trackpad does.
            let dy = if i < n / 2 { step } else { -step };
            let _ = window.dispatch_event(
                gpui::PlatformInput::ScrollWheel(gpui::ScrollWheelEvent {
                    position: point(px(x), px(y)),
                    delta: gpui::ScrollDelta::Pixels(point(px(0.), px(dy))),
                    modifiers: gpui::Modifiers::default(),
                    touch_phase: gpui::TouchPhase::Moved,
                }),
                cx,
            );
            b.borrow_mut().scroll_i += 1;
            schedule(b, window);
        }
        Phase::Stream => {
            let (_, rows, _, streaming) = transcript_info(&b.borrow(), cx);
            let seen = b.borrow().stream_seen;
            if streaming && !seen {
                {
                    let mut s = b.borrow_mut();
                    s.stream_seen = true;
                    s.intervals.clear();
                }
                emit("stream_start", &format!("\"rows\":{rows}"));
            } else if seen && !streaming {
                let intervals = ms_list(&b.borrow().intervals);
                emit("stream_end", &format!("\"rows\":{rows},\"intervals_ms\":{intervals}"));
                let settle = b.borrow().settle;
                return after(b, settle, cx, finish);
            }
            if timeout {
                emit("error", &format!("\"phase\":\"stream\",\"seen\":{seen}"));
                return cx.quit();
            }
            schedule(b, window);
        }
    }
}

fn open_long(b: Shared, window: &mut Window, cx: &mut App) {
    emit("idle_end", "");
    emit("open_long", "");
    let (state, id) = {
        let s = b.borrow();
        (s.state.clone(), s.long_chat.clone())
    };
    state.update(cx, |s, cx| s.select_chat(Some(id), cx));
    begin_frames(&b, Phase::OpenLong, window);
}

fn start_scroll(b: Shared, window: &mut Window, _cx: &mut App) {
    emit("settle1_end", "");
    emit("scroll_start", "");
    b.borrow_mut().scroll_i = 0;
    begin_frames(&b, Phase::Scroll, window);
}

fn settle2_done(b: Shared, window: &mut Window, cx: &mut App) {
    emit("settle2_end", "");
    // Back to the tail (follow mode) so the streamed reply is on screen.
    let (x, y) = {
        let s = b.borrow();
        (s.scroll_x, s.scroll_y)
    };
    let _ = window.dispatch_event(
        gpui::PlatformInput::ScrollWheel(gpui::ScrollWheelEvent {
            position: point(px(x), px(y)),
            delta: gpui::ScrollDelta::Pixels(point(px(0.), px(-1_000_000.))),
            modifiers: gpui::Modifiers::default(),
            touch_phase: gpui::TouchPhase::Moved,
        }),
        cx,
    );
    emit("stream_ready", "");
    b.borrow_mut().stream_seen = false;
    begin_frames(&b, Phase::Stream, window);
}

fn finish(_b: Shared, _window: &mut Window, cx: &mut App) {
    emit("done", "");
    cx.quit();
}
