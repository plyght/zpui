//! Window-side bookkeeping for native form controls (`zpui.nativeSwitch`,
//! `nativeSlider`, ...; macOS AppKit controls hosted as native child views).
//!
//! Controls are native children owned by the window, keyed by the painting element's
//! global id (like Liquid Glass, liquid_glass.zig). Each frame the element calls
//! `paint`, which attaches the control on first use (re-attaching when its kind or tier
//! changed), pushes the state to the backend only when it differs from what the control
//! already shows, records the placement like `paintNativeView`, and stores the
//! element's change listener. A control not painted in a presented frame is hidden by
//! the normal native-view pass and detached after `keep_idle_presents` presents.
//!
//! User changes arrive through `WindowCallbacks.native_control` (`handleEvent`): the
//! entry's state takes the control's new value first (so the next frame does not push a
//! stale value back while the user is still dragging), then the listener runs inside an
//! app update. A listener that ignores the change leaves the app's value unchanged; the
//! next frame then differs from the control and pushes the app's value back.
//!
//! Tier: controls painted in the window's floating pass (deferred dialogs / popovers)
//! or on the top plane are `.above_overlay` children, so a dialog card drawn on the
//! overlay plane does not cover them; everything else is `.above_content`, under the
//! overlay plane where menus, popovers and dialogs cover it.

const std = @import("std");
const platform = @import("../platform/platform.zig");
const geometry = @import("../geometry.zig");
const window_mod = @import("window.zig");
const context = @import("../app/context.zig");
const Window = window_mod.Window;

const Bounds = geometry.Bounds(geometry.Pixels);
const Size = geometry.Size(geometry.Pixels);

pub const Listener = context.Listener(platform.NativeControlEvent);

pub const Tier = enum { base, floating };

pub const Entry = struct {
    key: u64,
    view: platform.NativeViewId,
    kind: platform.NativeControlKind,
    tier: Tier,
    /// What the control shows (last pushed, or last reported by the control). Strings
    /// live in `arena`.
    state: platform.NativeControlState,
    arena: std.heap.ArenaAllocator,
    listener: ?Listener = null,
    idle_presents: u32 = 0,
};

/// Presents a control may go unpainted before it is detached.
pub const keep_idle_presents: u32 = 120;

const Measured = struct { hash: u64, size: Size };

pub const Pool = struct {
    entries: std.ArrayList(*Entry) = .empty,
    /// Keys placed this frame (a repeated key is re-derived by occurrence).
    frame_keys: std.ArrayList(u64) = .empty,
    /// Backend sizes by state shape (`shapeHash`).
    measured: std.ArrayList(Measured) = .empty,
    /// Force the fallbacks (no native controls) in this window.
    disabled: bool = false,
    /// Total attaches (diagnostics / tests).
    attach_count: u32 = 0,
    /// User changes received from the backend (diagnostics / tests).
    event_count: u32 = 0,

    pub fn deinit(self: *Pool, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| freeEntry(gpa, e);
        self.entries.deinit(gpa);
        self.frame_keys.deinit(gpa);
        self.measured.deinit(gpa);
    }

    pub fn find(self: *const Pool, key: u64) ?usize {
        for (self.entries.items, 0..) |e, i| if (e.key == key) return i;
        return null;
    }

    pub fn findView(self: *const Pool, view: platform.NativeViewId) ?*Entry {
        for (self.entries.items) |e| if (e.view == view) return e;
        return null;
    }
};

fn freeEntry(gpa: std.mem.Allocator, e: *Entry) void {
    e.arena.deinit();
    gpa.destroy(e);
}

/// Hash of the state fields that change a control's size.
fn shapeHash(s: platform.NativeControlState) u64 {
    var h = std.hash.Wyhash.init(0x6e61_7469_7665);
    h.update(&.{ @intFromEnum(s.kind), @intFromEnum(s.size) });
    h.update(s.title);
    h.update(std.mem.asBytes(&s.items.len));
    for (s.items) |it| {
        h.update(it);
        h.update(&.{0});
    }
    if (s.kind == .slider) h.update(std.mem.asBytes(&s.step));
    return h.final();
}

/// The control's frame size, or null when this window shows no native control for
/// `state` (the element then lays out and paints its fallback).
pub fn measure(w: *Window, state: platform.NativeControlState) ?Size {
    const pool = &w.native_controls;
    if (pool.disabled or !w.platform_window.hasNativeControls()) return null;
    const h = shapeHash(state);
    for (pool.measured.items) |m| if (m.hash == h) return m.size;
    // Only sizes are cached: "no control" may change (a test turning controls on).
    const size = w.platform_window.measureNativeControl(state) orelse return null;
    if (pool.measured.items.len >= 64) pool.measured.clearRetainingCapacity();
    pool.measured.append(w.gpa, .{ .hash = h, .size = size }) catch {};
    return size;
}

pub fn stateEql(a: platform.NativeControlState, b: platform.NativeControlState) bool {
    if (a.kind != b.kind or a.enabled != b.enabled or a.size != b.size or !std.meta.eql(a.dark, b.dark) or
        a.on != b.on or a.value != b.value or a.min != b.min or a.max != b.max or a.step != b.step or
        !std.meta.eql(a.selected, b.selected)) return false;
    if (!std.mem.eql(u8, a.label, b.label) or !std.mem.eql(u8, a.title, b.title) or !std.mem.eql(u8, a.help, b.help)) return false;
    if (a.items.len != b.items.len) return false;
    for (a.items, b.items) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Store a deep copy of `state` in `e` (its strings in the entry's arena).
fn storeState(e: *Entry, state: platform.NativeControlState) void {
    _ = e.arena.reset(.retain_capacity);
    const a = e.arena.allocator();
    var copy = state;
    copy.label = a.dupe(u8, state.label) catch "";
    copy.title = a.dupe(u8, state.title) catch "";
    copy.help = a.dupe(u8, state.help) catch "";
    copy.items = blk: {
        const items = a.alloc([]const u8, state.items.len) catch break :blk &.{};
        for (state.items, items) |src, *dst| dst.* = a.dupe(u8, src) catch "";
        break :blk items;
    };
    e.state = copy;
}

/// Paint phase: place control `element_key` at `bounds` showing `state`; `listener`
/// receives user changes. Returns false when the control could not be attached (the
/// element then paints nothing).
pub fn paint(w: *Window, element_key: u64, state_in: platform.NativeControlState, bounds: Bounds, listener: ?Listener) bool {
    std.debug.assert(w.phase == .paint);
    var state = state_in;
    if (state.dark == null) state.dark = w.glass_dark;
    const pool = &w.native_controls;
    var key = element_key;
    var n: u64 = 0;
    while (std.mem.indexOfScalar(u64, pool.frame_keys.items, key) != null) {
        n += 1;
        key = std.hash.Wyhash.hash(n, std.mem.asBytes(&element_key));
    }
    pool.frame_keys.append(w.gpa, key) catch @panic("OOM");
    const tier: Tier = if (w.liquid_glass.floating_depth > 0 or w.top_depth > 0) .floating else .base;

    var entry: ?*Entry = null;
    if (pool.find(key)) |i| {
        const e = pool.entries.items[i];
        if (e.kind != state.kind or e.tier != tier) {
            detachAt(w, i);
        } else entry = e;
    }
    if (entry) |e| {
        if (!stateEql(e.state, state)) {
            storeState(e, state);
            w.platform_window.updateNativeControl(e.view, e.state);
        }
    } else {
        // The backend sees the entry's copy: its strings outlive this frame.
        const e = w.gpa.create(Entry) catch @panic("OOM");
        e.* = .{ .key = key, .view = undefined, .kind = state.kind, .tier = tier, .state = state, .arena = .init(w.gpa) };
        storeState(e, state);
        const z: platform.NativeViewZ = if (tier == .base) .above_content else .above_overlay;
        e.view = w.platform_window.attachNativeControl(e.state, z) catch |err| {
            std.log.scoped(.native_controls).warn("attach failed ({t})", .{err});
            freeEntry(w.gpa, e);
            return false;
        };
        pool.entries.append(w.gpa, e) catch @panic("OOM");
        pool.attach_count += 1;
        entry = e;
    }
    entry.?.listener = listener;
    w.paintNativeView(entry.?.view, bounds, 0);
    return true;
}

fn detachAt(w: *Window, i: usize) void {
    const e = w.native_controls.entries.orderedRemove(i);
    w.detachNativeView(e.view);
    freeEntry(w.gpa, e);
}

/// Present: age unpainted controls and detach what stayed unused too long.
pub fn sweep(w: *Window) void {
    const pool = &w.native_controls;
    pool.frame_keys.clearRetainingCapacity();
    if (pool.entries.items.len == 0) return;
    var i: usize = 0;
    while (i < pool.entries.items.len) {
        const e = pool.entries.items[i];
        const painted = w.rendered_frame.native_views.items; // detaching edits it
        const used = for (painted) |p| {
            if (p.id == e.view) break true;
        } else false;
        if (used) e.idle_presents = 0 else e.idle_presents += 1;
        if (e.idle_presents > keep_idle_presents) detachAt(w, i) else i += 1;
    }
}

/// A user change from the backend: record it, then run the element's listener.
pub fn handleEvent(w: *Window, view: platform.NativeViewId, event: platform.NativeControlEvent) void {
    const e = w.native_controls.findView(view) orelse return;
    if (e.kind != event.kind) return;
    w.native_controls.event_count +%= 1;
    switch (event.kind) {
        .switch_, .checkbox => e.state.on = event.on,
        .slider, .stepper => e.state.value = event.value,
        .segmented, .popup => e.state.selected = event.index,
    }
    const l = e.listener orelse return;
    const app = w.app;
    app.startUpdate();
    defer app.finishUpdate();
    l.callIn(&event, w, app);
}
