//! Element-level events built on top of platform input (gpui `interactive.rs`).

const std = @import("std");
const geometry = @import("../geometry.zig");
const input = @import("../input.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point(Pixels);
const Bounds = geometry.Bounds(Pixels);

pub const MouseClickEvent = struct {
    down: input.MouseDownEvent,
    up: input.MouseUpEvent,
};

pub const KeyboardButton = enum { enter, space };

pub const KeyboardClickEvent = struct {
    button: KeyboardButton = .enter,
    /// Bounds of the activated element.
    bounds: Bounds = .{ .origin = .zero, .size = .zero },
};

/// A click by mouse (down + up over the same element) or keyboard (enter/space on a focused
/// element) — gpui `ClickEvent`.
pub const ClickEvent = union(enum) {
    mouse: MouseClickEvent,
    keyboard: KeyboardClickEvent,

    pub fn modifiers(self: ClickEvent) input.Modifiers {
        return switch (self) {
            .mouse => |m| m.up.modifiers,
            .keyboard => .{},
        };
    }

    /// Mouse-up position, or the bottom-left of the element for keyboard clicks.
    pub fn position(self: ClickEvent) Point {
        return switch (self) {
            .mouse => |m| m.up.position,
            .keyboard => |k| .{ .x = k.bounds.origin.x, .y = k.bounds.bottom() },
        };
    }

    pub fn mousePosition(self: ClickEvent) ?Point {
        return switch (self) {
            .mouse => |m| m.up.position,
            .keyboard => null,
        };
    }

    pub fn isRightClick(self: ClickEvent) bool {
        return switch (self) {
            .mouse => |m| m.down.button == .right,
            .keyboard => false,
        };
    }

    /// 1 for single clicks, 2 for double clicks, ...; keyboard clicks count as 1.
    pub fn clickCount(self: ClickEvent) u32 {
        return switch (self) {
            .mouse => |m| m.up.click_count,
            .keyboard => 1,
        };
    }

    /// A plain left click without modifiers.
    pub fn isStandardClick(self: ClickEvent) bool {
        return switch (self) {
            .mouse => |m| m.down.button == .left and m.up.modifiers.none(),
            .keyboard => true,
        };
    }

    pub fn isKeyboard(self: ClickEvent) bool {
        return self == .keyboard;
    }
};

/// Delivered to `onDragMove(T, ...)` listeners while a drag of `T` moves (gpui `DragMoveEvent`).
pub fn DragMoveEvent(comptime T: type) type {
    return struct {
        event: input.MouseMoveEvent,
        /// Bounds of the element that registered the listener.
        bounds: Bounds,
        value: *const T,
    };
}

/// Drag threshold in logical pixels before a mouse down becomes a drag (gpui `DRAG_THRESHOLD`).
pub const drag_threshold: f32 = if (@import("builtin").os.tag == .windows) 4 else 2;
/// Default delay before a tooltip shows.
pub const tooltip_show_delay_ns: u64 = 500 * std.time.ns_per_ms;
/// Delay before a hoverable tooltip hides after the mouse leaves.
pub const hoverable_tooltip_hide_delay_ns: u64 = 500 * std.time.ns_per_ms;
