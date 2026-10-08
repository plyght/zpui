//! zpui-drawn form controls that imitate the desktop toolkit where the platform has no
//! embeddable native controls (Linux): GNOME / libadwaita (GtkSwitch, GtkCheckButton,
//! GtkScale, AdwToggleGroup, GtkDropDown, GtkSpinButton) and KDE Plasma / Breeze.
//!
//! Opt-in per window (`Window.setDesktopControls(true)`; default off, so existing
//! `native*` callers keep their fallbacks): a `nativeSwitch` & co. element whose window
//! shows no native control then draws the desktop control instead of its fallback, in the
//! look `Window.desktopTheme()` names (style from `XDG_CURRENT_DESKTOP` /
//! `ZPUI_DESKTOP_STYLE`, accent from the settings portal, light / dark from the theme
//! pin or the window appearance). Same events as the AppKit controls
//! (`NativeControlEvent`), so app code is unchanged.
//!
//! Behavior: hover / pressed / keyboard-focus ring, Space / Enter toggle and activate,
//! arrows step sliders, spin buttons, toggle groups and drop-down lists, Home / End and
//! Page Up / Down on sliders and spin buttons, Escape closes a drop-down. Switch knobs,
//! check marks and the toggle-group selection ease over 180 ms (cubic out); frames are
//! requested only while a transition runs, and reduced motion snaps. Accessibility roles
//! (switch, check box, slider, radio buttons, combo box, spin button) go through the
//! normal a11y tree (AT-SPI on Linux). Per-control state lives in element state; the
//! frame's elements are built in the frame arena (no heap allocations per frame).

const std = @import("std");
const geometry = @import("../geometry.zig");
const platform = @import("../platform/platform.zig");
const style_mod = @import("../style.zig");
const StyleBuilder = @import("../style/builder.zig").StyleBuilder;
const App = @import("../app/app.zig").App;
const context = @import("../app/context.zig");
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const DispatchPhase = window_mod.DispatchPhase;
const element = @import("../window/element.zig");
const arena_mod = @import("../window/arena.zig");
const events = @import("../window/events.zig");
const input = @import("../input.zig");
const div_mod = @import("div.zig");
const svg_mod = @import("svg.zig");
const deferred_mod = @import("deferred.zig");
const anchored_mod = @import("anchored.zig");
pub const theme = @import("desktop_theme.zig");

const AnyElement = element.AnyElement;
const ElementId = element.ElementId;
const GlobalElementId = element.GlobalElementId;
const LayoutId = element.LayoutId;
const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds(Pixels);
const Point = geometry.Point(Pixels);
const px = geometry.px;
const Hsla = theme.Hsla;
const BoxShadow = style_mod.BoxShadow;
const div = div_mod.div;
const sb = StyleBuilder.init;
const ClickEvent = events.ClickEvent;
const ListenerData = context.ListenerData;

pub const Look = theme.Look;
pub const State = platform.NativeControlState;
pub const Event = platform.NativeControlEvent;
pub const Listener = context.Listener(Event);

/// Transition length of knobs, check marks and toggle-group selections.
pub const transition_ms: u64 = 180;

// ---------------------------------------------------------------------------------------
// Look selection
// ---------------------------------------------------------------------------------------

/// Whether `theme_pin` / the window says dark.
pub fn isDark(window: *const Window, pin: ?bool) bool {
    const t = window.desktopTheme();
    return t.dark orelse pin orelse window.glass_dark orelse switch (window.windowAppearance()) {
        .dark, .vibrant_dark => true,
        .light, .vibrant_light => false,
    };
}

/// The look drawn controls use in `window`, or null when the window does not draw desktop
/// controls (not opted in, native controls switched off, or no desktop style).
pub fn controlLook(window: *Window, pin_dark: ?bool) ?Look {
    if (!window.native_controls.desktop_drawn or window.native_controls.disabled) return null;
    const t = window.desktopTheme();
    const family = theme.Family.fromStyle(t.style) orelse return null;
    return theme.look(family, isDark(window, pin_dark), t.accent);
}

/// The first of `look.fonts` the text system has (the last entry is a generic family).
pub fn fontFamily(window: *Window, look: Look) []const u8 {
    const ts = window.app.textSystem();
    for (look.fonts) |f| {
        _ = ts.fontId(.{ .family = f }) catch continue;
        return f;
    }
    return look.fonts[look.fonts.len - 1];
}

// ---------------------------------------------------------------------------------------
// Pure control logic (unit-tested)
// ---------------------------------------------------------------------------------------

/// A retargetable eased transition between two scalar positions.
pub const Tween = struct {
    from: f32 = 0,
    to: f32 = 0,
    start_ns: u64 = 0,
    started: bool = false,

    /// Aim at `target` (no motion the first time, or under reduced motion).
    pub fn retarget(self: *Tween, target: f32, now: u64, reduced: bool) void {
        if (!self.started or reduced) {
            self.* = .{ .from = target, .to = target, .start_ns = now, .started = true };
            return;
        }
        if (target == self.to) return;
        self.from = self.value(now);
        self.to = target;
        self.start_ns = now;
    }

    pub fn progress(self: Tween, now: u64) f32 {
        const dur: f64 = @floatFromInt(transition_ms * std.time.ns_per_ms);
        const t: f64 = @as(f64, @floatFromInt(now -| self.start_ns)) / dur;
        return @floatCast(@min(t, 1));
    }

    /// Cubic ease-out between `from` and `to`.
    pub fn value(self: Tween, now: u64) f32 {
        const t = self.progress(now);
        const inv = 1 - t;
        const eased = 1 - inv * inv * inv;
        return self.from + (self.to - self.from) * eased;
    }

    pub fn running(self: Tween, now: u64) bool {
        return self.from != self.to and self.progress(now) < 1;
    }
};

/// `v` clamped to [min, max] and snapped to `step` (counted from `min`) when step > 0.
pub fn snap(v: f64, min: f64, max: f64, step: f64) f64 {
    const lo = @min(min, max);
    const hi = @max(min, max);
    var x = std.math.clamp(v, lo, hi);
    if (step > 0) {
        x = lo + @round((x - lo) / step) * step;
        x = std.math.clamp(x, lo, hi);
    }
    return x;
}

/// 0..1 position of `v` on [min, max].
pub fn fraction(v: f64, min: f64, max: f64) f32 {
    if (max <= min) return 0;
    return @floatCast(std.math.clamp((v - min) / (max - min), 0, 1));
}

/// The slider value under window x `x` for a track whose usable span starts at `x0` and is
/// `span` wide.
pub fn sliderValueAt(x: Pixels, x0: Pixels, span: Pixels, min: f64, max: f64, step: f64) f64 {
    const f: f64 = if (span <= 0) 0 else std.math.clamp((x - x0) / span, 0, 1);
    return snap(min + f * (max - min), min, max, step);
}

/// The increment arrow keys apply: `step`, else 1 % of the range (GtkScale-like).
pub fn keyStep(min: f64, max: f64, step: f64) f64 {
    return if (step > 0) step else @abs(max - min) / 100;
}

pub const KeyAction = enum { dec, inc, page_dec, page_inc, home, end, close, prev, next };

/// What a keystroke does to a control of `kind` (null = not handled). Space / Enter are
/// keyboard clicks (`onClick`), not listed here.
pub fn keyAction(kind: platform.NativeControlKind, key: []const u8) ?KeyAction {
    const eq = std.mem.eql;
    return switch (kind) {
        .slider, .stepper => if (eq(u8, key, "left") or eq(u8, key, "down")) .dec //
            else if (eq(u8, key, "right") or eq(u8, key, "up")) .inc //
            else if (eq(u8, key, "pagedown")) .page_dec //
            else if (eq(u8, key, "pageup")) .page_inc //
            else if (eq(u8, key, "home")) .home //
            else if (eq(u8, key, "end")) .end //
            else null,
        .segmented => if (eq(u8, key, "left") or eq(u8, key, "up")) .prev //
            else if (eq(u8, key, "right") or eq(u8, key, "down")) .next //
            else if (eq(u8, key, "home")) .home //
            else if (eq(u8, key, "end")) .end //
            else null,
        .popup => if (eq(u8, key, "up")) .prev //
            else if (eq(u8, key, "down")) .next //
            else if (eq(u8, key, "escape")) .close //
            else if (eq(u8, key, "home")) .home //
            else if (eq(u8, key, "end")) .end //
            else null,
        .switch_, .checkbox => null,
    };
}

/// The value a slider / stepper takes for `action` (null = no change).
pub fn stepValue(action: KeyAction, value: f64, min: f64, max: f64, step: f64) ?f64 {
    const k = keyStep(min, max, step);
    const next: f64 = switch (action) {
        .dec => value - k,
        .inc => value + k,
        .page_dec => value - k * 10,
        .page_inc => value + k * 10,
        .home => min,
        .end => max,
        else => return null,
    };
    const v = snap(next, min, max, step);
    return if (v == value) null else v;
}

/// The index `action` moves a selection to among `count` items (no wrap; null = none).
pub fn moveIndex(action: KeyAction, selected: ?u32, count: u32) ?u32 {
    if (count == 0) return null;
    const last = count - 1;
    const cur = selected orelse return switch (action) {
        .prev, .end => last,
        .next, .home => 0,
        else => null,
    };
    const next: u32 = switch (action) {
        .prev => cur -| 1,
        .next => @min(cur + 1, last),
        .home => 0,
        .end => last,
        else => return null,
    };
    return if (next == cur) null else next;
}

/// Decimal places to show for a stepper with `step` (0..3).
pub fn decimals(step: f64) u8 {
    var s = @abs(step);
    var d: u8 = 0;
    while (d < 3 and @abs(s - @round(s)) > 1e-7) : (d += 1) s *= 10;
    return d;
}

/// The weight (0..1) of item `i` in a sliding selection at position `pos`.
pub fn selectionWeight(pos: f32, i: u32) f32 {
    return std.math.clamp(1 - @abs(pos - @as(f32, @floatFromInt(i))), 0, 1);
}

// ---------------------------------------------------------------------------------------
// Element
// ---------------------------------------------------------------------------------------

/// What a drawn control keeps between frames (element state).
pub const ControlState = struct {
    tween: Tween = .{},
    listener: ?Listener = null,
    kind: platform.NativeControlKind = .switch_,
    enabled: bool = true,
    on: bool = false,
    value: f64 = 0,
    min: f64 = 0,
    max: f64 = 1,
    step: f64 = 0,
    selected: ?u32 = null,
    count: u32 = 0,
    /// Slider knob drag in progress (window-level move / up listeners while set).
    dragging: bool = false,
    /// Drop-down list open, and its keyboard highlight.
    open: bool = false,
    highlight: u32 = 0,
    /// The control's bounds last frame (slider hit math, popover width).
    bounds: Bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
    /// Slider geometry within `bounds`: knob diameter.
    knob: Pixels = 20,

    fn sync(self: *ControlState, s: State, listener: ?Listener) void {
        self.listener = listener;
        self.kind = s.kind;
        self.enabled = s.enabled;
        self.on = s.on;
        self.value = s.value;
        self.min = s.min;
        self.max = s.max;
        self.step = s.step;
        self.selected = s.selected;
        self.count = @intCast(s.items.len);
        if (!s.enabled) {
            self.open = false;
            self.dragging = false;
        }
    }

    fn emit(self: *ControlState, ev: Event, window: *Window, app: *App) void {
        if (!self.enabled) return;
        const l = self.listener orelse return;
        l.callIn(&ev, window, app);
    }
};

const Data = struct {
    id: ElementId,
    state: State,
    width: ?Pixels,
    listener: ?Listener,
    look: Look,
};

/// The drawn control for `state` (laid out by itself; `width` overrides the natural width).
pub fn drawn(id: ElementId, state: State, width: ?Pixels, listener: ?Listener, look: Look) AnyElement {
    return AnyElement.new(DrawnElement{ .d = arena_mod.current().create(Data, .{
        .id = id,
        .state = state,
        .width = width,
        .listener = listener,
        .look = look,
    }) });
}

const DrawnElement = struct {
    d: *Data,

    pub const RequestLayoutState = AnyElement;

    pub fn elementId(self: *DrawnElement) ?ElementId {
        return self.d.id;
    }

    pub fn requestLayout(self: *DrawnElement, gid: ?GlobalElementId, rl: *AnyElement, window: *Window, cx: *App) LayoutId {
        const d = self.d;
        const st = window.elementState(ControlState, gid.?);
        st.sync(d.state, d.listener);
        const now = cx.executor.now();
        const target: f32 = switch (d.state.kind) {
            .switch_, .checkbox => if (d.state.on) 1 else 0,
            .segmented => @floatFromInt(d.state.selected orelse 0),
            else => 0,
        };
        st.tween.retarget(target, now, window.prefersReducedMotion());
        const t = st.tween.value(now);
        if (st.tween.running(now)) window.requestAnimationFrame();
        var b: Builder = .{ .st = st, .s = d.state, .look = d.look, .width = d.width, .t = t, .font = fontFamily(window, d.look) };
        const el = b.build();
        rl.* = el;
        return el.requestLayout(window, cx);
    }

    pub fn prepaint(_: *DrawnElement, gid: ?GlobalElementId, bounds: Bounds, rl: *AnyElement, _: *void, window: *Window, cx: *App) void {
        const st = window.elementState(ControlState, gid.?);
        st.bounds = bounds;
        rl.prepaint(window, cx);
    }

    pub fn paint(_: *DrawnElement, gid: ?GlobalElementId, _: Bounds, rl: *AnyElement, _: *void, window: *Window, cx: *App) void {
        rl.paint(window, cx);
        const st = window.elementState(ControlState, gid.?);
        if (st.dragging) {
            const Drag = struct { st: *ControlState };
            window.onMouseEvent(input.MouseMoveEvent, Drag{ .st = st }, struct {
                fn f(c: *Drag, ev: *const input.MouseMoveEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                    if (phase != .bubble or !c.st.dragging) return;
                    if (ev.pressed_button != .left) {
                        c.st.dragging = false;
                        w.refresh();
                        return;
                    }
                    sliderTo(c.st, ev.position.x, w, a);
                }
            }.f);
            window.onMouseEvent(input.MouseUpEvent, Drag{ .st = st }, struct {
                fn f(c: *Drag, _: *const input.MouseUpEvent, phase: DispatchPhase, w: *Window, _: *App) void {
                    if (phase != .bubble or !c.st.dragging) return;
                    c.st.dragging = false;
                    w.refresh();
                }
            }.f);
        }
    }
};

// ---------------------------------------------------------------------------------------
// Listeners bound to the element state
// ---------------------------------------------------------------------------------------

const Cap = extern struct { st: *ControlState, arg: u32 };

fn bind(comptime Ev: type, st: *ControlState, arg: u32, comptime f: fn (*ControlState, u32, *const Ev, *Window, *App) void) context.Listener(Ev) {
    const Gen = struct {
        fn call(ld: *const ListenerData, ev: *const Ev, w: ?*Window, a: *App) void {
            const c = ld.get(Cap);
            f(c.st, c.arg, ev, w orelse return, a);
        }
    };
    var ld: ListenerData = .{};
    ld.set(Cap{ .st = st, .arg = arg });
    return .{ .func = Gen.call, .data = ld };
}

fn onToggle(st: *ControlState, _: u32, _: *const ClickEvent, w: *Window, a: *App) void {
    st.emit(.{ .kind = st.kind, .on = !st.on }, w, a);
}

fn onSegment(st: *ControlState, i: u32, _: *const ClickEvent, w: *Window, a: *App) void {
    if (st.selected == i) return;
    st.emit(.{ .kind = st.kind, .index = i }, w, a);
}

fn onSegmentKey(st: *ControlState, _: u32, ev: *const input.KeyDownEvent, w: *Window, a: *App) void {
    const action = keyAction(.segmented, ev.keystroke.key) orelse return;
    const next = moveIndex(action, st.selected, st.count) orelse return;
    st.emit(.{ .kind = st.kind, .index = next }, w, a);
    a.propagate_event = false;
}

fn sliderTo(st: *ControlState, x: Pixels, w: *Window, a: *App) void {
    const half = st.knob / 2;
    const v = sliderValueAt(x, st.bounds.origin.x + half, st.bounds.size.width - st.knob, st.min, st.max, st.step);
    if (v != st.value) st.emit(.{ .kind = .slider, .value = v }, w, a);
}

fn onSliderDown(st: *ControlState, _: u32, ev: *const input.MouseDownEvent, w: *Window, a: *App) void {
    if (!st.enabled) return;
    st.dragging = true;
    sliderTo(st, ev.position.x, w, a);
    w.refresh();
}

fn onStepKey(st: *ControlState, _: u32, ev: *const input.KeyDownEvent, w: *Window, a: *App) void {
    const action = keyAction(st.kind, ev.keystroke.key) orelse return;
    const v = stepValue(action, st.value, st.min, st.max, st.step) orelse return;
    st.emit(.{ .kind = st.kind, .value = v }, w, a);
    a.propagate_event = false;
}

fn onStepButton(st: *ControlState, up: u32, _: *const ClickEvent, w: *Window, a: *App) void {
    const v = stepValue(if (up == 1) .inc else .dec, st.value, st.min, st.max, st.step) orelse return;
    st.emit(.{ .kind = st.kind, .value = v }, w, a);
}

fn onPopupClick(st: *ControlState, _: u32, ev: *const ClickEvent, w: *Window, a: *App) void {
    if (st.open) {
        st.open = false;
        // Keyboard activation while open picks the highlighted row (GtkDropDown).
        if (ev.* == .keyboard and st.selected != st.highlight and st.highlight < st.count)
            st.emit(.{ .kind = .popup, .index = st.highlight }, w, a);
    } else {
        st.open = true;
        st.highlight = st.selected orelse 0;
    }
    w.refresh();
}

fn onPopupKey(st: *ControlState, _: u32, ev: *const input.KeyDownEvent, w: *Window, a: *App) void {
    const action = keyAction(.popup, ev.keystroke.key) orelse return;
    if (action == .close) {
        if (!st.open) return;
        st.open = false;
    } else if (!st.open) {
        // Closed: arrows change the selection directly (GtkDropDown opens on Down; we
        // open too, keeping the selection).
        st.open = true;
        st.highlight = st.selected orelse 0;
    } else {
        st.highlight = moveIndex(action, st.highlight, st.count) orelse st.highlight;
    }
    a.propagate_event = false;
    w.refresh();
}

fn onPopupPick(st: *ControlState, i: u32, _: *const ClickEvent, w: *Window, a: *App) void {
    st.open = false;
    if (st.selected != i) st.emit(.{ .kind = .popup, .index = i }, w, a);
    w.refresh();
}

fn onPopupHover(st: *ControlState, i: u32, hovered: *const bool, w: *Window, _: *App) void {
    if (hovered.* and st.highlight != i) {
        st.highlight = i;
        w.refresh();
    }
}

fn onPopupOutside(st: *ControlState, _: u32, ev: *const input.MouseDownEvent, w: *Window, _: *App) void {
    if (!st.open) return;
    // A press on the button itself is the button's click (it closes the list).
    if (st.bounds.contains(ev.position)) return;
    st.open = false;
    w.refresh();
}

// ---------------------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------------------

pub const icons = struct {
    pub const check = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\"><path d=\"M3.5 8.5l3 3 6-7\" fill=\"none\" stroke=\"#000\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>";
    pub const chevron_down = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\"><path d=\"M4 6.25l4 4 4-4\" fill=\"none\" stroke=\"#000\" stroke-width=\"1.6\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>";
    pub const chevron_up = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\"><path d=\"M4 9.75l4-4 4 4\" fill=\"none\" stroke=\"#000\" stroke-width=\"1.6\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>";
    pub const plus = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\"><path d=\"M8 2.5v11M2.5 8h11\" fill=\"none\" stroke=\"#000\" stroke-width=\"1.6\" stroke-linecap=\"round\"/></svg>";
    pub const minus = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\"><path d=\"M2.5 8h11\" fill=\"none\" stroke=\"#000\" stroke-width=\"1.6\" stroke-linecap=\"round\"/></svg>";
    pub const close = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\"><path d=\"M4 4l8 8M12 4l-8 8\" fill=\"none\" stroke=\"#000\" stroke-width=\"1.6\" stroke-linecap=\"round\"/></svg>";
    pub const trash = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\"><path d=\"M2.5 4h11M6 4V2.5h4V4M4 4l.7 9.5h6.6L12 4M6.6 6.5v4.5M9.4 6.5v4.5\" fill=\"none\" stroke=\"#000\" stroke-width=\"1.3\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>";
};

/// A monochrome icon (`icons.*`) tinted `c`, `size` px.
pub fn icon(name: []const u8, source: []const u8, size: Pixels, c: Hsla) svg_mod.Svg {
    return svg_mod.svg().source(name, source).flexNone().w(px(size)).h(px(size)).textColor(c);
}

/// Frame-arena copy of shadows (style slices must outlive the frame).
pub fn shadows(list: []const BoxShadow) []const BoxShadow {
    return arena_mod.frameAllocator().dupe(BoxShadow, list) catch @panic("OOM");
}

/// The keyboard focus ring of `look` around an element.
pub fn focusRing(look: Look) []const BoxShadow {
    const spread: Pixels = if (look.family == .breeze) 1 else 2;
    return shadows(&.{.{ .color = look.focus_ring, .offset = .{ .x = 0, .y = 0 }, .spread_radius = spread }});
}

fn hover(c: Hsla, look: Look) Hsla {
    return theme.mix(c, if (look.dark) theme.rgbA(0xffffff, 1) else theme.rgbA(0x000000, 1), 0.08);
}

fn press(c: Hsla, look: Look) Hsla {
    return theme.mix(c, if (look.dark) theme.rgbA(0xffffff, 1) else theme.rgbA(0x000000, 1), 0.16);
}

const Builder = struct {
    st: *ControlState,
    s: State,
    look: Look,
    width: ?Pixels,
    /// Eased transition position (switch / check: 0..1; segmented: selection index).
    t: f32,
    font: []const u8,

    fn build(b: *Builder) AnyElement {
        const body: AnyElement = switch (b.s.kind) {
            .switch_ => b.switchEl(),
            .checkbox => b.checkbox(),
            .slider => b.slider(),
            .segmented => b.segmented(),
            .popup => b.popup(),
            .stepper => b.stepper(),
        };
        var root = div().flex().flexNone().itemsCenter()
            .fontFamily(b.font).textSize(px(b.look.font_size)).lineHeight(px(b.look.line_height))
            .textColor(b.look.fg);
        if (!b.s.enabled) root = root.opacity(b.look.disabled_opacity);
        return element.intoAnyElement(root.child(body));
    }

    fn label(b: *const Builder) []const u8 {
        return if (b.s.label.len > 0) b.s.label else b.s.title;
    }

    fn switchEl(b: *Builder) AnyElement {
        const lk = b.look;
        const breeze = lk.family == .breeze;
        const w: Pixels = if (breeze) 36 else 46;
        const h: Pixels = if (breeze) 20 else 26;
        const k: Pixels = if (breeze) 20 else 20;
        const pad: Pixels = if (breeze) 0 else 3;
        const t = b.t;
        const accent_hover = if (lk.dark) theme.mix(lk.accent, theme.rgbA(0xffffff, 1), 0.1) else theme.mix(lk.accent, theme.rgbA(0x000000, 1), 0.1);
        const target_hover = if (b.s.on) accent_hover else lk.trough_hover;
        const track = theme.mix(lk.trough, lk.accent, t);
        // libadwaita's slider is white (light gray in dark mode when off).
        const knob_off = if (breeze) lk.knob else if (lk.dark) theme.rgbA(0xdedee0, 1) else theme.rgbA(0xffffff, 1);
        const knob = theme.mix(knob_off, theme.rgbA(0xffffff, 1), t);
        const knob_shadow = if (breeze) shadows(&.{.{ .color = lk.shadowColor(0.1), .offset = .{ .x = 0, .y = 1 }, .blur_radius = 2 }}) else shadows(&.{.{ .color = lk.shadowColor(0.2), .offset = .{ .x = 0, .y = 2 }, .blur_radius = 4 }});
        var knob_el = div().absolute().top(px((h - k) / 2)).left(px(pad + t * (w - 2 * pad - k)))
            .w(px(k)).h(px(k)).roundedFull().bg(knob).shadow(knob_shadow);
        if (breeze) knob_el = knob_el.border1().borderColor(theme.mix(lk.outline, lk.accent, t));
        var track_el = div().id("switch").relative().flexNone().w(px(w)).h(px(h)).roundedFull().bg(track)
            .role(.@"switch").ariaLabel(b.label()).ariaToggled(b.s.on).ariaDisabled(!b.s.enabled)
            .focusable().tabStop(b.s.enabled)
            .focusVisible(sb.shadow(focusRing(lk)));
        if (breeze) track_el = track_el.border1().borderColor(theme.mix(lk.outline, lk.accent, t));
        if (b.s.enabled) track_el = track_el.cursorPointer()
            .hover(sb.bg(target_hover))
            .active(sb.bg(if (b.s.on) press(lk.accent, lk) else press(lk.trough, lk)))
            .onClick(bind(ClickEvent, b.st, 0, onToggle));
        if (b.s.help.len > 0) track_el = track_el.ariaDescription(b.s.help);
        return element.intoAnyElement(track_el.child(knob_el));
    }

    fn checkbox(b: *Builder) AnyElement {
        const lk = b.look;
        const breeze = lk.family == .breeze;
        const size: Pixels = if (breeze) 18 else 20;
        const t = b.t;
        var box = div().relative().flexNone().w(px(size)).h(px(size)).rounded(px(if (breeze) 3 else 6))
            .flex().itemsCenter().justifyCenter();
        if (breeze) {
            box = box.bg(lk.check_bg).border1().borderColor(theme.mix(lk.check_border, lk.accent, t))
                .child(icon("zpui-check", icons.check, 14, lk.accent.alpha(t)));
        } else {
            box = box.bg(lk.accent.alpha(t)).border2().borderColor(lk.check_border.alpha(lk.check_border.a * (1 - t)))
                .child(div().absolute().inset0().flex().itemsCenter().justifyCenter()
                .child(icon("zpui-check", icons.check, 14, lk.accent_fg.alpha(t))));
        }
        var row = div().id("check").flex().itemsCenter().gap(px(if (breeze) 6 else 8)).rounded(px(6))
            .role(.check_box).ariaLabel(b.label()).ariaToggled(b.s.on).ariaDisabled(!b.s.enabled)
            .focusable().tabStop(b.s.enabled)
            .focusVisible(sb.shadow(focusRing(lk)))
            .child(box);
        if (b.s.enabled) row = row.cursorPointer().onClick(bind(ClickEvent, b.st, 0, onToggle))
            .hover(sb.textColor(lk.fg));
        if (b.s.title.len > 0) row = row.child(div().whitespaceNowrap().child(b.s.title));
        if (b.s.help.len > 0) row = row.ariaDescription(b.s.help);
        return element.intoAnyElement(row);
    }

    fn slider(b: *Builder) AnyElement {
        const lk = b.look;
        const breeze = lk.family == .breeze;
        const w: Pixels = b.width orelse 200;
        const h: Pixels = if (breeze) 24 else 26;
        const k: Pixels = 20;
        b.st.knob = k;
        const th: Pixels = if (breeze) 6 else 4;
        const f = fraction(b.s.value, b.s.min, b.s.max);
        const span = w - k;
        const knob_bg = if (breeze) lk.button_bg else theme.rgbA(0xffffff, 1);
        const knob_shadow = if (breeze)
            shadows(&.{.{ .color = lk.shadowColor(0.12), .offset = .{ .x = 0, .y = 1 }, .blur_radius = 2 }})
        else
            shadows(&.{
                .{ .color = lk.shadowColor(0.14), .offset = .{ .x = 0, .y = 0 }, .spread_radius = 1 },
                .{ .color = lk.shadowColor(0.2), .offset = .{ .x = 0, .y = 1 }, .blur_radius = 3 },
            });
        var knob = div().id("knob").absolute().top(px((h - k) / 2)).left(px(span * f)).w(px(k)).h(px(k))
            .roundedFull().bg(knob_bg).shadow(knob_shadow);
        if (breeze) knob = knob.border1().borderColor(if (b.st.dragging) lk.accent else lk.outline)
            .hover(sb.borderColor(lk.accent))
        else knob = knob.hover(sb.bg(theme.rgbA(0xf6f6f7, 1)));
        var root = div().id("slider").relative().flexNone().w(px(w)).h(px(h))
            .role(.slider).ariaLabel(b.label()).ariaDisabled(!b.s.enabled)
            .ariaNumericValue(b.s.value).ariaMinNumericValue(b.s.min).ariaMaxNumericValue(b.s.max)
            .ariaOrientation(.horizontal)
            .focusable().tabStop(b.s.enabled).rounded(px(h / 2))
            .focusVisible(sb.shadow(focusRing(lk)))
            .child(div().absolute().left(px(k / 2)).right(px(k / 2)).top(px((h - th) / 2)).h(px(th)).roundedFull().bg(lk.trough))
            .child(div().absolute().left(px(k / 2)).w(px(span * f)).top(px((h - th) / 2)).h(px(th)).roundedFull().bg(lk.accent))
            .child(knob);
        if (b.s.step > 0) root = root.ariaNumericValueStep(b.s.step);
        if (b.s.enabled) root = root
            .onMouseDown(.left, bind(input.MouseDownEvent, b.st, 0, onSliderDown))
            .onKeyDown(bind(input.KeyDownEvent, b.st, 0, onStepKey));
        if (b.s.help.len > 0) root = root.ariaDescription(b.s.help);
        return element.intoAnyElement(root);
    }

    fn segmented(b: *Builder) AnyElement {
        const lk = b.look;
        const breeze = lk.family == .breeze;
        const n: u32 = @intCast(b.s.items.len);
        var group = div().id("toggles").flex().flexRow().flexNone()
            .role(.group).ariaLabel(b.label())
            .focusable().tabStop(b.s.enabled)
            .focusVisible(sb.shadow(focusRing(lk)));
        if (b.width) |w| group = group.w(px(w));
        if (breeze) {
            group = group.h(px(lk.control_height)).rounded(px(lk.button_radius)).border1().borderColor(lk.outline)
                .bg(lk.button_bg).overflowHidden();
        } else {
            group = group.h(px(lk.control_height)).p(px(3)).gap(px(3)).rounded(px(lk.button_radius + 3)).bg(lk.toggle_group_bg);
        }
        if (b.s.enabled) group = group.onKeyDown(bind(input.KeyDownEvent, b.st, 0, onSegmentKey));
        const sel_shadow = if (lk.dark or breeze) shadows(&.{}) else shadows(&.{
            .{ .color = lk.shadowColor(0.08), .offset = .{ .x = 0, .y = 0 }, .spread_radius = 1 },
            .{ .color = lk.shadowColor(0.1), .offset = .{ .x = 0, .y = 1 }, .blur_radius = 3 },
        });
        for (b.s.items, 0..) |item, ix| {
            const i: u32 = @intCast(ix);
            const wgt = selectionWeight(b.t, i);
            const selected = b.s.selected == i;
            var seg = div().id(.{ "seg", ix }).flex().flex1().itemsCenter().justifyCenter().whitespaceNowrap()
                .role(.radio_button).ariaLabel(item).ariaToggled(selected).ariaPositionInSet(ix + 1).ariaSizeOfSet(n);
            if (breeze) {
                seg = seg.px(px(12)).bg(lk.toggle_checked.alpha(lk.toggle_checked.a * wgt));
                if (ix > 0) seg = seg.borderL1().borderColor(lk.outline);
                if (selected) seg = seg.textColor(lk.fg);
            } else {
                seg = seg.px(px(12)).rounded(px(lk.button_radius)).bg(lk.toggle_checked.alpha(lk.toggle_checked.a * wgt));
                if (wgt > 0.5) seg = seg.shadow(sel_shadow);
            }
            if (b.s.enabled and !selected) seg = seg.cursorPointer().hover(sb.bg(lk.item_hover))
                .onClick(bind(ClickEvent, b.st, i, onSegment));
            group = group.child(seg.child(item));
        }
        if (b.s.help.len > 0) group = group.ariaDescription(b.s.help);
        return element.intoAnyElement(group);
    }

    fn popup(b: *Builder) AnyElement {
        const lk = b.look;
        const breeze = lk.family == .breeze;
        const sel = b.s.selected;
        const current: []const u8 = if (sel) |i| (if (i < b.s.items.len) b.s.items[i] else "") else "";
        var button = div().id("dropdown").relative().flex().flexNone().itemsCenter().justifyBetween().gap(px(6))
            .h(px(lk.control_height)).pl(px(if (breeze) 8 else 10)).pr(px(if (breeze) 6 else 8)).rounded(px(lk.button_radius))
            .bg(lk.button_bg)
            .role(.combo_box).ariaLabel(b.label()).ariaValue(current).ariaExpanded(b.st.open).ariaDisabled(!b.s.enabled)
            .focusable().tabStop(b.s.enabled)
            .focusVisible(sb.shadow(focusRing(lk)))
            .child(div().whitespaceNowrap().overflowHidden().child(current))
            .child(icon("zpui-chevron-down", icons.chevron_down, 16, lk.fg));
        if (b.width) |w| button = button.w(px(w)) else button = button.minW(px(120));
        if (breeze) button = button.border1().borderColor(if (b.st.open) lk.accent else lk.outline);
        if (b.s.enabled) {
            button = button.cursorPointer()
                .onClick(bind(ClickEvent, b.st, 0, onPopupClick))
                .onKeyDown(bind(input.KeyDownEvent, b.st, 0, onPopupKey));
            button = if (breeze)
                button.hover(sb.borderColor(lk.accent)).active(sb.bg(lk.button_active))
            else
                button.hover(sb.bg(lk.button_hover)).active(sb.bg(lk.button_active));
        }
        if (b.s.help.len > 0) button = button.ariaDescription(b.s.help);
        if (b.st.open and b.s.enabled) button = button.child(b.popupList());
        return element.intoAnyElement(button);
    }

    fn popupList(b: *Builder) AnyElement {
        const lk = b.look;
        const breeze = lk.family == .breeze;
        const min_w = @max(b.st.bounds.size.width, 120);
        const card_shadow = if (breeze) shadows(&.{
            .{ .color = lk.shadowColor(0.2), .offset = .{ .x = 0, .y = 2 }, .blur_radius = 8 },
        }) else shadows(&.{
            .{ .color = lk.shadowColor(0.09), .offset = .{ .x = 0, .y = 1 }, .blur_radius = 5, .spread_radius = 1 },
            .{ .color = lk.shadowColor(0.05), .offset = .{ .x = 0, .y = 2 }, .blur_radius = 14, .spread_radius = 3 },
        });
        var list = div().id("dropdown-list").occlude().flex().flexCol().minW(px(min_w))
            .p(px(if (breeze) 3 else 6)).rounded(px(lk.popover_radius)).bg(lk.popover_bg).shadow(card_shadow)
            .fontFamily(b.font).textSize(px(lk.font_size)).textColor(lk.fg)
            .role(.list_box).ariaLabel(b.label())
            .onMouseDownOut(bind(input.MouseDownEvent, b.st, 0, onPopupOutside));
        if (breeze or lk.dark) list = list.border1().borderColor(lk.outline);
        for (b.s.items, 0..) |item, ix| {
            const i: u32 = @intCast(ix);
            const is_sel = b.s.selected == i;
            const hi = b.st.highlight == i;
            var row = div().id(.{ "opt", ix }).flex().itemsCenter().justifyBetween().gap(px(12))
                .h(px(if (breeze) 28 else 32)).px(px(if (breeze) 8 else 10)).rounded(px(if (breeze) 3 else 6))
                .whitespaceNowrap().cursorPointer()
                .role(.list_box_option).ariaSelected(is_sel)
                .onClick(bind(ClickEvent, b.st, i, onPopupPick))
                .onHover(bind(bool, b.st, i, onPopupHover))
                .child(item);
            if (hi) {
                row = if (breeze) row.bg(lk.item_hover).border1().borderColor(lk.accent) else row.bg(lk.item_hover);
            }
            if (!breeze) row = row.child(if (is_sel)
                element.intoAnyElement(icon("zpui-check", icons.check, 16, lk.fg))
            else
                element.intoAnyElement(div().w(px(16)).h(px(16))));
            list = list.child(row);
        }
        const h = lk.control_height;
        return element.intoAnyElement(div().absolute().top(px(h + 4)).left(px(0))
            .child(deferred_mod.deferred(anchored_mod.anchored()
            .snapToWindowWithMargin(.{ .top = 8, .right = 8, .bottom = 8, .left = 8 })
            .child(list)).withPriority(1)));
    }

    fn stepper(b: *Builder) AnyElement {
        const lk = b.look;
        const breeze = lk.family == .breeze;
        const h = lk.control_height;
        const text = switch (decimals(b.s.step)) {
            0 => arena_mod.fmt("{d:.0}", .{b.s.value}),
            1 => arena_mod.fmt("{d:.1}", .{b.s.value}),
            2 => arena_mod.fmt("{d:.2}", .{b.s.value}),
            else => arena_mod.fmt("{d:.3}", .{b.s.value}),
        };
        const can_dec = b.s.enabled and b.s.value > b.s.min;
        const can_inc = b.s.enabled and b.s.value < b.s.max;
        var root = div().id("spin").flex().flexNone().itemsCenter().h(px(h)).rounded(px(lk.button_radius)).overflowHidden()
            .role(.spin_button).ariaLabel(b.label()).ariaDisabled(!b.s.enabled)
            .ariaNumericValue(b.s.value).ariaMinNumericValue(b.s.min).ariaMaxNumericValue(b.s.max).ariaNumericValueStep(b.s.step)
            .focusable().tabStop(b.s.enabled)
            .focusVisible(sb.shadow(focusRing(lk)))
            .child(div().flex1().minW(px(0)).pl(px(if (breeze) 8 else 10)).pr(px(4)).whitespaceNowrap().child(text));
        if (b.width) |w| root = root.w(px(w)) else root = root.w(px(if (breeze) 96 else 132));
        if (b.s.enabled) root = root.onKeyDown(bind(input.KeyDownEvent, b.st, 0, onStepKey));
        if (b.s.help.len > 0) root = root.ariaDescription(b.s.help);
        if (breeze) {
            // QQC2 Breeze SpinBox: a line edit with stacked up / down arrows at the end.
            root = root.bg(lk.view_bg).border1().borderColor(lk.outline).hover(sb.borderColor(lk.accent));
            const half = (h - 2) / 2;
            var col = div().flex().flexCol().flexNone().w(px(18)).h(px(h - 2));
            inline for (.{ 1, 0 }) |up| {
                const enabled = if (up == 1) can_inc else can_dec;
                var btn = div().id(.{ "step", @as(u32, up) }).flex().itemsCenter().justifyCenter().w(px(18)).h(px(half))
                    .child(icon(if (up == 1) "zpui-chevron-up" else "zpui-chevron-down", if (up == 1) icons.chevron_up else icons.chevron_down, 12, lk.fg.alpha(if (enabled) lk.fg.a else lk.fg.a * 0.4)));
                if (enabled) btn = btn.cursorPointer().hover(sb.textColor(lk.accent)).onClick(bind(ClickEvent, b.st, @as(u32, up), onStepButton));
                col = col.child(btn);
            }
            return element.intoAnyElement(root.child(col));
        }
        // GtkSpinButton: an entry with flat − / + image buttons at the end.
        root = root.bg(lk.button_bg);
        inline for (.{ 0, 1 }) |up| {
            const enabled = if (up == 1) can_inc else can_dec;
            var btn = div().id(.{ "step", @as(u32, up) }).flex().flexNone().itemsCenter().justifyCenter().w(px(h)).h(px(h))
                .child(icon(if (up == 1) "zpui-plus" else "zpui-minus", if (up == 1) icons.plus else icons.minus, 16, lk.fg.alpha(if (enabled) lk.fg.a else lk.fg.a * 0.5)));
            if (enabled) btn = btn.cursorPointer().hover(sb.bg(lk.button_bg)).active(sb.bg(lk.button_active))
                .onClick(bind(ClickEvent, b.st, @as(u32, up), onStepButton));
            root = root.child(btn);
        }
        return element.intoAnyElement(root);
    }
};

test "tween: first value is instant, retarget eases from the current position" {
    const t = std.testing;
    const ms = std.time.ns_per_ms;
    var tw: Tween = .{};
    tw.retarget(0, 1000 * ms, false);
    try t.expect(!tw.running(1000 * ms));
    tw.retarget(1, 1000 * ms, false);
    try t.expect(tw.running(1000 * ms));
    const mid = tw.value(1090 * ms);
    try t.expect(mid > 0.5 and mid < 1); // cubic ease-out is past half at half time
    try t.expectEqual(@as(f32, 1), tw.value(1000 * ms + transition_ms * ms));
    try t.expect(!tw.running(1000 * ms + transition_ms * ms));
    // Reversal mid-flight starts from where the knob is.
    tw.retarget(0, 1090 * ms, false);
    try t.expectApproxEqAbs(mid, tw.value(1090 * ms), 1e-4);
    // Reduced motion snaps.
    tw.retarget(1, 1100 * ms, true);
    try t.expect(!tw.running(1100 * ms));
    try t.expectEqual(@as(f32, 1), tw.value(1100 * ms));
}

test "slider math: snap, fraction, position → value" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 5), snap(5.2, 0, 10, 1));
    try t.expectEqual(@as(f64, 10), snap(12, 0, 10, 0));
    try t.expectEqual(@as(f64, 560), snap(500, 560, 1200, 0));
    try t.expectEqual(@as(f64, 0.25), snap(0.3, 0, 1, 0.25));
    try t.expectEqual(@as(f32, 0.5), fraction(5, 0, 10));
    try t.expectEqual(@as(f32, 0), fraction(5, 3, 3));
    try t.expectEqual(@as(f64, 0), sliderValueAt(0, 10, 100, 0, 1, 0));
    try t.expectEqual(@as(f64, 1), sliderValueAt(500, 10, 100, 0, 1, 0));
    try t.expectEqual(@as(f64, 50), sliderValueAt(60, 10, 100, 0, 100, 10));
}

test "keyboard: actions per kind, stepping and moving selections" {
    const t = std.testing;
    try t.expectEqual(@as(?KeyAction, .inc), keyAction(.slider, "right"));
    try t.expectEqual(@as(?KeyAction, .dec), keyAction(.stepper, "down"));
    try t.expectEqual(@as(?KeyAction, .close), keyAction(.popup, "escape"));
    try t.expectEqual(@as(?KeyAction, .next), keyAction(.segmented, "right"));
    try t.expectEqual(@as(?KeyAction, null), keyAction(.switch_, "space"));
    try t.expectEqual(@as(?f64, 4), stepValue(.inc, 3, 0, 10, 1));
    try t.expectEqual(@as(?f64, null), stepValue(.inc, 10, 0, 10, 1)); // at max
    try t.expectEqual(@as(?f64, 0), stepValue(.home, 3, 0, 10, 1));
    try t.expectEqual(@as(?f64, 0.6), stepValue(.page_inc, 0.5, 0, 1, 0));
    try t.expectEqual(@as(?u32, 2), moveIndex(.next, 1, 3));
    try t.expectEqual(@as(?u32, null), moveIndex(.next, 2, 3));
    try t.expectEqual(@as(?u32, 0), moveIndex(.prev, 1, 3));
    try t.expectEqual(@as(?u32, 2), moveIndex(.end, null, 3));
    try t.expectEqual(@as(?u32, null), moveIndex(.next, null, 0));
    try t.expectEqual(@as(u8, 0), decimals(1));
    try t.expectEqual(@as(u8, 1), decimals(0.5));
    try t.expectEqual(@as(u8, 2), decimals(0.25));
    try t.expectEqual(@as(f32, 1), selectionWeight(2, 2));
    try t.expectEqual(@as(f32, 0.5), selectionWeight(1.5, 2));
    try t.expectEqual(@as(f32, 0), selectionWeight(0, 2));
}
