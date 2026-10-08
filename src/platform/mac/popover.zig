//! macOS native popover containers (`platform.PopoverParams`, zpui `nativePopover`).
//!
//! Why a panel and not `NSPopover`: zpui content is drawn by a `MacWindow` (its own
//! CAMetalLayer view, display link, input, IME and native child views), and a borderless
//! non-activating `NSPanel` *is* such a window, so every popover gets the whole pipeline
//! for free. `NSPopover` owns a private window and view controller, always draws its
//! arrow and its own content insets on macOS 26/27, positions itself (zpui flips and
//! clamps against the screen itself, with the same rules as the in-window popovers), and
//! cannot host a mouse-transparent tooltip. On macOS 26+ the panel's material is a
//! Liquid Glass `NSGlassEffectView` (what Tahoe menus and popovers are made of);
//! elsewhere, or with Liquid Glass off, an `NSVisualEffectView` with the `.popover`,
//! `.menu` or `.toolTip` material. Either way it looks and animates like the system
//! surfaces: AppKit's window shadow follows the rounded content, and ordering in / out
//! uses the utility-window animation (the fade + scale of system popovers).
//!
//! * The panel is a child window of the parent while shown (it moves with it) and may
//!   extend past it. Frames come in the parent's content coordinates (top-left origin).
//! * Keyboard focus: a `key` popover becomes the key window; its parent keeps reporting
//!   itself active (`key_popovers`), so zpui draws it as focused, and the parent's
//!   private active-appearance hooks (installed only when AppKit has them) keep the
//!   traffic lights lit.
//! * Dismissal: losing key status (a click in another window or app, an app switch)
//!   reports `popover_dismiss(.outside_click)`; presses inside the parent and Escape are
//!   handled by the core.
//! * Appearance is pinned to the theme (`dark`), so the material matches the app.

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const platform = @import("../platform.zig");
const dispatcher = @import("dispatcher.zig");
const native_views = @import("native_views.zig");
const window_mod = @import("window.zig");

const MacWindow = window_mod.MacWindow;
const id = objc.id;
const BOOL = objc.BOOL;
const YES = objc.YES;
const NO = objc.NO;
const NSRect = ak.NSRect;
const CGFloat = ak.CGFloat;
const Bounds = platform.Bounds;

const NSVisualEffectMaterialMenu: ak.NSInteger = 5;
const NSVisualEffectMaterialPopover: ak.NSInteger = 6;
const NSVisualEffectMaterialToolTip: ak.NSInteger = 17;

/// Per-popover backend state (`MacWindow.popover`).
pub const State = struct {
    /// The parent's ZPUIView (+1); its `MacWindow` is looked up through the ivar, so a
    /// parent torn down first reads as gone.
    parent_view: id,
    key: bool,
    mouse_transparent: bool,
    /// The material view under the zpui surface (+1).
    material_view: ?id = null,
    shown: bool = false,
};

fn responds(obj: id, comptime selector: [:0]const u8) bool {
    return obj.msg(BOOL, "respondsToSelector:", .{objc.cachedSel(selector)}) == YES;
}

/// A rect in `w`'s content coordinates (top-left origin, logical px) on screen.
pub fn contentToScreen(w: *const MacWindow, b: Bounds) NSRect {
    const content_view = w.native_window.msg(id, "contentView", .{});
    const ch: CGFloat = w.contentSize().height;
    const local: NSRect = .{
        .origin = .{ .x = b.origin.x, .y = ch - @as(CGFloat, b.origin.y) - b.size.height },
        .size = .{ .width = b.size.width, .height = b.size.height },
    };
    const in_window = ak.msgStruct(NSRect, content_view, "convertRect:toView:", .{ local, @as(?id, null) });
    return ak.msgStruct(NSRect, w.native_window, "convertRectToScreen:", .{in_window});
}

/// `platform.Window.screenBoundsInContent`: the visible frame of `w`'s screen.
pub fn screenBoundsInContent(w: *const MacWindow) ?Bounds {
    if (w.closed) return null;
    const screen = w.native_window.msg(?id, "screen", .{}) orelse return null;
    const visible = ak.msgStruct(NSRect, screen, "visibleFrame", .{});
    const in_window = ak.msgStruct(NSRect, w.native_window, "convertRectFromScreen:", .{visible});
    const content_view = w.native_window.msg(id, "contentView", .{});
    const local = ak.msgStruct(NSRect, content_view, "convertRect:fromView:", .{ in_window, @as(?id, null) });
    const ch: CGFloat = w.contentSize().height;
    return .{
        .origin = .{ .x = @floatCast(local.origin.x), .y = @floatCast(ch - local.origin.y - local.size.height) },
        .size = .{ .width = @floatCast(local.size.width), .height = @floatCast(local.size.height) },
    };
}

/// Style the freshly created panel as a popover (called from `MacWindow.open`).
pub fn setUp(w: *MacWindow, pp: platform.PopoverParams) void {
    const parent = MacWindow.fromWindow(pp.parent);
    const win = w.native_window;
    win.msg(void, "setHasShadow:", .{YES});
    win.msg(void, "setHidesOnDeactivate:", .{NO});
    win.msg(void, "setMovable:", .{NO});
    win.msg(void, "setIgnoresMouseEvents:", .{objc.toBOOL(pp.mouse_transparent)});
    if (responds(win, "setBecomesKeyOnlyIfNeeded:")) win.msg(void, "setBecomesKeyOnlyIfNeeded:", .{objc.toBOOL(!pp.key)});
    if (responds(win, "setFloatingPanel:")) win.msg(void, "setFloatingPanel:", .{NO});
    // Theme-pinned appearance (else the parent's), for the material and any native view.
    const appearance: ?id = if (pp.dark) |dark|
        ak.class("NSAppearance").msg(?id, "appearanceNamed:", .{objc.nsString(if (dark) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua")})
    else
        parent.native_window.msg(?id, "appearance", .{});
    win.msg(void, "setAppearance:", .{appearance});

    // Rounded content: the window shadow follows the clipped layer tree.
    const content_view = win.msg(id, "contentView", .{});
    content_view.msg(void, "setWantsLayer:", .{YES});
    if (content_view.msg(?id, "layer", .{})) |layer| {
        layer.msg(void, "setCornerRadius:", .{@as(CGFloat, pp.corner_radius)});
        layer.msg(void, "setMasksToBounds:", .{YES});
        if (responds(layer, "setCornerCurve:")) layer.msg(void, "setCornerCurve:", .{objc.nsString("continuous")});
    }

    const frame_rect = ak.bounds(content_view);
    var material: ?id = null;
    if (pp.liquid_glass and native_views.glassSupported()) if (objc.getClass("NSGlassEffectView")) |cls| {
        const g = cls.msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{frame_rect});
        if (responds(g, "setCornerRadius:")) g.msg(void, "setCornerRadius:", .{@as(CGFloat, pp.corner_radius)});
        material = g;
    };
    if (material == null) {
        const v = ak.class("NSVisualEffectView").msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{frame_rect});
        v.msg(void, "setMaterial:", .{switch (pp.material) {
            .popover => NSVisualEffectMaterialPopover,
            .menu => NSVisualEffectMaterialMenu,
            .tooltip => NSVisualEffectMaterialToolTip,
        }});
        v.msg(void, "setBlendingMode:", .{ak.NSVisualEffectBlendingModeBehindWindow});
        v.msg(void, "setState:", .{ak.NSVisualEffectStateActive});
        material = v;
    }
    const m = material.?;
    m.msg(void, "setAutoresizingMask:", .{ak.NSViewWidthSizable | ak.NSViewHeightSizable});
    content_view.msg(void, "addSubview:positioned:relativeTo:", .{ m, ak.NSWindowBelow, @as(?id, null) });
    w.popover = .{
        .parent_view = parent.native_view.retain(),
        .key = pp.key,
        .mouse_transparent = pp.mouse_transparent,
        .material_view = m, // keep the +1 from alloc
    };
}

/// `MacWindow.destroy`: detach from the parent and drop the references.
pub fn deinit(w: *MacWindow) void {
    const st = &(w.popover orelse return);
    if (st.shown) if (window_mod.stateOf(st.parent_view)) |parent| {
        parent.native_window.msg(void, "removeChildWindow:", .{w.native_window});
        if (st.key) parent.key_popovers -|= 1;
    };
    if (st.material_view) |v| v.release();
    st.parent_view.release();
    w.popover = null;
}

const PlaceRequest = struct { view: id, frame: Bounds, visible: bool };

/// `platform.Window.placePopover` (applied on the next main-queue turn, like resize).
pub fn place(w: *MacWindow, frame: Bounds, visible: bool) void {
    const Ctx = struct {
        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const req: *PlaceRequest = @ptrCast(@alignCast(ctx.?));
            defer std.heap.c_allocator.destroy(req);
            defer req.view.release();
            const win = window_mod.stateOf(req.view) orelse return;
            if (win.closed) return;
            apply(win, req.frame, req.visible);
        }
    };
    const req = std.heap.c_allocator.create(PlaceRequest) catch return;
    req.* = .{ .view = w.native_view.retain(), .frame = frame, .visible = visible };
    dispatcher.onMain(req, &Ctx.run);
}

fn apply(w: *MacWindow, frame: Bounds, visible: bool) void {
    const st = &(w.popover orelse return);
    const parent = window_mod.stateOf(st.parent_view) orelse {
        if (st.shown) hide(w, st, null);
        return;
    };
    if (parent.closed) return;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const rect = contentToScreen(parent, frame);
    w.native_window.msg(void, "setFrame:display:", .{ rect, objc.toBOOL(st.shown) });
    if (visible and !st.shown) {
        // Draw at the new size before the window appears (no stale first frame).
        w.synchronousFrame();
        if (st.key) {
            parent.key_popovers += 1;
            w.native_window.msg(void, "makeKeyAndOrderFront:", .{@as(?id, null)});
        } else {
            w.native_window.msg(void, "orderFront:", .{@as(?id, null)});
        }
        parent.native_window.msg(void, "addChildWindow:ordered:", .{ w.native_window, ak.NSWindowAbove });
        st.shown = true;
    } else if (!visible and st.shown) {
        hide(w, st, parent);
    }
    w.native_window.msg(void, "invalidateShadow", .{});
}

fn hide(w: *MacWindow, st: *State, parent: ?*MacWindow) void {
    st.shown = false;
    if (parent) |p| p.native_window.msg(void, "removeChildWindow:", .{w.native_window});
    const was_key = w.native_window.msg(BOOL, "isKeyWindow", .{}) == YES;
    w.native_window.msg(void, "orderOut:", .{@as(?id, null)}); // the utility-window fade
    const p = parent orelse return;
    if (!st.key) return;
    p.key_popovers -|= 1;
    if (p.key_popovers > 0) return;
    const app_active = ak.sharedApp().msg(BOOL, "isActive", .{}) == YES;
    if (was_key and app_active and p.native_window.msg(BOOL, "isVisible", .{}) == YES) {
        // Hand keyboard focus straight back to the parent.
        p.native_window.msg(void, "makeKeyWindow", .{});
    } else if (p.native_window.msg(BOOL, "isKeyWindow", .{}) != YES) {
        if (p.callbacks.active_status_change) |f| f(p.callbacks.ctx, false);
    }
}

/// The panel lost key status: a press elsewhere or an app switch dismisses it.
pub fn didResignKey(w: *MacWindow) void {
    const st = w.popover orelse return;
    if (!st.shown or !st.key) return;
    const Ctx = struct {
        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const view: id = @ptrCast(ctx.?);
            defer view.release();
            const win = window_mod.stateOf(view) orelse return;
            if (win.closed) return;
            const s = win.popover orelse return;
            if (!s.shown) return;
            if (win.callbacks.popover_dismiss) |f| f(win.callbacks.ctx, .outside_click);
        }
    };
    dispatcher.onMain(w.native_view.retain(), &Ctx.run);
}

/// Whether `w` should look active: it is key, or one of its key popovers is.
pub fn hasActiveChild(w: *const MacWindow) bool {
    return w.key_popovers > 0 and ak.sharedApp().msg(BOOL, "isActive", .{}) == YES;
}
