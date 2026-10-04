//! Composer dictation — zeron `composer.rs` hold-to-talk (`toggle_dictation`,
//! `press_dictation`, `release_dictation`, `render_dictation_button`,
//! `render_voice_track`, `render_dictation_status`, `update_voice`,
//! `VoiceTween`) with `dictation/glass.rs` and `dictation/waveform.rs`.
//!
//! The editor (`zeron_input` `TextInput`) owns the session (`Dictation`, the
//! `Transcriber`, insertion); this file owns the composer's half: the
//! microphone that morphs into Stop, the waveform track that unrolls from it
//! over the action row (the paperclip becomes Cancel), the outcome strip
//! under the pill, and the hold bookkeeping. The native engine is reached
//! only through the app-installed `dictation.Service` global.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const input_mod = @import("zeron_input");
const composer_mod = @import("composer.zig");
const chrome = @import("chrome.zig");
const extras = @import("extras.zig");

const dict = input_mod.dictation;
const ComposerView = composer_mod.ComposerView;
const TextInput = input_mod.TextInput;
const Ctx = zpui.Context(ComposerView);
const InputCtx = zpui.Context(TextInput);
const Window = zpui.Window;
const App = zpui.App;
const Hsla = zpui.Hsla;
const Theme = zt.Theme;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;

/// Dictation is hold to talk, from the microphone (pointer or Enter/Space
/// while it is focused) and from the shortcut. Each releases only its own hold.
pub const HoldSource = enum { pointer, button, key };

pub const Hold = struct {
    source: HoldSource,
    /// When this hold started dictation; null when it took over a session
    /// started another way (assistive Click), which it then only finishes.
    started: ?u64,
};

/// `DICTATION_TAP`: a release sooner than this is a click, not speech.
pub const tap_ns: u64 = 300 * std.time.ns_per_ms;
/// `VOICE_MORPH` / `VOICE_CURVE`.
pub const morph_ns: u64 = 420 * std.time.ns_per_ms;
const morph_curve: zt.motion.CubicBezier = .init(0.2, 0.0, 0.0, 1.0);
/// `VOICE_LIMIT_WARNING`: the clock turns amber 10 s before the limit.
pub const limit_warning_ns: u64 = 10 * std.time.ns_per_s;
/// `zeron_voice::MAX_SECONDS`.
pub const max_seconds: u64 = 60;
/// `VOICE_TRACK_HEIGHT` / `VOICE_TRACK_GAP`.
pub const track_height: f32 = 32;
pub const track_gap: f32 = 8;

/// `waveform::Mode`.
pub const Mode = enum {
    /// Microphone is opening: a quiet baseline breathes.
    waiting,
    /// Live input: bars follow the voice.
    live,
    /// Capture ended: bars hold still while a highlight sweeps across them.
    processing,
};

/// `VoiceFrame`: everything the voice track draws, captured from the meter.
pub const Frame = struct {
    label_buf: [256]u8 = undefined,
    label_len: usize = 0,
    mode: Mode = .waiting,
    bars_buf: [dict.capacity]dict.Bar = undefined,
    bars_len: usize = 0,
    level: f32 = 0,
    elapsed: ?u64 = null,

    pub fn label(self: *const Frame) []const u8 {
        return self.label_buf[0..self.label_len];
    }
    pub fn bars(self: *const Frame) []const dict.Bar {
        return self.bars_buf[0..self.bars_len];
    }
};

/// `VoiceTween`: interruptible 0↔1 progress of the morph; a retarget starts
/// from the current value, so toggling mid-flight reverses without a jump.
pub const Tween = struct {
    from: f32 = 0,
    to: f32 = 0,
    start: u64 = 0,

    pub fn value(self: Tween, now: u64) f32 {
        const raw = @as(f32, @floatFromInt(now -| self.start)) / @as(f32, @floatFromInt(morph_ns));
        return self.from + (self.to - self.from) * morph_curve.eval(raw);
    }

    pub fn retarget(self: *Tween, to: f32, now: u64, reduced: bool) void {
        if (self.to == to) return;
        self.from = if (reduced) to else self.value(now);
        self.to = to;
        self.start = now;
    }

    pub fn settled(self: Tween, now: u64) bool {
        return self.value(now) == self.to;
    }
};

/// The composer's dictation state (`dictation_hold`, `voice_last`,
/// `voice_tween`, `dictation_focus`, `focus_pending`).
pub const State = struct {
    hold: ?Hold = null,
    last: ?Frame = null,
    tween: Tween = .{},
    /// Return focus to the editor on the next render.
    focus_pending: bool = false,
    /// Tracks the pill + status: only leaving the whole composer cancels.
    focus: ?zpui.FocusHandle = null,
    blur_sub: ?zpui.Subscription = null,
    settings_sub: ?zpui.Subscription = null,
    window_was_active: bool = true,

    pub fn deinit(self: *State, app: *App) void {
        if (self.blur_sub) |*s| s.deinit();
        if (self.settings_sub) |*s| s.deinit();
        if (self.focus) |f| f.release(app);
    }
};

fn nowNs(cx: anytype) u64 {
    return cx.app.executor.now();
}

fn phaseTag(self: *const ComposerView, cx: anytype) dict.PhaseTag {
    return self.input.read(cx).dictation.phase;
}

fn active(self: *const ComposerView, cx: anytype) bool {
    return self.input.read(cx).dictation.phase.active();
}

/// Whether the microphone is offered (`dictation::enabled` and no question).
pub fn available(self: *const ComposerView, cx: anytype) bool {
    return dict.enabled(cx.app) and !extras.wizardActive(self);
}

// ---- hold to talk -----------------------------------------------------------------------

fn toggleIn(in: *TextInput, cx: *InputCtx) void {
    switch (@as(dict.PhaseTag, in.dictation.phase)) {
        .requesting => in.cancelDictationNotify(cx),
        .listening => _ = in.finishDictation(false, cx),
        // The voice track's Cancel stops transcription.
        .finalizing => {},
        else => if (in.isComposing()) {
            in.dictation.setPhase(dict.Phase.withMessage(in.gpa, .unavailable, "Finish composing the current character before starting dictation.") catch return);
            cx.emit(input_mod.TextInputEvent{ .dictation_changed = {} });
            cx.notify();
        } else if (dict.startSession(cx.app)) |t| in.beginDictation(t, cx),
    }
}

/// `toggle_dictation`: `refocus` returns focus to the editor afterwards.
/// Enter/Space on the focused microphone keeps focus there so its key-up
/// ends the hold.
pub fn toggle(self: *ComposerView, refocus: bool, cx: *Ctx) void {
    if (!dict.enabled(cx.app) and !active(self, cx)) return;
    // A queue row still acquiring its edit lease is about to replace the
    // draft, which would discard the dictation.
    if (extras.wizardActive(self) or self.ext.edit_finishing or self.ext.edit_pending != null or
        self.sending or self.input.read(cx).isReadOnly()) return;
    self.input.update(cx, toggleIn, .{});
    self.voice.focus_pending = self.voice.focus_pending or refocus;
    cx.notify();
}

/// `press_dictation`: the microphone or the shortcut going down starts
/// dictation. Pressing during a session started by assistive Click takes it
/// over, so releasing finishes it.
pub fn press(self: *ComposerView, source: HoldSource, cx: *Ctx) void {
    const tag = phaseTag(self, cx);
    const is_active = active(self, cx);
    // Repeats from the same source are ignored. Another source takes the
    // session over, so a hold whose release went missing can always be ended.
    if (is_active) if (self.voice.hold) |h| if (h.source == source) return;
    self.voice.hold = null;
    switch (tag) {
        .finalizing => {},
        .requesting, .listening => self.voice.hold = .{ .source = source, .started = null },
        else => {
            toggle(self, source != .button, cx);
            if (active(self, cx)) self.voice.hold = .{ .source = source, .started = nowNs(cx) };
        },
    }
}

fn releaseIn(in: *TextInput, tapped: bool, cx: *InputCtx) void {
    switch (@as(dict.PhaseTag, in.dictation.phase)) {
        .requesting, .listening => |t| {
            if (t == .requesting and dict.permissionPending(cx.app)) {
                // The release only answered the permission prompt.
                in.cancelDictationNotify(cx);
            } else if (tapped) {
                in.cancelDictation();
                in.dictation.setPhase(.tapped);
                cx.emit(input_mod.TextInputEvent{ .dictation_changed = {} });
                cx.notify();
            } else _ = in.finishDictation(false, cx);
        },
        else => {},
    }
}

/// `release_dictation`: letting go transcribes what was said. A tap
/// explains hold to talk, and a release that only answered the permission
/// prompt records nothing.
pub fn release(self: *ComposerView, source: HoldSource, cx: *Ctx) void {
    const hold = self.voice.hold orelse return;
    if (hold.source != source) return;
    self.voice.hold = null;
    const tapped = if (hold.started) |s| nowNs(cx) -| s < tap_ns else false;
    self.input.update(cx, releaseIn, .{tapped});
    // Only the pointer moved focus to the microphone.
    self.voice.focus_pending = self.voice.focus_pending or source == .pointer;
    cx.notify();
}

/// `dismiss_dictation`: Cancel / Dismiss keep the draft and drop any send.
pub fn dismiss(self: *ComposerView, cx: *Ctx) void {
    self.input.update(cx, dismissIn, .{});
    self.voice.focus_pending = true;
    cx.notify();
}

fn dismissIn(in: *TextInput, cx: *InputCtx) void {
    in.cancelDictation();
    cx.emit(input_mod.TextInputEvent{ .dictation_changed = {} });
    cx.notify();
}

fn cancelIn(in: *TextInput, _: *InputCtx) void {
    in.cancelDictation();
}

// ---- lifecycle --------------------------------------------------------------------------

fn onComposerFocusOut(self: *ComposerView, _: *Window, cx: *Ctx) void {
    // Stop, Send and keyboard navigation within the composer must not
    // discard capture. Only leaving the whole composer invalidates it.
    const in = self.input.read(cx);
    if (!in.dictation.phase.active()) return;
    if (in.dictation.phase == .requesting and dict.permissionPending(cx.app)) return;
    self.input.update(cx, dismissIn, .{});
}

fn onSettings(self: *ComposerView, cx: *Ctx) void {
    // Turning Settings → Voice off stops a live session.
    if (!dict.enabled(cx.app) and self.input.read(cx).dictation.phase.active()) self.input.update(cx, cancelIn, .{});
    cx.notify();
}

/// Subscribe to a settings global `G` (the app's `SettingsStore`).
pub fn observeSettings(self: *ComposerView, comptime G: type, cx: *Ctx) void {
    if (self.voice.settings_sub != null) return;
    self.voice.settings_sub = cx.observeGlobal(G, onSettings) catch null;
}

/// Called at the top of `render`: lazily wires the composer-wide focus
/// tracking, returns focus after a pointer hold, and releases capture when
/// the window stops being active (Rust `observe_window_activation`).
pub fn beforeRender(self: *ComposerView, window: *Window, cx: *Ctx) void {
    if (self.voice.focus == null) {
        const f = cx.focusHandle();
        self.voice.focus = f;
        self.voice.blur_sub = cx.onFocusOut(f, window, onComposerFocusOut) catch null;
    }
    const is_active = window.isWindowActive();
    if (self.voice.window_was_active and !is_active) {
        const in = self.input.read(cx);
        // The permission bridge checks the originating key window before
        // starting any capture after a prompt.
        if (in.dictation.phase.active() and !(in.dictation.phase == .requesting and dict.permissionPending(cx.app)))
            self.input.update(cx, cancelIn, .{});
    }
    self.voice.window_was_active = is_active;
    if (self.voice.focus_pending) {
        self.voice.focus_pending = false;
        window.focus(self.input.read(cx).focus);
    }
}

/// `update_voice`: advance the morph; returns its eased progress and the
/// frame to draw (live while dictating, the last live frame while retracting).
pub fn update(self: *ComposerView, window: *Window, cx: *Ctx) struct { f32, ?*const Frame } {
    const t_now = nowNs(cx);
    const reduced = window.prefersReducedMotion();
    const d = &self.input.read(cx).dictation;
    const is_active = d.phase.active();
    self.voice.tween.retarget(if (is_active) 1.0 else 0.0, t_now, reduced);
    const t = self.voice.tween.value(t_now);
    if (is_active) {
        const meter = &d.meter;
        const mode: Mode = switch (d.phase) {
            .listening => .live,
            .finalizing => if (meter.sinceStart(t_now) != null) .processing else .waiting,
            else => .waiting,
        };
        if (self.voice.last == null) self.voice.last = .{};
        const f = &self.voice.last.?;
        f.mode = mode;
        f.label_len = 0;
        if (d.phase.status()) |st| {
            if (std.fmt.bufPrint(&f.label_buf, "{s}. {s}", .{ st.title, st.detail })) |l| f.label_len = l.len else |_| {}
        }
        f.bars_len = meter.bars(t_now, !reduced, &f.bars_buf).len;
        f.level = if (mode == .live) meter.level(t_now) else 0;
        f.elapsed = if (meter.sinceStart(t_now) != null) meter.elapsed(t_now) else null;
    } else if (t <= 0) {
        self.voice.last = null;
    }
    // Bars scroll, the glow follows the voice, and the morph advances.
    if (!reduced and (is_active or !self.voice.tween.settled(t_now))) window.requestAnimationFrame();
    return .{ t, if (self.voice.last) |*f| f else null };
}

// ---- glass (dictation/glass.rs) ---------------------------------------------------------

fn white(a: f32) Hsla {
    return zpui.hsla(0, 0, 1, a);
}
fn black(a: f32) Hsla {
    return zpui.hsla(0, 0, 0, a);
}
fn shadow(color: Hsla, y: f32, blur: f32, spread: f32, inset: bool) zpui.BoxShadow {
    return .{ .color = color, .offset = .{ .x = 0, .y = y }, .blur_radius = blur, .spread_radius = spread, .inset = inset };
}
fn vertical(top: Hsla, bottom: Hsla) zpui.color.Background {
    return zpui.color.linearGradient(180, zpui.color.linearColorStop(top, 0), zpui.color.linearColorStop(bottom, 1));
}
fn arenaShadows(list: []const zpui.BoxShadow) []const zpui.BoxShadow {
    return zpui.window.arena_mod.current().allocator().dupe(zpui.BoxShadow, list) catch @panic("OOM");
}
/// A lighter tint of `color` for the lit top of a gradient.
fn lift(color: Hsla, amount: f32) Hsla {
    return zt.motion.mix(color, white(color.a), amount);
}

/// `glass::light`: neutral glass plate; `t` fades the whole treatment in.
pub fn light(el: anytype, theme: *const Theme, t: f32) @TypeOf(el) {
    const dark = theme.appearance.isDark();
    const top, const bottom, const rim, const highlight, const drop = if (dark)
        .{ white(0.09), white(0.04), white(0.10), white(0.10), black(0.35) }
    else
        .{ zpui.hsla(0, 0, 0.985, 1), zpui.hsla(0, 0, 0.925, 1), black(0.10), white(0.95), black(0.08) };
    return el.bg(vertical(top.opacity(t), bottom.opacity(t))).border1().borderColor(rim.opacity(t))
        .shadow(arenaShadows(&.{ shadow(highlight.opacity(t), 1, 0, 0, true), shadow(drop.opacity(t), 1, 3, 0, false) }));
}

/// `glass::accent`: accent plate; `glow` (0–1, the live voice level)
/// spreads its coloured shadow.
pub fn accent(el: anytype, theme: *const Theme, t: f32, glow: f32) @TypeOf(el) {
    const dark = theme.appearance.isDark();
    const base = theme.accent;
    const top = lift(base, if (dark) 0.18 else 0.32);
    const rim = lift(base, 0.45).opacity(if (dark) 0.45 else 0.7);
    const highlight = white(if (dark) 0.22 else 0.38);
    const halo = base.opacity((0.22 + 0.4 * glow) * t);
    return el.bg(vertical(top.opacity(t), base.opacity(t))).border1().borderColor(rim.opacity(t))
        .shadow(arenaShadows(&.{
        shadow(highlight.opacity(t), 1, 0, 0, true),
        shadow(white(0.12 * t), 0, 0, 1, true),
        shadow(halo, 2 + 2 * glow, 6 + 14 * glow, 0, false),
    }));
}

// ---- waveform (dictation/waveform.rs) ---------------------------------------------------

pub const bar_width: f32 = 3;
const bar_gap: f32 = 3;
const pitch: f32 = bar_width + bar_gap;
/// Bars dissolve over this distance at the leading edge instead of clipping.
const edge_fade: f32 = 28;
/// Seconds for the transcribing highlight to cross the bars once.
const sweep_period: f32 = 1.6;
/// Seconds per breath of the placeholder baseline while capture starts.
const breath_period: f32 = 1.4;

pub fn easeOut(t0: f32) f32 {
    const t = std.math.clamp(t0, 0, 1);
    return 1 - std.math.pow(f32, 1 - t, 3);
}

fn fract(x: f32) f32 {
    return x - @trunc(x);
}

pub const Wave = struct {
    bars: []const dict.Bar,
    mode: Mode,
    ink: Hsla,
    quiet: Hsla,
    /// Baseline draws in from the trailing edge as the pill appears.
    intro: f32,
    /// Bars settle back into the baseline as the transcript lands.
    collapse: f32,
    motion: bool,
    /// Seconds on a process-wide clock (phase-continuous across renders).
    seconds: f32,
};

/// One quad of the waveform, for painting and tests.
pub const Quad = struct { x: f32, y: f32, h: f32, color: Hsla };

/// The bars `waveform` paints into `bounds` (left, top, width, height).
pub fn layout(w: Wave, left: f32, top: f32, width_px: f32, height: f32, out: []Quad) []Quad {
    const right = left + width_px - bar_width;
    const mid = top + height / 2;
    const width = @max(right - left, 1);
    const offset: f32 = switch (w.mode) {
        .waiting => 0,
        else => if (w.bars.len > 0) fract(w.bars[0].age) else 0,
    };
    const count: usize = @as(usize, @intFromFloat(@ceil((width + bar_width) / pitch))) + 1;
    const now_s = if (w.motion) w.seconds else 0;
    const sweep = fract(now_s / sweep_period);
    const settle = 1 - easeOut(w.collapse);
    var n: usize = 0;
    for (0..count) |k| {
        if (n == out.len) break;
        const kf: f32 = @floatFromInt(k);
        const x = right - (kf + offset) * pitch;
        const fade = std.math.clamp((x - left) / edge_fade, 0, 1);
        // Draw in from the trailing edge: 0 there, 1 at the leading edge.
        const distance = 1 - (x - left) / width;
        const reveal = easeOut((w.intro - 0.5 * distance) / 0.5);
        const alpha = fade * reveal;
        if (alpha <= 0) continue;
        var amplitude: f32 = undefined;
        var color: Hsla = undefined;
        if (w.mode == .waiting or k >= w.bars.len) {
            // A soft swell travels toward the leading edge.
            const swell: f32 = if (w.mode == .waiting) blk: {
                const wave = now_s / breath_period - kf / 18.0;
                break :blk std.math.pow(f32, 0.5 + 0.5 * @sin(wave * std.math.tau), 3);
            } else 0;
            amplitude = dict.floor + 0.1 * swell;
            color = w.quiet;
        } else {
            const bar = w.bars[k];
            // The newest bar rises out of the baseline as it enters.
            const grow = if (w.motion) easeOut(bar.age) else 1;
            const c = if (w.mode == .live) w.ink else blk: {
                // Right-to-left highlight, matching the scroll.
                const position = 1 - (x - left) / width;
                const d = @abs(position - (sweep * 1.4 - 0.2));
                const glow = std.math.clamp(1 - d / 0.18, 0, 1);
                break :blk zt.motion.mix(w.quiet, w.ink, easeOut(glow));
            };
            const lift_ = (1 - dict.floor) * bar.amplitude * grow * settle;
            amplitude = dict.floor + lift_;
            color = zt.motion.mix(w.quiet, c, settle);
        }
        const h = @max(std.math.clamp(amplitude, dict.floor, 1) * height * (0.4 + 0.6 * reveal), bar_width);
        out[n] = .{ .x = x, .y = mid - h / 2, .h = h, .color = color.opacity(color.a * alpha) };
        n += 1;
    }
    return out[0..n];
}

fn paintWave(w: Wave, bounds: zpui.Bounds(f32), window: *Window, _: *App) void {
    var buf: [512]Quad = undefined;
    for (layout(w, bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height, &buf)) |q| {
        window.paintQuad(zpui.fill(.{ .origin = .{ .x = q.x, .y = q.y }, .size = .{ .width = bar_width, .height = q.h } }, q.color).cornerRadii(bar_width / 2));
    }
}

/// `waveform::waveform`: one rounded bar per meter slot on a single canvas.
pub fn waveform(w: Wave) zpui.elements.Canvas {
    var copy = w;
    copy.bars = zpui.window.arena_mod.current().allocator().dupe(dict.Bar, w.bars) catch &.{};
    return zpui.canvas(copy, paintWave).flex1().minW0().hFull();
}

/// The process-wide waveform clock (`waveform::seconds`).
fn seconds(cx: anytype) f32 {
    return @as(f32, @floatFromInt(nowNs(cx) % (3600 * std.time.ns_per_s))) / @as(f32, std.time.ns_per_s);
}

// ---- rendering --------------------------------------------------------------------------

fn spinner(tint: Hsla, cx: anytype) zpui.Div {
    // `loaders::mini_mono_spinner(_, 2.0, on_accent)`: the 2×3 grid whose
    // brightness chases around the ring.
    const period: u64 = zt.motion.gradient_spin.duration_ms * std.time.ns_per_ms;
    const phase = @as(f32, @floatFromInt(nowNs(cx) % period)) / @as(f32, @floatFromInt(period));
    const ring = [3][2]usize{ .{ 0, 1 }, .{ 5, 2 }, .{ 4, 3 } };
    const cell: f32 = 2;
    var col = div().flexNone().flex().flexCol().gap(px(cell / 2));
    for (0..3) |row| {
        var r = div().flex().flexRow().gap(px(cell / 2));
        for (0..2) |c| {
            const op = zt.motion.gspinOpacity(phase + @as(f32, @floatFromInt(ring[row][c])) / 6.0, zt.motion.gspin_dim);
            r = r.child(div().size(px(cell)).rounded(px(cell / 2)).bg(tint).opacity(op));
        }
        col = col.child(r);
    }
    return col;
}

fn centered() zpui.Div {
    return div().absolute().inset0().flex().itemsCenter().justifyCenter();
}

fn onMicDown(self: *ComposerView, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Ctx) void {
    press(self, .pointer, cx);
}
fn onMicUp(self: *ComposerView, _: *const zpui.input.MouseUpEvent, _: *Window, cx: *Ctx) void {
    release(self, .pointer, cx);
}
fn onMicKeyDown(self: *ComposerView, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Ctx) void {
    if (!isActivate(ev.keystroke.key)) return;
    cx.stopPropagation();
    if (!ev.is_held) press(self, .button, cx);
}
fn onMicKeyUp(self: *ComposerView, ev: *const zpui.input.KeyUpEvent, _: *Window, cx: *Ctx) void {
    if (!isActivate(ev.keystroke.key)) return;
    cx.stopPropagation();
    release(self, .button, cx);
}
/// Assistive technology cannot hold: Click starts, then finishes.
fn onMicA11yClick(self: *ComposerView, _: *const zpui.a11y.ActionRequest, _: *Window, cx: *Ctx) void {
    toggle(self, true, cx);
}

fn isActivate(key: []const u8) bool {
    return std.mem.eql(u8, key, "enter") or std.mem.eql(u8, key, "space");
}

/// `render_dictation_button`: the microphone at rest; the one Stop control
/// while dictating. `t` morphs the mic glyph out and the accent glass plate,
/// stop square or spinner in; the glow follows the live voice level.
pub fn renderButton(self: *ComposerView, t: f32, frame: ?*const Frame, cx: *Ctx) ?zpui.StatefulDiv {
    if (!available(self, cx)) return null;
    const theme = &self.theme;
    const phase = &self.input.read(cx).dictation.phase;
    const is_active = phase.active();
    const label = phase.actionLabel();
    const live = if (frame) |f| f.mode == .live else false;
    const glow = if (frame) |f| f.level * @sqrt(f.level) else 0;
    // Spinner while the microphone opens or the model transcribes; the stop
    // square once the voice is live (and while retracting from it).
    const busy = phase.* == .requesting or phase.* == .finalizing or
        (!is_active and frame != null and frame.?.mode != .live);
    var b = div().id("composer-dictation").relative().size(px(28)).flexNone().roundedFull()
        .role(.button).ariaLabel(label).ariaToggled(is_active).tabIndex(0).cursorPointer()
        .focusVisible(sb.border1().borderColor(theme.accent))
        .tooltipWith(chrome.TipData{ .text = label, .dark = theme.appearance.isDark() }, chrome.buildTooltip)
        .onMouseDown(.left, cx.listener(onMicDown))
        .onMouseUp(.left, cx.listener(onMicUp))
        .onMouseUpOut(.left, cx.listener(onMicUp))
        .onKeyDown(cx.listener(onMicKeyDown))
        .onKeyUp(cx.listener(onMicKeyUp))
        .onA11yAction(.click, cx.listener(onMicA11yClick));
    // At rest it is a sibling of the paperclip: the same ink wash. Live, it
    // is the accent plate and dims like Send.
    if (t <= 0) {
        b = b.hover(sb.bg(chrome.actionWash(theme)));
    } else {
        b = accent(b, theme, t, glow).hover(sb.opacity(0.85));
    }
    if (t < 1) {
        const scale = 1 - 0.75 * t;
        b = b.child(centered().child(chrome.icon(.microphone, 18, theme.text_muted.opacity(theme.text_muted.a * (1 - t)))
            .withTransformation(zpui.SvgTransformation.scaled(.{ .width = scale, .height = scale }))));
    }
    if (t > 0 and busy) {
        b = b.child(centered().opacity(t).child(spinner(theme.on_accent, cx)));
    }
    if (t > 0 and !busy) {
        // Square grows from a quarter of its size, as the mic shrinks.
        const side = 9 * (0.25 + 0.75 * t) * (if (live) 1 + 0.08 * glow else 1);
        b = b.child(centered().child(div().size(px(side)).rounded(px(2.5)).bg(theme.on_accent.opacity(theme.on_accent.a * t))));
    }
    return b;
}

fn onAttachKey(self: *ComposerView, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Ctx) void {
    if (!isActivate(ev.keystroke.key)) return;
    cx.stopPropagation();
    if (active(self, cx)) dismiss(self, cx) else self.openFilePicker(cx);
}
fn onAttachA11y(self: *ComposerView, _: *const zpui.a11y.ActionRequest, _: *Window, cx: *Ctx) void {
    if (active(self, cx)) dismiss(self, cx) else self.openFilePicker(cx);
}

/// The attachment slot: while dictating it becomes Cancel; the paperclip
/// and the cross swap with a scale and fade. The action follows the
/// dictation phase, never the animation.
pub fn decorateAttach(self: *ComposerView, b: zpui.StatefulDiv, t: f32, cx: *Ctx) zpui.StatefulDiv {
    const theme = &self.theme;
    const dictating = active(self, cx);
    const label: []const u8 = if (dictating) "Cancel dictation" else "Attach images";
    var el = b.role(.button).ariaLabel(label).tabIndex(0)
        .focusVisible(sb.border1().borderColor(theme.accent))
        .tooltipWith(chrome.TipData{ .text = label, .dark = theme.appearance.isDark() }, chrome.buildTooltip)
        .onKeyDown(cx.listener(onAttachKey))
        .onA11yAction(.click, cx.listener(onAttachA11y));
    if (t < 1) {
        const scale = 1 - 0.75 * t;
        el = el.child(centered().child(chrome.icon(.paperclip, 18, theme.text_muted.opacity(theme.text_muted.a * (1 - t)))
            .withTransformation(zpui.SvgTransformation.scaled(.{ .width = scale, .height = scale }))));
    }
    if (t > 0) {
        const scale = 0.25 + 0.75 * t;
        el = el.child(centered().child(chrome.icon(.close, 16, theme.text_muted.opacity(theme.text_muted.a * t))
            .withTransformation(zpui.SvgTransformation.scaled(.{ .width = scale, .height = scale }))));
    }
    return el;
}

/// `render_voice_track`: the waveform track that unrolls from Stop across
/// the action row. The box keeps its final geometry and occludes the
/// controls fading out beneath it.
pub fn renderTrack(self: *ComposerView, t: f32, frame: *const Frame, left: f32, right: f32, top: f32, window: *Window, cx: *Ctx) zpui.StatefulDiv {
    const theme = &self.theme;
    const animate = !window.prefersReducedMotion();
    const is_active = active(self, cx);
    const live = frame.mode == .live and is_active;
    var track = light(div().id("dictation-live-status").role(.status).ariaLabel(frame.label())
        .hFull().w(zpui.relative(@max(t, 0))).minW(px(track_height * @min(t, 1))).roundedFull().overflowHidden()
        .flex().itemsCenter().gap(px(10)).pl(px(12)).pr(px(12)), theme, t)
        .child(div().flex1().minW0().h(px(16)).flex().child(waveform(.{
        .bars = frame.bars(),
        .mode = frame.mode,
        .ink = theme.text.opacity(0.8),
        .quiet = theme.text_faint.opacity(0.5),
        .intro = t,
        .collapse = if (is_active) 0 else 1 - t,
        .motion = animate,
        .seconds = seconds(cx),
    })));
    if (frame.elapsed) |elapsed| {
        const limit = max_seconds * std.time.ns_per_s;
        const color = if (live and elapsed + limit_warning_ns >= limit) theme.warning else if (live) theme.text_muted else theme.text_faint;
        var buf: [16]u8 = undefined;
        track = track.child(div().flexNone().fontFamily(theme.font_mono).textSize(px(11)).opacity(t).textColor(color)
            .child(zpui.fmt("{s}", .{dict.clockLabel(&buf, elapsed)})));
    }
    return div().id("dictation-track").absolute().left(px(left)).right(px(right)).top(px(top)).h(px(track_height))
        .flex().justifyEnd().occlude().child(track);
}

fn onDismissClick(self: *ComposerView, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    dismiss(self, cx);
}
fn onDismissKey(self: *ComposerView, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Ctx) void {
    if (!isActivate(ev.keystroke.key)) return;
    cx.stopPropagation();
    dismiss(self, cx);
}
fn onDismissA11y(self: *ComposerView, _: *const zpui.a11y.ActionRequest, _: *Window, cx: *Ctx) void {
    dismiss(self, cx);
}

fn fadeInFrame(el: zpui.Div, t: f32) zpui.Div {
    return el.relative().opacity(t).top(px(4 * (1 - t)));
}

/// `render_dictation_status`: live dictation renders inside the composer;
/// only outcomes that need reading (no speech, errors) appear below it.
pub fn renderStatus(self: *ComposerView, cx: *Ctx) ?@TypeOf(zpui.withAnimation(div(), "dictation-message-enter", zpui.Animation.ms(500), fadeInFrame)) {
    const phase = &self.input.read(cx).dictation.phase;
    if (phase.active()) return null;
    const st = phase.status() orelse return null;
    const failed = switch (phase.*) {
        .denied, .unavailable, .failed => true,
        else => false,
    };
    const theme = &self.theme;
    const dismiss_btn = div().id("dictation-dismiss").role(.button).ariaLabel("Dismiss dictation message").tabIndex(0)
        .flexNone().h(px(24)).px(px(8)).flex().itemsCenter().roundedFull().textColor(theme.text_muted).cursorPointer()
        .hover(sb.bg(theme.surface_raised_hover).textColor(theme.text))
        .focusVisible(sb.border1().borderColor(theme.accent))
        .onClick(cx.listener(onDismissClick))
        .onKeyDown(cx.listener(onDismissKey))
        .onA11yAction(.click, cx.listener(onDismissA11y))
        .mt(px(-3)).child("Dismiss");
    const body = div().flex().itemsStart().gap(px(8)).px(px(12)).textSize(px(12)).lineHeight(px(18))
        .child(div().flexNone().mt(px(6)).size(px(6)).roundedFull().bg(if (failed) theme.warning else theme.text_faint))
        .child(div().id("dictation-status-text").role(.status).ariaLabel(zpui.fmt("{s}. {s}", .{ st.title, st.detail }))
        .flex1().minW0().flex().flexWrap().gapX(px(8))
        .child(div().textColor(theme.text).child(zpui.fmt("{s}", .{st.title})))
        .child(div().minW0().textColor(theme.text_muted).child(zpui.fmt("{s}", .{st.detail}))))
        .child(dismiss_btn);
    return zpui.withAnimation(body, "dictation-message-enter", zpui.Animation.ms(500).withEasing(zpui.easing.ease_out_expo), fadeInFrame);
}

fn onFocusKey(self: *ComposerView, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Ctx) void {
    if (std.mem.eql(u8, ev.keystroke.key, "escape") and active(self, cx)) {
        dismiss(self, cx);
        cx.stopPropagation();
    }
}

/// The composer-wide focus region around the pill and the status strip
/// (Escape anywhere in it cancels a live session).
pub fn focusRegion(self: *ComposerView, cx: *Ctx) zpui.Div {
    var d = div().flex().flexCol().gap(px(zt.layout.space_sm)).onKeyDown(cx.listener(onFocusKey));
    if (self.voice.focus) |f| d = d.trackFocus(f);
    return d;
}

/// The input's `dictation_*` events (Rust `DictationInputEvent`); the
/// submit event is the caller's (it needs the composer's private send).
pub fn onInputEvent(self: *ComposerView, ev: input_mod.TextInputEvent, cx: *Ctx) void {
    switch (ev) {
        .dictation_press => press(self, .key, cx),
        .dictation_release => release(self, .key, cx),
        .dictation_changed => cx.notify(),
        else => {},
    }
}
