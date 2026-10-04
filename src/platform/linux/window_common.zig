//! State and logic shared by the Wayland and X11 windows: callback dispatch, the
//! KeyDown → InputHandler text fallback, IME bridging, click counting and scroll
//! delta conversion (ports of gpui_linux `handle_input`/`handle_ime` and the
//! `wl_pointer` axis / X11 button-scroll handling).

const std = @import("std");
const platform = @import("../platform.zig");
const input = @import("../../input.zig");

const Point = platform.Point;
const Size = platform.Size;

/// gpui_linux constants (platform.rs).
pub const scroll_lines: f32 = 3.0;
pub const double_click_interval_ns: u64 = 400 * std.time.ns_per_ms;
pub const double_click_distance: f32 = 5.0;

pub const ImeInput = union(enum) {
    insert_text: []const u8,
    set_marked_text: []const u8,
    unmark_text,
    delete_text,
};

pub const Common = struct {
    callbacks: platform.WindowCallbacks = .{},
    input_handler: ?platform.InputHandler = null,
    active: bool = false,
    hovered: bool = false,
    mouse_position: Point = .zero,
    modifiers: input.Modifiers = .{},
    /// Logical content size and scale factor as last reported to the core.
    size: Size = .zero,
    scale: f32 = 1,
    background: platform.WindowBackgroundAppearance = .opaque_,
    fullscreen: bool = false,
    maximized: bool = false,
    closed: bool = false,
    /// The AT-SPI bridge exposing this window (set by `atspi.Bridge.addWindow`), told
    /// about activation changes (Window Activate / Deactivate events).
    atspi_bridge: ?*@import("atspi.zig").Bridge = null,

    /// Delivers an event to the core; unhandled printable key presses become text input.
    pub fn handleInput(w: *Common, event: input.PlatformInput) void {
        if (w.callbacks.input) |f| {
            const result = f(w.callbacks.ctx, event);
            if (!result.propagate) return;
        }
        switch (event) {
            .key_down => |kd| {
                const m = kd.keystroke.modifiers;
                const only_shift = !m.control and !m.alt and !m.platform and !m.function;
                if (only_shift) if (kd.keystroke.key_char) |ch| if (w.input_handler) |h| {
                    h.vtable.replaceTextInRange(h.ptr, null, ch);
                };
            },
            else => {},
        }
    }

    pub fn handleIme(w: *Common, ime: ImeInput) void {
        const h = w.input_handler orelse return;
        switch (ime) {
            .insert_text => |t| h.vtable.replaceTextInRange(h.ptr, null, t),
            .set_marked_text => |t| h.vtable.replaceAndMarkTextInRange(h.ptr, null, t, null),
            .unmark_text => h.vtable.unmarkText(h.ptr),
            .delete_text => if (h.vtable.markedTextRange(h.ptr)) |r| h.vtable.replaceTextInRange(h.ptr, r, ""),
        }
    }

    /// Bounds of the current selection, for placing the IME candidate window.
    pub fn imeArea(w: *Common) ?platform.Bounds {
        const h = w.input_handler orelse return null;
        const sel = h.vtable.selectedTextRange(h.ptr) orelse return null;
        return h.vtable.boundsForRange(h.ptr, sel.range);
    }

    pub fn requestFrame(w: *Common, force: bool) void {
        if (w.callbacks.request_frame) |f| f(w.callbacks.ctx, force);
    }

    pub fn setActive(w: *Common, active: bool) void {
        const changed = w.active != active;
        w.active = active;
        if (w.callbacks.active_status_change) |f| f(w.callbacks.ctx, active);
        if (changed) if (w.atspi_bridge) |b| b.windowActivated(w, active);
    }

    pub fn setHovered(w: *Common, hovered: bool) void {
        w.hovered = hovered;
        if (w.callbacks.hover_status_change) |f| f(w.callbacks.ctx, hovered);
    }

    /// Records the new size/scale; returns true (and notifies the core) when it changed.
    pub fn setSizeAndScale(w: *Common, size: Size, scale: f32) bool {
        if (size.width == w.size.width and size.height == w.size.height and scale == w.scale) return false;
        w.size = size;
        w.scale = scale;
        if (w.callbacks.resize) |f| f(w.callbacks.ctx, size, scale);
        return true;
    }

    pub fn moved(w: *Common) void {
        if (w.callbacks.moved) |f| f(w.callbacks.ctx);
    }

    pub fn shouldClose(w: *Common) bool {
        const f = w.callbacks.should_close orelse return true;
        return f(w.callbacks.ctx);
    }

    pub fn notifyClosed(w: *Common) void {
        if (w.closed) return;
        w.closed = true;
        if (w.callbacks.close) |f| f(w.callbacks.ctx);
    }

    pub fn appearanceChanged(w: *Common) void {
        if (w.callbacks.appearance_changed) |f| f(w.callbacks.ctx);
    }

    /// Physical (device pixel) size for the current logical size and scale.
    pub fn deviceSize(w: *const Common) struct { width: u32, height: u32 } {
        return .{
            .width = @intFromFloat(@max(1, @round(w.size.width * w.scale))),
            .height = @intFromFloat(@max(1, @round(w.size.height * w.scale))),
        };
    }
};

/// Multi-click detection (gpui: same button within 400ms and 5px).
pub const ClickState = struct {
    button: ?input.MouseButton = null,
    time_ns: u64 = 0,
    position: Point = .zero,
    count: u32 = 0,

    pub fn press(s: *ClickState, button: input.MouseButton, position: Point, now_ns: u64) u32 {
        const near = @abs(position.x - s.position.x) <= double_click_distance and
            @abs(position.y - s.position.y) <= double_click_distance;
        const fast = now_ns -| s.time_ns < double_click_interval_ns;
        s.count = if (s.button == button and near and fast) s.count + 1 else 1;
        s.button = button;
        s.time_ns = now_ns;
        s.position = position;
        return s.count;
    }
};

pub const Axis = enum { vertical, horizontal };

/// Accumulates `wl_pointer` axis events until `wl_pointer.frame` (gpui wayland client).
///
/// Continuous sources (touchpads) produce `ScrollDelta.pixels` (value × 3, inverted);
/// wheels produce `ScrollDelta.lines` from `axis_value120` (or legacy `axis_discrete`).
/// Shift turns vertical scrolling into horizontal.
pub const WaylandScroll = struct {
    pub const Source = enum { wheel, finger, continuous, wheel_tilt };

    source: Source = .wheel,
    continuous: ?Point = null,
    discrete: ?Point = null,
    received: bool = false,
    /// gpui's `vertical_modifier`/`horizontal_modifier` (natural scrolling is -1).
    modifier: f32 = -1.0,

    fn target(axis: Axis, shift: bool) Axis {
        return if (shift) .horizontal else axis;
    }

    fn add(p: *Point, axis: Axis, v: f32) void {
        switch (axis) {
            .vertical => p.y += v,
            .horizontal => p.x += v,
        }
    }

    /// `wl_pointer.axis` (value in surface-local px). Ignored for wheel sources.
    pub fn axisValue(s: *WaylandScroll, axis: Axis, value: f32, shift: bool) void {
        if (s.source == .wheel) return;
        s.received = true;
        if (s.continuous == null) s.continuous = .zero;
        add(&s.continuous.?, target(axis, shift), value * 3.0 * s.modifier);
    }

    /// `wl_pointer.axis_discrete` (wl_seat < v8).
    pub fn axisDiscrete(s: *WaylandScroll, axis: Axis, steps: i32, shift: bool) void {
        s.received = true;
        if (s.discrete == null) s.discrete = .zero;
        add(&s.discrete.?, target(axis, shift), @as(f32, @floatFromInt(steps)) * s.modifier * scroll_lines);
    }

    /// `wl_pointer.axis_value120` (one wheel notch = 120).
    pub fn axisValue120(s: *WaylandScroll, axis: Axis, value120: i32, shift: bool) void {
        s.received = true;
        if (s.discrete == null) s.discrete = .zero;
        add(&s.discrete.?, target(axis, shift), @as(f32, @floatFromInt(value120)) / 120.0 * s.modifier * scroll_lines);
    }

    /// `wl_pointer.frame`: the accumulated delta, continuous taking precedence.
    pub fn frame(s: *WaylandScroll) ?input.ScrollDelta {
        if (!s.received) return null;
        s.received = false;
        const cont = s.continuous;
        const disc = s.discrete;
        s.continuous = null;
        s.discrete = null;
        if (cont) |p| return .{ .pixels = p };
        if (disc) |p| return .{ .lines = p };
        return null;
    }
};

/// X11 core scroll buttons 4-7 → line delta (gpui x11 client). Null for other buttons.
pub fn x11ButtonScroll(button: u8, shift: bool) ?Point {
    const d: Point = switch (button) {
        4 => .{ .x = 0, .y = scroll_lines },
        5 => .{ .x = 0, .y = -scroll_lines },
        6 => .{ .x = scroll_lines, .y = 0 },
        7 => .{ .x = -scroll_lines, .y = 0 },
        else => return null,
    };
    return applyShift(d, shift);
}

/// Shift turns vertical scrolling into horizontal (gpui `make_scroll_wheel_event`).
pub fn applyShift(d: Point, shift: bool) Point {
    return if (shift) .{ .x = d.y, .y = 0 } else d;
}

/// XInput2 smooth-scroll valuator axis (gpui `ScrollAxisState`).
pub const XiScrollAxis = struct {
    valuator: ?u16 = null,
    /// `scroll_lines / increment`.
    multiplier: f32 = 1,
    last: ?f64 = null,

    /// Feeds an absolute valuator value; returns the line delta since the previous one.
    pub fn update(a: *XiScrollAxis, value: f64) ?f32 {
        defer a.last = value;
        const old = a.last orelse return null;
        return @floatCast((old - value) * a.multiplier);
    }
};

/// Linux evdev button codes → gpui buttons.
pub fn evdevButton(code: u32) ?input.MouseButton {
    return switch (code) {
        0x110 => .left,
        0x111 => .right,
        0x112 => .middle,
        0x116, 0x113 => .back,
        0x115, 0x114 => .forward,
        else => null,
    };
}

/// X11 core button numbers → gpui buttons (8/9 are back/forward).
pub fn x11Button(detail: u8) ?input.MouseButton {
    return switch (detail) {
        1 => .left,
        2 => .middle,
        3 => .right,
        8 => .back,
        9 => .forward,
        else => null,
    };
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "WaylandScroll: wheel value120 -> lines, finger -> pixels, shift -> horizontal" {
    var s: WaylandScroll = .{};
    // A wheel notch down: axis (ignored for wheels) + value120 then frame.
    s.axisValue(.vertical, 15, false);
    s.axisValue120(.vertical, 120, false);
    const d = s.frame().?;
    try testing.expectEqual(input.ScrollDelta{ .lines = .{ .x = 0, .y = -3 } }, d);
    try testing.expect(s.frame() == null);

    // Half notch from a high-resolution wheel.
    s.axisValue120(.vertical, -60, false);
    try testing.expectEqual(input.ScrollDelta{ .lines = .{ .x = 0, .y = 1.5 } }, s.frame().?);

    // Touchpad: continuous px, scaled by 3 and inverted; shift redirects to x.
    s.source = .finger;
    s.axisValue(.vertical, 2, false);
    s.axisValue(.vertical, 1, true);
    try testing.expectEqual(input.ScrollDelta{ .pixels = .{ .x = -3, .y = -6 } }, s.frame().?);

    // Legacy discrete.
    s.source = .wheel;
    s.axisDiscrete(.horizontal, 1, false);
    try testing.expectEqual(input.ScrollDelta{ .lines = .{ .x = -3, .y = 0 } }, s.frame().?);
}

test "x11 scroll buttons and XI2 valuators" {
    try testing.expectEqual(Point{ .x = 0, .y = 3 }, x11ButtonScroll(4, false).?);
    try testing.expectEqual(Point{ .x = -3, .y = 0 }, x11ButtonScroll(5, true).?);
    try testing.expect(x11ButtonScroll(1, false) == null);

    var a: XiScrollAxis = .{ .valuator = 3, .multiplier = scroll_lines / 120.0 };
    try testing.expect(a.update(1000) == null);
    try testing.expectApproxEqAbs(@as(f32, -3), a.update(1120).?, 1e-5);
}

test "ClickState counts multi-clicks" {
    var c: ClickState = .{};
    const ms = std.time.ns_per_ms;
    try testing.expectEqual(@as(u32, 1), c.press(.left, .{ .x = 10, .y = 10 }, 1000 * ms));
    try testing.expectEqual(@as(u32, 2), c.press(.left, .{ .x = 12, .y = 9 }, 1200 * ms));
    try testing.expectEqual(@as(u32, 3), c.press(.left, .{ .x = 12, .y = 9 }, 1500 * ms));
    try testing.expectEqual(@as(u32, 1), c.press(.left, .{ .x = 12, .y = 9 }, 2000 * ms)); // too slow
    try testing.expectEqual(@as(u32, 1), c.press(.right, .{ .x = 12, .y = 9 }, 2100 * ms)); // other button
    try testing.expectEqual(@as(u32, 1), c.press(.right, .{ .x = 30, .y = 9 }, 2200 * ms)); // too far
}

test "Common.handleInput falls back to text insertion" {
    const H = struct {
        inserted: std.ArrayList(u8) = .empty,
        const SelRet = @typeInfo(@typeInfo(@FieldType(platform.InputHandler.VTable, "selectedTextRange")).pointer.child).@"fn".return_type.?;
        fn sel(_: *anyopaque) SelRet {
            return null;
        }
        fn marked(_: *anyopaque) ?platform.InputHandler.Range {
            return null;
        }
        fn text(_: *anyopaque, _: platform.InputHandler.Range, _: *std.ArrayList(u8), _: std.mem.Allocator) ?platform.InputHandler.Range {
            return null;
        }
        fn replace(ptr: *anyopaque, _: ?platform.InputHandler.Range, t: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.inserted.appendSlice(testing.allocator, t) catch unreachable;
        }
        fn mark(_: *anyopaque, _: ?platform.InputHandler.Range, _: []const u8, _: ?platform.InputHandler.Range) void {}
        fn unmark(_: *anyopaque) void {}
        fn bounds(_: *anyopaque, _: platform.InputHandler.Range) ?platform.Bounds {
            return null;
        }
        const vt: platform.InputHandler.VTable = .{
            .selectedTextRange = sel,
            .markedTextRange = marked,
            .textForRange = text,
            .replaceTextInRange = replace,
            .replaceAndMarkTextInRange = mark,
            .unmarkText = unmark,
            .boundsForRange = bounds,
        };
    };
    var h: H = .{};
    defer h.inserted.deinit(testing.allocator);
    var w: Common = .{ .input_handler = .{ .ptr = &h, .vtable = &H.vt } };
    w.handleInput(.{ .key_down = .{ .keystroke = .{ .key = "a", .key_char = "A", .modifiers = .{ .shift = true } } } });
    w.handleInput(.{ .key_down = .{ .keystroke = .{ .key = "c", .key_char = "c", .modifiers = .{ .control = true } } } });
    w.handleIme(.{ .insert_text = "é" });
    try testing.expectEqualStrings("Aé", h.inserted.items);
}
