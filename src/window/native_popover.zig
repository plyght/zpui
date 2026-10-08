//! Native popover containers: rich floating content (pickers, cards, rich tooltips)
//! rendered by zpui in its own popover-style platform window (macOS: a borderless,
//! non-activating `NSPanel` with the system popover / menu / tooltip material or
//! Liquid Glass, the system shadow and show / hide animation). The content is an
//! ordinary zpui view drawn with Metal in that window, so it can extend past the
//! parent window. Backends without popover windows (Linux, tests by default) keep the
//! in-window popover: the element renders its fallback.
//!
//! ```zig
//! // In the trigger (a `relative` div), while the popover is open:
//! trigger.child(zpui.nativePopover(
//!     .trigger("model-picker"),
//!     .{ .edge = .above, .focus = self.search_focus },
//!     zpui.popoverContent(cx.entity(), Picker.renderCard, Picker.dismiss),
//! ).fallback(ui.popover.anchoredAbove(card)));
//! ```
//!
//! `build_content(self: *V, window, cx: *Context(V))` renders the card in the popover
//! window (`window.isNativePopover()` is true there, so the content can drop its own
//! background, border and shadow: the material provides them). `on_dismiss(self,
//! window, cx)` runs for an outside press (in the parent outside the anchor, in another
//! window or app) and for an unhandled Escape; it should close the popover (stop
//! rendering the element). Notifying `V` redraws the popover window.
//!
//! Lifecycle (per parent window, `Pool`): the element records a `Request` in paint (the
//! frame's `popover_requests`, carried over by cached views). After each parent draw
//! `afterDraw` matches requests to entries: a new key opens a hidden popover window from
//! a main-thread task, draws it once to measure the content (max-content layout) and then
//! places and shows it (`place`: anchor edge + alignment, flipped and clamped against the
//! screen's visible area). A key no longer requested hides at once (system animation)
//! and its window closes `close_linger_ns` later unless it is requested again. Content
//! size changes re-place the window (resize to fit).
//!
//! Plain tooltips go the same way when `Window.native_tooltips` is set: the frame's
//! tooltip view is shown in a non-key, mouse-transparent popover (`tooltip_options`)
//! instead of on the overlay plane.

const std = @import("std");
const platform = @import("../platform/platform.zig");
const geometry = @import("../geometry.zig");
const input = @import("../input.zig");
const window_mod = @import("window.zig");
const view_mod = @import("view.zig");
const element = @import("element.zig");
const focus_mod = @import("focus.zig");
const App = @import("../app/app.zig").App;
const Context = @import("../app/context.zig").Context;
const entity_mod = @import("../app/entity.zig");

const Window = window_mod.Window;
const WindowId = window_mod.WindowId;
const AnyView = view_mod.AnyView;
const EntityId = entity_mod.EntityId;
const Pixels = geometry.Pixels;
const Point = geometry.Point(Pixels);
const Size = geometry.Size(Pixels);
const Bounds = geometry.Bounds(Pixels);

const log = std.log.scoped(.native_popover);

/// The side of the anchor the popover opens on (before flipping).
pub const Edge = enum {
    below,
    above,
    right,
    left,

    pub fn opposite(e: Edge) Edge {
        return switch (e) {
            .below => .above,
            .above => .below,
            .right => .left,
            .left => .right,
        };
    }
};

/// Cross-axis alignment against the anchor: `start` = left / top edges flush.
pub const Align = enum { start, center, end };

pub const Options = struct {
    edge: Edge = .below,
    alignment: Align = .start,
    /// Distance from the anchor (logical px).
    gap: f32 = 6,
    /// Kept clear at the screen edges.
    margin: f32 = 8,
    /// Open on the opposite edge when the preferred one has less room.
    flip: bool = true,
    material: platform.PopoverMaterial = .popover,
    corner_radius: f32 = 12,
    liquid_glass: bool = true,
    /// Appearance pinned to the theme; null = the parent window's `glass_dark`.
    dark: ?bool = null,
    /// Takes keyboard focus when shown (`focus` is then focused inside).
    key: bool = true,
    mouse_transparent: bool = false,
    focus: ?focus_mod.FocusHandle = null,
    /// A press in the parent outside the anchor dismisses (the anchor itself is left to
    /// the trigger, which usually toggles).
    dismiss_on_outside_click: bool = true,
    /// false: always use the fallback (the app's "native" setting is off).
    native: bool = true,
};

/// `Options` for native plain-text tooltips (cursor-anchored, below-right, non-key).
pub const tooltip_options: Options = .{
    .edge = .below,
    .alignment = .start,
    .gap = 18,
    .margin = 4,
    .material = .tooltip,
    .corner_radius = 6,
    .key = false,
    .mouse_transparent = true,
    .dismiss_on_outside_click = false,
};

/// Seconds a hidden popover window is kept before it closes (reopening within this
/// reuses it without a new window).
pub const close_linger_ns: u64 = 250 * std.time.ns_per_ms;

/// The owner callback for dismissal (see the file docs).
pub const Dismiss = struct {
    owner: EntityId,
    call: *const fn (owner: EntityId, window: *Window, app: *App) void,
};

/// What a popover shows: a view-like render of the owner entity, plus its dismiss hook.
pub const Content = struct {
    view: AnyView,
    dismiss: ?Dismiss = null,

    fn sameView(a: Content, b: Content) bool {
        return a.view.entity.id == b.view.entity.id and a.view.render == b.view.render;
    }
};

/// `zpui.popoverContent(owner, build_content, on_dismiss)`: `owner` is an `Entity(V)`,
/// `build_content: fn (*V, *Window, *Context(V)) R` (any element), `on_dismiss: fn (*V,
/// *Window, *Context(V)) void` or `null`.
pub fn content(owner: anytype, comptime build: anytype, comptime on_dismiss: anytype) Content {
    const V = @TypeOf(owner).Type;
    const has_dismiss = @TypeOf(on_dismiss) != @TypeOf(null);
    const R = struct {
        fn render(id: EntityId, w: *Window, a: *App) element.AnyElement {
            if (!a.entities.isAlive(id)) return element.empty();
            const e: entity_mod.Entity(V) = .{ .id = id };
            return e.update(a, call, .{w});
        }
        fn call(v: *V, w: *Window, cx: *Context(V)) element.AnyElement {
            return element.intoAnyElement(build(v, w, cx));
        }
        fn dismiss(id: EntityId, w: *Window, a: *App) void {
            if (!a.entities.isAlive(id)) return;
            const e: entity_mod.Entity(V) = .{ .id = id };
            e.update(a, on_dismiss, .{w});
        }
    };
    return .{
        .view = .{ .entity = owner.toAny(), .render = R.render },
        .dismiss = if (comptime has_dismiss) .{ .owner = owner.id, .call = R.dismiss } else null,
    };
}

/// One frame's popover (the parent's `Frame.popover_requests`).
pub const Request = struct {
    key: u64,
    /// Parent content coordinates.
    anchor: Bounds,
    options: Options,
    content: Content,
    tooltip: bool = false,
};

/// Marks a window as a native popover (`Window.popover_role`).
pub const Role = struct {
    parent: WindowId,
    key: u64,
    /// Max-content size of the root measured by the last draw.
    measured: ?Size = null,
};

pub const Entry = struct {
    key: u64,
    window: ?WindowId = null,
    anchor: Bounds,
    options: Options,
    content: Content,
    tooltip: bool,
    seen: bool = true,
    measured: ?Size = null,
    /// Last frame / visibility handed to the platform.
    frame: ?Bounds = null,
    placed_visible: bool = false,
    edge: Edge = .below,
    closing: bool = false,
    close_gen: u32 = 0,
    /// Opening failed: never retried for this key while it stays requested.
    failed: bool = false,
};

/// A parent window's popovers (`Window.native_popovers`).
pub const Pool = struct {
    entries: std.ArrayList(*Entry) = .empty,
    sync_scheduled: bool = false,
    /// Force the fallbacks in this window.
    disabled: bool = false,
    /// Popover windows opened so far (diagnostics / tests).
    opened_count: u32 = 0,
    /// Dismissals delivered to owners (diagnostics / tests).
    dismiss_count: u32 = 0,

    pub fn find(self: *const Pool, key: u64) ?*Entry {
        for (self.entries.items) |e| if (e.key == key) return e;
        return null;
    }

    fn indexOf(self: *const Pool, key: u64) ?usize {
        for (self.entries.items, 0..) |e, i| if (e.key == key) return i;
        return null;
    }

    /// The open (not closing) entry's popover window, if any.
    pub fn windowFor(self: *const Pool, key: u64) ?WindowId {
        const e = self.find(key) orelse return null;
        if (e.closing) return null;
        return e.window;
    }
};

// ---------------------------------------------------------------------------------------
// Placement
// ---------------------------------------------------------------------------------------

pub const Placement = struct { frame: Bounds, edge: Edge };

fn space(anchor: Bounds, screen: Bounds, edge: Edge, margin: f32) f32 {
    return switch (edge) {
        .below => screen.bottom() - anchor.bottom() - margin,
        .above => anchor.origin.y - screen.origin.y - margin,
        .right => screen.right() - anchor.right() - margin,
        .left => anchor.origin.x - screen.origin.x - margin,
    };
}

fn clampAxis(v: f32, lo: f32, hi: f32) f32 {
    if (hi < lo) return lo;
    return std.math.clamp(v, lo, hi);
}

/// Where a popover of `size` goes next to `anchor` inside `screen` (all in one
/// coordinate space): on `o.edge` (flipped to the opposite edge when that has more
/// room and the preferred one cannot fit), aligned on the cross axis, then shrunk and
/// shifted to stay `o.margin` inside the screen. Rounded to whole pixels.
pub fn place(anchor: Bounds, size: Size, screen: Bounds, o: Options) Placement {
    var edge = o.edge;
    const vertical = edge == .below or edge == .above;
    const need = (if (vertical) size.height else size.width) + o.gap;
    if (o.flip) {
        const here = space(anchor, screen, edge, o.margin);
        const there = space(anchor, screen, edge.opposite(), o.margin);
        if (here < need and there > here) edge = edge.opposite();
    }
    const w = @max(0, @min(size.width, screen.size.width - 2 * o.margin));
    const h = @max(0, @min(size.height, screen.size.height - 2 * o.margin));
    var x: f32 = 0;
    var y: f32 = 0;
    switch (edge) {
        .below => y = anchor.bottom() + o.gap,
        .above => y = anchor.origin.y - o.gap - h,
        .right => x = anchor.right() + o.gap,
        .left => x = anchor.origin.x - o.gap - w,
    }
    if (vertical) {
        x = switch (o.alignment) {
            .start => anchor.origin.x,
            .center => anchor.origin.x + (anchor.size.width - w) / 2,
            .end => anchor.right() - w,
        };
    } else {
        y = switch (o.alignment) {
            .start => anchor.origin.y,
            .center => anchor.origin.y + (anchor.size.height - h) / 2,
            .end => anchor.bottom() - h,
        };
    }
    x = clampAxis(x, screen.origin.x + o.margin, screen.right() - o.margin - w);
    y = clampAxis(y, screen.origin.y + o.margin, screen.bottom() - o.margin - h);
    return .{
        .frame = .{ .origin = .{ .x = @round(x), .y = @round(y) }, .size = .{ .width = @round(w), .height = @round(h) } },
        .edge = edge,
    };
}

/// The screen area popovers of `w` flip against (its content coordinates).
fn screenFor(w: *const Window) Bounds {
    if (!w.platform_closed) if (w.platform_window.screenBoundsInContent()) |b| return b;
    return .{ .origin = .zero, .size = w.viewport_size };
}

// ---------------------------------------------------------------------------------------
// Element side (parent window)
// ---------------------------------------------------------------------------------------

/// Whether `w` shows native popovers (else elements render their fallbacks).
pub fn available(w: *const Window) bool {
    return !w.native_popovers.disabled and w.popover_role == null and !w.platform_closed and !w.removed and
        w.app.platform.supportsNativePopovers();
}

/// Paint phase: show `req` this frame.
pub fn request(w: *Window, req: Request) void {
    var r = req;
    r.content.view.cached_style = null; // arena pointer; the popover lays out its own root
    w.next_frame.popover_requests.append(w.gpa, r) catch @panic("OOM");
}

/// The key native tooltips use (one per window).
pub const tooltip_key: u64 = 0x6e70_6f70_746f_6f6c;

/// `prepaintTooltip` for `Window.native_tooltips`: route the frame's tooltip view to a
/// native popover. Never paints in-window.
pub fn prepaintTooltip(w: *Window) void {
    const reqs = w.next_frame.tooltip_requests.items;
    var i = reqs.len;
    while (i > 0) {
        i -= 1;
        const req = reqs[i] orelse continue;
        const anchor: Bounds = .{ .origin = req.mouse_position, .size = .zero };
        const c: Content = .{ .view = req.view };
        var size: Size = .zero;
        if (w.native_popovers.find(tooltip_key)) |e| if (e.content.sameView(c)) {
            size = e.measured orelse .zero;
        };
        const b = place(anchor, size, screenFor(w), w.native_tooltip_options).frame;
        if (req.check_visible) |check| if (!check(req.owner.?, b, w)) continue;
        w.next_frame.popover_requests.append(w.gpa, .{
            .key = tooltip_key,
            .anchor = anchor,
            .options = w.native_tooltip_options,
            .content = .{ .view = .{ .entity = req.view.entity, .render = req.view.render } },
            .tooltip = true,
        }) catch @panic("OOM");
        w.tooltip_bounds = .{ .id = req.id, .bounds = b };
        return;
    }
}

/// End of every draw: a popover window reports its measured size; a parent matches its
/// requests to popover windows.
pub fn afterDraw(w: *Window) void {
    if (w.popover_role) |role| afterPopoverDraw(w, role);
    syncParent(w);
}

fn syncParent(w: *Window) void {
    const pool = &w.native_popovers;
    const reqs = w.rendered_frame.popover_requests.items;
    if (reqs.len == 0 and pool.entries.items.len == 0) return;
    const app = w.app;
    for (pool.entries.items) |e| e.seen = false;
    var need_open = false;
    for (reqs) |r| {
        if (pool.find(r.key)) |e| {
            if (e.seen) continue; // a duplicate key in one frame: first wins
            const view_changed = !e.content.sameView(r.content);
            const anchor_changed = !std.meta.eql(e.anchor, r.anchor);
            const reopened = e.closing;
            e.anchor = r.anchor;
            e.options = r.options;
            e.content = r.content;
            e.tooltip = r.tooltip;
            e.seen = true;
            if (reopened) {
                e.closing = false;
                e.close_gen +%= 1;
            }
            if (e.window) |id| {
                if (app.windowById(id)) |pw| {
                    if (view_changed) {
                        if (e.tooltip) e.measured = null;
                        pw.refresh();
                    }
                    if (reopened) if (e.options.focus) |f| pw.focus(f);
                    if (anchor_changed or reopened) reposition(w, e);
                } else {
                    e.window = null;
                    need_open = need_open or !e.failed;
                }
            } else need_open = need_open or !e.failed;
        } else {
            const e = w.gpa.create(Entry) catch @panic("OOM");
            e.* = .{ .key = r.key, .anchor = r.anchor, .options = r.options, .content = r.content, .tooltip = r.tooltip, .edge = r.options.edge };
            pool.entries.append(w.gpa, e) catch @panic("OOM");
            need_open = true;
        }
    }
    var i: usize = 0;
    while (i < pool.entries.items.len) {
        const e = pool.entries.items[i];
        if (!e.seen and !e.closing) {
            if (e.window == null) {
                _ = pool.entries.orderedRemove(i);
                w.gpa.destroy(e);
                continue;
            }
            beginClose(w, e);
        }
        i += 1;
    }
    if (need_open) scheduleSync(w);
}

/// Re-place `e`'s window for its anchor and measured size.
fn reposition(parent: *Window, e: *Entry) void {
    const id = e.window orelse return;
    const pw = parent.app.windowById(id) orelse return;
    const size = e.measured orelse return;
    const p = place(e.anchor, size, screenFor(parent), e.options);
    e.edge = p.edge;
    const visible = e.seen and !e.closing;
    if (e.frame != null and std.meta.eql(e.frame.?, p.frame) and e.placed_visible == visible) return;
    e.frame = p.frame;
    e.placed_visible = visible;
    if (!pw.platform_closed) pw.platform_window.placePopover(p.frame, visible);
}

fn afterPopoverDraw(pw: *Window, role: Role) void {
    const parent = pw.app.windowById(role.parent) orelse return;
    const e = parent.native_popovers.find(role.key) orelse return;
    if (e.window == null or e.window.? != pw.id) return;
    const m = role.measured orelse return;
    if (e.measured != null and std.meta.eql(e.measured.?, m) and e.placed_visible == (e.seen and !e.closing)) return;
    e.measured = m;
    reposition(parent, e);
}

fn beginClose(parent: *Window, e: *Entry) void {
    e.closing = true;
    e.close_gen +%= 1;
    const app = parent.app;
    if (e.window) |id| if (app.windowById(id)) |pw| if (e.placed_visible) {
        e.placed_visible = false;
        if (!pw.platform_closed) pw.platform_window.placePopover(e.frame orelse .{ .origin = .zero, .size = pw.viewport_size }, false);
    };
    var task = app.foregroundExecutor().timer(close_linger_ns, CloseTask{ .app = app, .parent = parent.id, .key = e.key, .gen = e.close_gen }) catch return;
    task.detach();
}

const CloseTask = struct {
    app: *App,
    parent: WindowId,
    key: u64,
    gen: u32,

    pub fn finish(self: *CloseTask) void {
        const parent = self.app.windowById(self.parent) orelse return;
        const pool = &parent.native_popovers;
        const i = pool.indexOf(self.key) orelse return;
        const e = pool.entries.items[i];
        if (!e.closing or e.close_gen != self.gen) return;
        _ = pool.entries.orderedRemove(i);
        self.app.startUpdate();
        defer self.app.finishUpdate();
        if (e.window) |id| if (self.app.windowById(id)) |pw| pw.removeWindow();
        parent.gpa.destroy(e);
    }
};

fn scheduleSync(w: *Window) void {
    if (w.native_popovers.sync_scheduled) return;
    var task = w.app.foregroundExecutor().spawn(SyncTask{ .app = w.app, .parent = w.id }) catch return;
    w.native_popovers.sync_scheduled = true;
    task.detach();
}

const SyncTask = struct {
    app: *App,
    parent: WindowId,

    pub fn finish(self: *SyncTask) void {
        const parent = self.app.windowById(self.parent) orelse return;
        parent.native_popovers.sync_scheduled = false;
        if (!available(parent)) return;
        // Entries may be appended while windows open (nested frames): index loop.
        var i: usize = 0;
        while (i < parent.native_popovers.entries.items.len) : (i += 1) {
            const e = parent.native_popovers.entries.items[i];
            if (e.window != null or e.closing or e.failed or !e.seen) continue;
            open(parent, e);
        }
    }
};

const PopoverRoot = struct {
    parent: WindowId,
    key: u64,

    fn init(parent: WindowId, key: u64, _: *Window, _: *Context(PopoverRoot)) PopoverRoot {
        return .{ .parent = parent, .key = key };
    }

    pub fn render(self: *PopoverRoot, _: *Window, cx: *Context(PopoverRoot)) element.AnyElement {
        const parent = cx.app.windowById(self.parent) orelse return element.empty();
        const e = parent.native_popovers.find(self.key) orelse return element.empty();
        if (!cx.app.entities.isAlive(e.content.view.entity.id)) return element.empty();
        return e.content.view.intoAnyElement();
    }
};

fn open(parent: *Window, e: *Entry) void {
    const app = parent.app;
    app.startUpdate();
    defer app.finishUpdate();
    const estimate = e.measured orelse Size{ .width = 240, .height = 160 };
    const p = place(e.anchor, estimate, screenFor(parent), e.options);
    const o = e.options;
    const params: platform.WindowParams = .{
        .bounds = p.frame,
        .titlebar = null,
        .kind = .popup,
        .focus = false,
        .show = false,
        .is_movable = false,
        .background = .transparent,
        .popover = .{
            .parent = parent.platform_window,
            .material = o.material,
            .corner_radius = o.corner_radius,
            .liquid_glass = o.liquid_glass,
            .dark = o.dark orelse parent.glass_dark,
            .key = o.key,
            .mouse_transparent = o.mouse_transparent,
        },
    };
    const handle = app.openWindow(params, PopoverRoot, PopoverRoot.init, .{ parent.id, e.key }) catch |err| {
        log.warn("could not open a popover window ({t}); key {x} stays closed", .{ err, e.key });
        e.failed = true;
        return;
    };
    const pw = app.windowById(handle.id) orelse return;
    pw.popover_role = .{ .parent = parent.id, .key = e.key };
    pw.glass_dark = o.dark orelse parent.glass_dark;
    pw.background_appearance = .transparent;
    pw.prefers_reduced_motion = parent.prefers_reduced_motion;
    pw.rem_size = parent.rem_size;
    e.window = handle.id;
    e.frame = p.frame;
    e.placed_visible = false;
    parent.native_popovers.opened_count += 1;
    if (o.focus) |f| pw.focus(f);
    // Measure now (the hidden window gets no vsync frames): the draw reports the content
    // size, which places and shows the window.
    pw.drawAndPresent();
}

// ---------------------------------------------------------------------------------------
// Dismissal
// ---------------------------------------------------------------------------------------

fn dismiss(parent: *Window, e: *Entry, reason: platform.PopoverDismissReason) void {
    _ = reason;
    if (e.closing or !e.seen) return;
    const d = e.content.dismiss orelse return;
    const app = parent.app;
    parent.native_popovers.dismiss_count += 1;
    app.startUpdate();
    defer app.finishUpdate();
    d.call(d.owner, parent, app);
}

/// Parent input, before dispatch: a press outside every anchor dismisses those popovers.
pub fn parentInput(w: *Window, event: input.PlatformInput) void {
    if (w.native_popovers.entries.items.len == 0) return;
    const pos = switch (event) {
        .mouse_down => |m| m.position,
        else => return,
    };
    var keys: [16]u64 = undefined;
    var n: usize = 0;
    for (w.native_popovers.entries.items) |e| {
        if (e.tooltip or e.closing or !e.options.dismiss_on_outside_click) continue;
        if (e.anchor.contains(pos)) continue;
        if (n < keys.len) {
            keys[n] = e.key;
            n += 1;
        }
    }
    for (keys[0..n]) |k| if (w.native_popovers.find(k)) |e| dismiss(w, e, .outside_click);
}

/// Popover window input, after dispatch: an Escape nothing handled dismisses.
pub fn popoverInput(pw: *Window, event: input.PlatformInput, result: platform.DispatchEventResult) void {
    if (pw.popover_role == null) return;
    const k = switch (event) {
        .key_down => |k| k,
        else => return,
    };
    if (!result.propagate or result.default_prevented) return;
    if (!std.mem.eql(u8, k.keystroke.key, "escape")) return;
    popoverDismiss(pw, .escape);
}

/// The platform (or `popoverInput`) asks popover window `pw` to close.
pub fn popoverDismiss(pw: *Window, reason: platform.PopoverDismissReason) void {
    const role = pw.popover_role orelse return;
    const parent = pw.app.windowById(role.parent) orelse return;
    const e = parent.native_popovers.find(role.key) orelse return;
    if (e.window == null or e.window.? != pw.id) return;
    // A press on the trigger: leave it to the trigger's own toggle.
    if (reason == .outside_click and !parent.platform_closed and e.anchor.contains(parent.platform_window.mousePosition())) return;
    dismiss(parent, e, reason);
}

/// Window teardown: a parent closes its popover windows.
pub fn deinitWindow(w: *Window) void {
    const app = w.app;
    const any = w.native_popovers.entries.items.len > 0;
    if (any) app.startUpdate();
    defer if (any) app.finishUpdate();
    for (w.native_popovers.entries.items) |e| {
        if (e.window) |id| if (app.windowById(id)) |pw| pw.removeWindow();
        w.gpa.destroy(e);
    }
    w.native_popovers.entries.deinit(w.gpa);
}

// ---------------------------------------------------------------------------------------
// Tests (placement; window behaviour is in window/tests.zig)
// ---------------------------------------------------------------------------------------

const testing = std.testing;

fn bnds(x: f32, y: f32, w: f32, h: f32) Bounds {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

test "place: below-start, gap, then flip above when the screen bottom is near" {
    const screen = bnds(0, 0, 1000, 800);
    const anchor = bnds(100, 100, 80, 20);
    const p = place(anchor, .{ .width = 200, .height = 300 }, screen, .{});
    try testing.expectEqual(Edge.below, p.edge);
    try testing.expectEqual(bnds(100, 126, 200, 300), p.frame);
    const low = bnds(100, 700, 80, 20);
    const q = place(low, .{ .width = 200, .height = 300 }, screen, .{});
    try testing.expectEqual(Edge.above, q.edge);
    try testing.expectEqual(bnds(100, 394, 200, 300), q.frame);
    // No flip when disabled: clamped inside the screen instead.
    const r = place(low, .{ .width = 200, .height = 300 }, screen, .{ .flip = false });
    try testing.expectEqual(Edge.below, r.edge);
    try testing.expectEqual(@as(f32, 800 - 8 - 300), r.frame.origin.y);
}

test "place: alignment, horizontal edges and clamping" {
    const screen = bnds(0, 0, 1000, 800);
    const anchor = bnds(900, 300, 60, 40);
    const end = place(anchor, .{ .width = 200, .height = 100 }, screen, .{ .alignment = .end });
    try testing.expectEqual(bnds(760, 346, 200, 100), end.frame);
    const center = place(bnds(400, 300, 60, 40), .{ .width = 200, .height = 100 }, screen, .{ .edge = .above, .alignment = .center });
    try testing.expectEqual(bnds(330, 194, 200, 100), center.frame);
    // Right edge flips left near the screen's right side.
    const right = place(anchor, .{ .width = 200, .height = 100 }, screen, .{ .edge = .right });
    try testing.expectEqual(Edge.left, right.edge);
    try testing.expectEqual(bnds(694, 300, 200, 100), right.frame);
    // Start alignment past the right edge is shifted back inside the margin.
    const shifted = place(anchor, .{ .width = 200, .height = 100 }, screen, .{});
    try testing.expectEqual(@as(f32, 1000 - 8 - 200), shifted.frame.origin.x);
    // Bigger than the screen: shrunk to fit inside the margins.
    const huge = place(bnds(10, 10, 10, 10), .{ .width = 5000, .height = 5000 }, screen, .{});
    try testing.expectEqual(bnds(8, 8, 984, 784), huge.frame);
}

test "place: screen offset (parent content coordinates may be negative)" {
    const screen = bnds(-200, -100, 1440, 900);
    const p = place(bnds(-150, -60, 20, 20), .{ .width = 100, .height = 50 }, screen, .{ .edge = .above });
    try testing.expectEqual(Edge.below, p.edge);
    try testing.expectEqual(bnds(-150, -34, 100, 50), p.frame);
}
