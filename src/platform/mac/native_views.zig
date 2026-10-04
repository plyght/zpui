//! macOS native child views + the overlay plane (zui fork `GPUIOverlayView`,
//! `enable_scene_overlay`, `draw_layered`; zeron `BrowserClipView`).
//!
//! Window content view subviews, back to front:
//!
//!     [ZPUIBlurredView]  [below_content children]  [ZPUIView (main CAMetalLayer)]
//!     [above_content children]  [ZPUIOverlayView (transparent CAMetalLayer)]
//!
//! * Each child (any `NSView*` the caller created; retained) lives in a
//!   `ZPUINativeClipView` that covers the whole content view and stays put. Its
//!   layer mask (a CALayer at the visible region, with the placement's corner radius)
//!   clips the child's pixels; its `hitTest:` clips hit testing to the same region
//!   (or never hits for `pass_through_mouse`), so zpui keeps input elsewhere.
//!   Keeping the host stationary and moving only the child mirrors zeron: moving the
//!   host while WebKit updates its remote layer tree can combine old origin and new size.
//! * The overlay plane is created on the first attach. `drawLayered` splits the
//!   scene: the overlay ranges go to the overlay layer, the rest to the main layer;
//!   the overlay view is hidden while it has nothing to show and only takes the mouse
//!   while it holds interactive content (`capture_input`), forwarding events to the
//!   ZPUIView. Both layers then present with the CA transaction, so native geometry
//!   (applied just before, by `place`) and both Metal planes land in the same frame.
//!
//! [liquid-glass] Native Liquid Glass (macOS 26 `NSGlassEffectView`) adds a second
//! tier, created on demand:
//!
//!     ... [ZPUIOverlayView]  [above_overlay children]  [ZPUIOverlayView (top plane)]
//!
//! * `attachGlass` creates the glass (or an `NSGlassEffectContainerView`) and hosts it
//!   like any child, except the host has no layer mask: it sits at the visible region
//!   and only clips (`masksToBounds`, rectangular) while the region is smaller than
//!   the bounds, so the glass's own edge effects and corners stay intact. Container
//!   members are not hosted: they are subviews of the container's content view,
//!   framed relative to the container's last placement.
//! * `drawLayered` splits the scene three ways (main / overlay / top ranges).

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const platform = @import("../platform.zig");
const scene_mod = @import("../../scene.zig");
const window_mod = @import("window.zig");

const MacWindow = window_mod.MacWindow;
const id = objc.id;
const SEL = objc.SEL;
const BOOL = objc.BOOL;
const YES = objc.YES;
const NO = objc.NO;
const NSRect = ak.NSRect;
const NSPoint = ak.NSPoint;

const log = std.log.scoped(.mac_native_views);

const child_ivar = "zpuiChild";
const state_ivar = "zpuiWindow";

var clip_class: ?*objc.Class = null;
var overlay_class: ?*objc.Class = null;

const Child = struct {
    id: platform.NativeViewId,
    view: id,
    /// The host clip view (for a container member: the member view itself, retained).
    clip: id,
    /// Layer mask of the host (null for glass hosts and members).
    mask: ?id,
    options: platform.NativeViewOptions,
    /// [liquid-glass] A glass / container view created by `attachGlass`.
    glass: ?platform.LiquidGlassKind = null,
    /// [liquid-glass] The container this glass is a member of.
    member_of: ?*Child = null,
    /// Visible region in content-view coordinates (bottom-left origin).
    region: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
    last: ?platform.NativeViewPlacement = null,
};

/// Per-window state, embedded in `MacWindow` (`natives`).
pub const Host = struct {
    children: std.ArrayList(*Child) = .empty,
    next_id: u32 = 1,
    overlay_view: ?id = null,
    /// The overlay holds interactive content and takes the mouse.
    overlay_capture: bool = false,
    base: scene_mod.Scene = .{},
    overlay: scene_mod.Scene = .{},
    /// [liquid-glass] The top plane (above `.above_overlay` children), created on demand.
    top_view: ?id = null,
    top_capture: bool = false,
    top: scene_mod.Scene = .{},

    pub fn enabled(self: *const Host) bool {
        return self.overlay_view != null;
    }

    pub fn deinit(self: *Host, w: *MacWindow) void {
        for (self.children.items) |c| destroyChild(w.gpa, c);
        self.children.deinit(w.gpa);
        if (self.overlay_view) |v| {
            objc.setIvar(v, state_ivar, null);
            v.msg(void, "removeFromSuperview", .{});
            v.release();
        }
        self.overlay_view = null;
        if (self.top_view) |v| {
            objc.setIvar(v, state_ivar, null);
            v.msg(void, "removeFromSuperview", .{});
            v.release();
        }
        self.top_view = null;
        self.base.deinit(w.gpa);
        self.overlay.deinit(w.gpa);
        self.top.deinit(w.gpa);
    }
};

fn registerClasses() void {
    if (clip_class != null) return;
    clip_class = blk: {
        const b = objc.ClassBuilder.init("NSView", "ZPUINativeClipView") orelse break :blk objc.getClass("ZPUINativeClipView").?;
        _ = b.addPointerIvar(child_ivar);
        _ = b.addMethod("hitTest:", &clipHitTest, "@@:" ++ ak.enc_point);
        _ = b.addMethod("isFlipped", &no, ak.enc_bool ++ "@:");
        break :blk b.register();
    };
    overlay_class = blk: {
        const b = objc.ClassBuilder.init("NSView", "ZPUIOverlayView") orelse break :blk objc.getClass("ZPUIOverlayView").?;
        _ = b.addPointerIvar(state_ivar);
        _ = b.addMethod("hitTest:", &overlayHitTest, "@@:" ++ ak.enc_point);
        _ = b.addMethod("acceptsFirstMouse:", &yes1, ak.enc_bool ++ "@:@");
        inline for (.{
            "mouseDown:",         "mouseUp:",           "rightMouseDown:", "rightMouseUp:",
            "otherMouseDown:",    "otherMouseUp:",      "mouseMoved:",     "mouseDragged:",
            "rightMouseDragged:", "otherMouseDragged:", "scrollWheel:",    "swipeWithEvent:",
            "magnifyWithEvent:",
        }) |s| _ = b.addMethod(s, &overlayEvent, "v@:@");
        break :blk b.register();
    };
}

fn no(_: id, _: SEL) callconv(.c) BOOL {
    return NO;
}
fn yes1(_: id, _: SEL, _: id) callconv(.c) BOOL {
    return YES;
}

fn clipHitTest(this: id, _: SEL, point: NSPoint) callconv(.c) ?id {
    const c: *Child = @ptrCast(@alignCast(objc.getIvar(this, child_ivar) orelse return null));
    if (c.options.pass_through_mouse) return null;
    const r = c.region;
    if (point.x < r.origin.x or point.x >= r.origin.x + r.size.width or
        point.y < r.origin.y or point.y >= r.origin.y + r.size.height) return null;
    var sup: objc.Super = .{ .receiver = this, .super_class = ak.class("NSView") };
    return objc.msgSendSuper(?id, &sup, objc.sel("hitTest:"), .{point});
}

fn overlayWindow(this: id) ?*MacWindow {
    return @ptrCast(@alignCast(objc.getIvar(this, state_ivar)));
}

fn overlayHitTest(this: id, _: SEL, _: NSPoint) callconv(.c) ?id {
    const w = overlayWindow(this) orelse return null;
    if (w.natives.top_view != null and w.natives.top_view.? == this) return if (w.natives.top_capture) this else null;
    return if (w.natives.overlay_capture) this else null;
}

/// Interactive overlay content is zpui's: route its events through the ZPUIView.
fn overlayEvent(this: id, s: SEL, event: id) callconv(.c) void {
    const w = overlayWindow(this) orelse return;
    window_mod.handleViewEvent(w.native_view, s, event);
}

fn contentView(w: *MacWindow) id {
    return w.native_window.msg(id, "contentView", .{});
}

/// zui `enable_scene_overlay`: the transparent plane above every native child.
fn enableOverlay(w: *MacWindow) !void {
    if (w.natives.overlay_view != null) return;
    registerClasses();
    const layer: id = @ptrCast(try w.renderer.createOverlayLayer());
    const parent = contentView(w);
    const view = overlay_class.?.msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{ak.bounds(parent)});
    objc.setIvar(view, state_ivar, w);
    layer.msg(void, "setContentsScale:", .{@as(ak.CGFloat, w.scaleFactor())});
    view.msg(void, "setLayer:", .{layer});
    view.msg(void, "setWantsLayer:", .{YES});
    view.msg(void, "setAutoresizingMask:", .{ak.NSViewWidthSizable | ak.NSViewHeightSizable});
    view.msg(void, "setHidden:", .{YES});
    parent.msg(void, "addSubview:", .{view});
    w.natives.overlay_view = view; // keep our +1 from alloc/init
    // Native geometry and both Metal planes must land in the same frame.
    w.renderer.setPresentsWithTransaction(true);
}

pub fn updateScale(w: *MacWindow) void {
    if (w.renderer.overlay_layer) |l| l.msg(void, "setContentsScale:", .{@as(ak.CGFloat, w.scaleFactor())});
    if (w.renderer.top_layer) |l| l.msg(void, "setContentsScale:", .{@as(ak.CGFloat, w.scaleFactor())}); // [liquid-glass]
}

pub fn attach(w: *MacWindow, native: *anyopaque, options: platform.NativeViewOptions) !platform.NativeViewId {
    return attachHosted(w, native, options, null);
}

fn attachHosted(w: *MacWindow, native: *anyopaque, options: platform.NativeViewOptions, glass: ?platform.LiquidGlassKind) !platform.NativeViewId {
    registerClasses();
    try enableOverlay(w);
    if (options.z == .above_overlay) try enableTop(w);
    const gpa = w.gpa;
    const view: id = @ptrCast(native);
    const parent = contentView(w);
    const c = try gpa.create(Child);
    errdefer gpa.destroy(c);
    try w.natives.children.ensureUnusedCapacity(gpa, 1);

    const zero: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    const clip = clip_class.?.msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{ak.bounds(parent)});
    clip.msg(void, "setWantsLayer:", .{YES});
    clip.msg(void, "setAutoresizesSubviews:", .{NO});
    // Glass hosts clip without a mask (backdrop effects inside masked layers render
    // offscreen); `place` toggles `masksToBounds` instead.
    const mask: ?id = if (glass != null) null else blk: {
        const m = ak.class("CALayer").msg(id, "new", .{});
        const black = ak.class("NSColor").msg(id, "blackColor", .{}).msg(*anyopaque, "CGColor", .{});
        m.msg(void, "setBackgroundColor:", .{black});
        m.msg(void, "setFrame:", .{zero});
        break :blk m;
    };
    if (clip.msg(?id, "layer", .{})) |l| {
        l.msg(void, "setMasksToBounds:", .{objc.toBOOL(mask != null)});
        if (mask) |m| l.msg(void, "setMask:", .{m});
    }
    clip.msg(void, "setHidden:", .{YES});

    const ident: platform.NativeViewId = @enumFromInt(w.natives.next_id);
    w.natives.next_id += 1;
    c.* = .{ .id = ident, .view = view.retain(), .clip = clip, .mask = mask, .options = options, .glass = glass };
    objc.setIvar(clip, child_ivar, c);

    switch (options.z) {
        .above_content => parent.msg(void, "addSubview:positioned:relativeTo:", .{ clip, ak.NSWindowBelow, w.natives.overlay_view.? }),
        .below_content => parent.msg(void, "addSubview:positioned:relativeTo:", .{ clip, ak.NSWindowBelow, w.native_view }),
        .above_overlay => parent.msg(void, "addSubview:positioned:relativeTo:", .{ clip, ak.NSWindowBelow, w.natives.top_view.? }),
    }
    clip.msg(void, "addSubview:", .{view});
    w.natives.children.appendAssumeCapacity(c);
    return ident;
}

fn find(w: *MacWindow, ident: platform.NativeViewId) ?usize {
    for (w.natives.children.items, 0..) |c, i| if (c.id == ident) return i;
    return null;
}

fn destroyChild(gpa: std.mem.Allocator, c: *Child) void {
    if (c.member_of == null) objc.setIvar(c.clip, child_ivar, null);
    c.view.msg(void, "removeFromSuperview", .{});
    c.clip.msg(void, "removeFromSuperview", .{});
    c.view.release();
    c.clip.release();
    if (c.mask) |m| m.release();
    gpa.destroy(c);
}

pub fn detach(w: *MacWindow, ident: platform.NativeViewId) void {
    const i = find(w, ident) orelse return;
    const c = w.natives.children.items[i];
    // [liquid-glass] A container takes its members along.
    if (c.glass == .container) {
        var j: usize = 0;
        while (j < w.natives.children.items.len) {
            const m = w.natives.children.items[j];
            if (m.member_of == c) destroyChild(w.gpa, w.natives.children.orderedRemove(j)) else j += 1;
        }
    }
    _ = w.natives.children.orderedRemove(find(w, ident).?);
    if (isFirstResponderWithin(w, c.view)) _ = w.native_window.msg(BOOL, "makeFirstResponder:", .{w.native_view});
    destroyChild(w.gpa, c);
}

fn isFirstResponderWithin(w: *MacWindow, view: id) bool {
    const r = w.native_window.msg(?id, "firstResponder", .{}) orelse return false;
    if (!objc.isKindOf(r, ak.class("NSView"))) return false;
    return r.msg(BOOL, "isDescendantOf:", .{view}) == YES;
}

pub fn focus(w: *MacWindow, ident: ?platform.NativeViewId) void {
    const target = if (ident) |i| (if (find(w, i)) |ix| w.natives.children.items[ix].view else return) else w.native_view;
    _ = w.native_window.msg(BOOL, "makeFirstResponder:", .{target});
}

fn flipped(parent_height: f64, b: platform.Bounds) NSRect {
    const h: f64 = @max(b.size.height, 0);
    return .{
        .origin = .{ .x = b.origin.x, .y = parent_height - @as(f64, b.origin.y) - h },
        .size = .{ .width = @max(b.size.width, 0), .height = h },
    };
}

pub fn place(w: *MacWindow, ident: platform.NativeViewId, placement: ?platform.NativeViewPlacement) void {
    const i = find(w, ident) orelse return;
    const c = w.natives.children.items[i];
    const p = placement orelse {
        if (c.last != null) {
            if (isFirstResponderWithin(w, c.view)) _ = w.native_window.msg(BOOL, "makeFirstResponder:", .{w.native_view});
            c.clip.msg(void, "setHidden:", .{YES});
            c.last = null;
        }
        return;
    };
    if (c.last) |l| if (std.meta.eql(l, p)) return;
    c.last = p;
    if (c.glass != null) return placeGlass(w, c, p);

    const CAT = ak.class("CATransaction");
    const prev_disabled = CAT.msg(BOOL, "disableActions", .{});
    CAT.msg(void, "setDisableActions:", .{YES});
    // Leave the implicit transaction open for the matching Metal presentation.
    defer CAT.msg(void, "setDisableActions:", .{prev_disabled});

    const parent = contentView(w);
    const pb = ak.bounds(parent);
    c.clip.msg(void, "setFrame:", .{pb});
    c.region = flipped(pb.size.height, p.clip);
    c.mask.?.msg(void, "setFrame:", .{c.region});
    c.mask.?.msg(void, "setCornerRadius:", .{@as(ak.CGFloat, p.corner_radius)});
    c.view.msg(void, "setFrame:", .{flipped(pb.size.height, p.bounds)});
    const visible = p.clip.size.width > 0 and p.clip.size.height > 0;
    c.clip.msg(void, "setHidden:", .{objc.toBOOL(!visible)});
    if (!visible and isFirstResponderWithin(w, c.view)) _ = w.native_window.msg(BOOL, "makeFirstResponder:", .{w.native_view});
}

/// zui `draw_layered` ([liquid-glass]: plus the top plane).
pub fn drawLayered(w: *MacWindow, scene: *const scene_mod.Scene, overlay_ranges: []const platform.OverlayRange, capture_input: bool) !void {
    const size = w.drawableSizePub();
    const scale = w.scaleFactor();
    const host = &w.natives;
    const overlay_view = host.overlay_view orelse return w.renderer.drawScene(scene, size, scale, .{});
    const gpa = w.gpa;
    host.base.clear(gpa);
    host.overlay.clear(gpa);
    host.top.clear(gpa);
    var at: usize = 0;
    const n = scene.len();
    for (overlay_ranges) |r| {
        const start = @min(r.start, n);
        const end = @min(r.end, n);
        if (start > at) try host.base.replay(gpa, at, start, scene);
        if (end > start) {
            const dst = if (r.plane == .top) &host.top else &host.overlay;
            try dst.replay(gpa, start, end, scene);
        }
        at = @max(at, end);
    }
    if (n > at) try host.base.replay(gpa, at, n, scene);
    host.base.finish();
    host.overlay.finish();
    host.top.finish();
    if (!host.top.isEmpty()) try enableTop(w);

    const visible = !host.overlay.isEmpty();
    const top_visible = !host.top.isEmpty();
    // Input goes to the topmost plane holding content (both forward to the ZPUIView).
    const active = capture_input and (visible or top_visible);
    const focus_chrome = active and !(host.overlay_capture or host.top_capture);
    host.top_capture = capture_input and top_visible;
    host.overlay_capture = capture_input and visible;

    try w.renderer.drawScene(&host.base, size, scale, .{});
    if (visible) try w.renderer.drawOverlay(&host.overlay, size, scale);
    overlay_view.msg(void, "setHidden:", .{objc.toBOOL(!visible)});
    if (host.top_view) |tv| {
        if (top_visible) try w.renderer.drawTop(&host.top, size, scale);
        tv.msg(void, "setHidden:", .{objc.toBOOL(!top_visible)});
    }
    ak.class("CATransaction").msg(void, "flush", .{});
    // A menu opening over a focused web view takes the keyboard back to zpui.
    if (focus_chrome) _ = w.native_window.msg(BOOL, "makeFirstResponder:", .{w.native_view});
}

// ---------------------------------------------------------------------------------------
// [liquid-glass] NSGlassEffectView / NSGlassEffectContainerView (macOS 26+)
// ---------------------------------------------------------------------------------------

var glass_support: ?bool = null;

/// macOS 26+ with `NSGlassEffectView` in AppKit (cached).
pub fn glassSupported() bool {
    if (glass_support) |s| return s;
    const s = ak.osAtLeast(26, 0, 0) and objc.getClass("NSGlassEffectView") != null and
        objc.getClass("NSGlassEffectContainerView") != null;
    glass_support = s;
    return s;
}

/// The top plane: a second transparent overlay view above `.above_overlay` children.
fn enableTop(w: *MacWindow) !void {
    if (w.natives.top_view != null) return;
    try enableOverlay(w);
    const layer: id = @ptrCast(try w.renderer.createTopLayer());
    const parent = contentView(w);
    const view = overlay_class.?.msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{ak.bounds(parent)});
    objc.setIvar(view, state_ivar, w);
    layer.msg(void, "setContentsScale:", .{@as(ak.CGFloat, w.scaleFactor())});
    view.msg(void, "setLayer:", .{layer});
    view.msg(void, "setWantsLayer:", .{YES});
    view.msg(void, "setAutoresizingMask:", .{ak.NSViewWidthSizable | ak.NSViewHeightSizable});
    view.msg(void, "setHidden:", .{YES});
    parent.msg(void, "addSubview:positioned:relativeTo:", .{ view, ak.NSWindowAbove, w.natives.overlay_view.? });
    w.natives.top_view = view;
}

pub fn attachGlass(w: *MacWindow, options: platform.LiquidGlassAttach) !platform.NativeViewId {
    if (!glassSupported()) return error.LiquidGlassUnsupported;
    const cls_name: [:0]const u8 = switch (options.kind) {
        .glass => "NSGlassEffectView",
        .container => "NSGlassEffectContainerView",
    };
    const cls = objc.getClass(cls_name) orelse return error.LiquidGlassUnsupported;
    const zero: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    const view = cls.msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{zero});
    defer view.release(); // the host (or member record) keeps its own reference
    view.msg(void, "setAutoresizingMask:", .{@as(ak.NSUInteger, 0)});
    if (options.kind == .container) {
        // Members go into the container's content view (a plain, non-flipped NSView).
        const content = ak.class("NSView").msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{zero});
        content.msg(void, "setAutoresizingMask:", .{ak.NSViewWidthSizable | ak.NSViewHeightSizable});
        view.msg(void, "setContentView:", .{content});
        content.release();
    }
    const parent_ident = options.parent orelse
        return attachHosted(w, @ptrCast(view), .{ .z = options.z, .pass_through_mouse = true }, options.kind);

    // A member of a container: no host; framed relative to the container.
    const pi = find(w, parent_ident) orelse return error.UnknownLiquidGlassContainer;
    const container = w.natives.children.items[pi];
    if (container.glass != .container) return error.NotALiquidGlassContainer;
    const content = container.view.msg(?id, "contentView", .{}) orelse return error.NotALiquidGlassContainer;
    const gpa = w.gpa;
    const c = try gpa.create(Child);
    errdefer gpa.destroy(c);
    try w.natives.children.ensureUnusedCapacity(gpa, 1);
    const ident: platform.NativeViewId = @enumFromInt(w.natives.next_id);
    w.natives.next_id += 1;
    c.* = .{
        .id = ident,
        .view = view.retain(),
        .clip = view.retain(),
        .mask = null,
        .options = .{ .z = container.options.z, .pass_through_mouse = true },
        .glass = options.kind,
        .member_of = container,
    };
    view.msg(void, "setHidden:", .{YES});
    content.msg(void, "addSubview:", .{view});
    w.natives.children.appendAssumeCapacity(c);
    return ident;
}

fn placeGlass(w: *MacWindow, c: *Child, p: platform.NativeViewPlacement) void {
    const CAT = ak.class("CATransaction");
    const prev_disabled = CAT.msg(BOOL, "disableActions", .{});
    CAT.msg(void, "setDisableActions:", .{YES});
    defer CAT.msg(void, "setDisableActions:", .{prev_disabled});

    if (c.member_of) |container| {
        frameMember(c, container);
    } else {
        const pb = ak.bounds(contentView(w));
        const full = flipped(pb.size.height, p.bounds);
        c.region = flipped(pb.size.height, p.clip);
        const clipped = !std.meta.eql(p.clip, p.bounds);
        // The host sits at the visible region; it clips only while scrolled/masked.
        const host = if (clipped) c.region else full;
        c.clip.msg(void, "setFrame:", .{host});
        if (c.clip.msg(?id, "layer", .{})) |l| l.msg(void, "setMasksToBounds:", .{objc.toBOOL(clipped)});
        c.view.msg(void, "setFrame:", .{NSRect{
            .origin = .{ .x = full.origin.x - host.origin.x, .y = full.origin.y - host.origin.y },
            .size = full.size,
        }});
        const visible = p.clip.size.width > 0 and p.clip.size.height > 0;
        c.clip.msg(void, "setHidden:", .{objc.toBOOL(!visible)});
    }
    // A container moved: re-frame its members against the new origin.
    if (c.glass == .container) for (w.natives.children.items) |m| {
        if (m.member_of == c and m.last != null) frameMember(m, c);
    };
}

/// Frame member `m` inside `container`'s content view (bottom-left origin).
fn frameMember(m: *Child, container: *Child) void {
    const p = m.last orelse return;
    const cp = container.last orelse {
        m.view.msg(void, "setHidden:", .{YES});
        return;
    };
    const h: f64 = @max(p.bounds.size.height, 0);
    m.view.msg(void, "setFrame:", .{NSRect{
        .origin = .{
            .x = @as(f64, p.bounds.origin.x) - @as(f64, cp.bounds.origin.x),
            .y = @as(f64, cp.bounds.size.height) - (@as(f64, p.bounds.origin.y) - @as(f64, cp.bounds.origin.y)) - h,
        },
        .size = .{ .width = @max(p.bounds.size.width, 0), .height = h },
    }});
    const visible = p.clip.size.width > 0 and p.clip.size.height > 0;
    m.view.msg(void, "setHidden:", .{objc.toBOOL(!visible)});
}

fn responds(obj: id, comptime selector: [:0]const u8) bool {
    return obj.msg(BOOL, "respondsToSelector:", .{objc.cachedSel(selector)}) == YES;
}

pub fn configureGlass(w: *MacWindow, ident: platform.NativeViewId, cfg: platform.LiquidGlassConfig) void {
    const i = find(w, ident) orelse return;
    const c = w.natives.children.items[i];
    const v = c.view;
    switch (c.glass orelse return) {
        .glass => {
            if (responds(v, "setStyle:")) v.msg(void, "setStyle:", .{@as(objc.NSInteger, @intFromEnum(cfg.style))});
            if (responds(v, "setCornerRadius:")) v.msg(void, "setCornerRadius:", .{@as(ak.CGFloat, cfg.corner_radius)});
            if (responds(v, "setTintColor:")) {
                const tint: ?id = if (cfg.tint) |t| ak.class("NSColor").msg(id, "colorWithSRGBRed:green:blue:alpha:", .{
                    @as(ak.CGFloat, t[0]), @as(ak.CGFloat, t[1]), @as(ak.CGFloat, t[2]), @as(ak.CGFloat, t[3]),
                }) else null;
                v.msg(void, "setTintColor:", .{tint});
            }
            // AppKit added `effectIsInteractive` after 26.0 (documented for macOS 27).
            if (responds(v, "setEffectIsInteractive:")) v.msg(void, "setEffectIsInteractive:", .{objc.toBOOL(cfg.interactive)});
        },
        .container => {
            if (responds(v, "setSpacing:")) v.msg(void, "setSpacing:", .{@as(ak.CGFloat, cfg.spacing)});
        },
    }
}
