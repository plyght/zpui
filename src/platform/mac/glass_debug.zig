//! [glass-lab] Liquid Glass diagnostics for a zpui window on macOS (CI evidence
//! gathering; `ZERON_GLASS_LAB=1`, apps/zeron/src/glass_lab.zig).
//!
//! * `accessibility` — NSWorkspace display accommodations (Reduce Transparency etc.);
//!   with Reduce Transparency on, AppKit legitimately draws glass/materials solid.
//! * `dump` — the window, its content-view subtree (view class, frame, layer class and
//!   the layer flags that decide backdrop sampling: opaque, hidden, opacity, mask,
//!   masksToBounds, shouldRasterize, filters), the CAMetalLayers, and every glass
//!   view's properties plus its private layer tree (is a `CABackdropLayer` there?).
//! * `addControls` — reference views that bypass zpui's hosting: an `NSGlassEffectView`
//!   added straight to the content view, a within-window `NSVisualEffectView`, and an
//!   AppKit-only scene (CALayer stripes under an `NSGlassEffectView`).
//! * `windowRectCG` — the window frame in CoreGraphics global coordinates (top-left
//!   origin of the primary display), for an on-screen `CGWindowListCreateImage`.
//!
//! Debug only: nothing here runs unless an app calls it.

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const cf = @import("cf.zig");
const window_mod = @import("window.zig");
const native_views = @import("native_views.zig");

const MacWindow = window_mod.MacWindow;
const id = objc.id;
const BOOL = objc.BOOL;
const YES = objc.YES;
const NO = objc.NO;
const NSRect = ak.NSRect;
const CGFloat = ak.CGFloat;
const NSInteger = ak.NSInteger;
const NSUInteger = ak.NSUInteger;

extern "c" fn CGColorGetAlpha(color: ?*anyopaque) CGFloat;

const print = std.debug.print;

pub const Accessibility = struct {
    reduce_transparency: bool,
    increase_contrast: bool,
    differentiate_without_color: bool,
    reduce_motion: bool,
    invert_colors: bool,
};

fn wsFlag(ws: id, comptime selector: [:0]const u8) bool {
    if (ws.msg(BOOL, "respondsToSelector:", .{objc.cachedSel(selector)}) != YES) return false;
    return ws.msg(BOOL, selector, .{}) == YES;
}

/// NSWorkspace display accommodations as AppKit sees them in this process.
pub fn accessibility() Accessibility {
    const ws = ak.class("NSWorkspace").msg(id, "sharedWorkspace", .{});
    return .{
        .reduce_transparency = wsFlag(ws, "accessibilityDisplayShouldReduceTransparency"),
        .increase_contrast = wsFlag(ws, "accessibilityDisplayShouldIncreaseContrast"),
        .differentiate_without_color = wsFlag(ws, "accessibilityDisplayShouldDifferentiateWithoutColor"),
        .reduce_motion = wsFlag(ws, "accessibilityDisplayShouldReduceMotion"),
        .invert_colors = wsFlag(ws, "accessibilityDisplayShouldInvertColors"),
    };
}

fn responds(obj: id, comptime selector: [:0]const u8) bool {
    return obj.msg(BOOL, "respondsToSelector:", .{objc.cachedSel(selector)}) == YES;
}

fn str(obj: ?id) []const u8 {
    const o = obj orelse return "nil";
    const d = o.msg(?id, "description", .{}) orelse return "?";
    return ak.stringBytes(d);
}

fn className(obj: id) []const u8 {
    return ak.stringBytes(obj.msg(id, "className", .{}));
}

fn b(v: BOOL) []const u8 {
    return if (v == YES) "YES" else "no";
}

fn rect(r: NSRect) [4]f64 {
    return .{ r.origin.x, r.origin.y, r.size.width, r.size.height };
}

/// One line of layer flags (the properties that decide whether a backdrop above can
/// sample what is below, or whether the layer forms an isolated offscreen group).
fn layerLine(layer: id) void {
    const bg: ?*anyopaque = layer.msg(?*anyopaque, "backgroundColor", .{});
    const filters = layer.msg(?id, "filters", .{});
    const comp = layer.msg(?id, "compositingFilter", .{});
    print("{s} frame={any} opaque={s} hidden={s} opacity={d:.2} masksToBounds={s} mask={s} rasterize={s} cornerRadius={d:.1} bgAlpha={d:.3} groupOpacity={s}", .{
        className(layer),
        rect(ak.msgStruct(NSRect, layer, "frame", .{})),
        b(layer.msg(BOOL, "isOpaque", .{})),
        b(layer.msg(BOOL, "isHidden", .{})),
        layer.msg(f32, "opacity", .{}),
        b(layer.msg(BOOL, "masksToBounds", .{})),
        if (layer.msg(?id, "mask", .{}) != null) "SET" else "nil",
        b(layer.msg(BOOL, "shouldRasterize", .{})),
        layer.msg(CGFloat, "cornerRadius", .{}),
        if (bg) |c| CGColorGetAlpha(c) else 0,
        b(layer.msg(BOOL, "allowsGroupOpacity", .{})),
    });
    if (filters) |f| if (ak.arrayCount(f) > 0) print(" filters={s}", .{oneLine(str(f))});
    if (comp != null) print(" compositingFilter={s}", .{str(comp)});
    if (objc.getClass("CAMetalLayer")) |ml| if (objc.isKindOf(layer, ml)) {
        const size = ak.msgStruct(ak.NSSize, layer, "drawableSize", .{});
        print(" [metal pixelFormat={d} framebufferOnly={s} presentsWithTransaction={s} drawableSize={d}x{d}]", .{
            layer.msg(NSUInteger, "pixelFormat", .{}),
            b(layer.msg(BOOL, "framebufferOnly", .{})),
            b(layer.msg(BOOL, "presentsWithTransaction", .{})),
            size.width,
            size.height,
        });
    };
    // CABackdropLayer (private): the sampler behind materials and glass.
    if (std.mem.indexOf(u8, className(layer), "Backdrop") != null) {
        if (responds(layer, "isEnabled")) print(" enabled={s}", .{b(layer.msg(BOOL, "isEnabled", .{}))});
        if (responds(layer, "scale")) print(" scale={d:.3}", .{layer.msg(CGFloat, "scale", .{})});
        if (responds(layer, "windowServerAware")) print(" windowServerAware={s}", .{b(layer.msg(BOOL, "windowServerAware", .{}))});
        if (responds(layer, "groupName")) print(" groupName={s}", .{str(layer.msg(?id, "groupName", .{}))});
        if (responds(layer, "captureOnly")) print(" captureOnly={s}", .{b(layer.msg(BOOL, "captureOnly", .{}))});
    }
    print("\n", .{});
}

/// Descriptions can span lines; keep the log one line per layer.
fn oneLine(s: []const u8) []const u8 {
    const State = struct {
        var buf: [512]u8 = undefined;
    };
    const n = @min(s.len, State.buf.len);
    for (s[0..n], 0..) |c, i| State.buf[i] = if (c == '\n' or c == '\r') ' ' else c;
    return State.buf[0..n];
}

fn indent(depth: usize) void {
    for (0..depth) |_| print("  ", .{});
}

fn dumpLayerTree(layer: id, depth: usize, max_depth: usize) void {
    indent(depth);
    print("- ", .{});
    layerLine(layer);
    if (depth >= max_depth) return;
    const subs = layer.msg(?id, "sublayers", .{}) orelse return;
    const n = ak.arrayCount(subs);
    var i: NSUInteger = 0;
    while (i < n) : (i += 1) dumpLayerTree(ak.arrayAt(subs, i), depth + 1, max_depth);
}

fn glassClass() ?*objc.Class {
    return objc.getClass("NSGlassEffectView");
}

fn dumpView(view: id, depth: usize) void {
    indent(depth);
    print("{s} frame={any} hidden={s} wantsLayer={s} flipped={s}", .{
        className(view),
        rect(ak.frame(view)),
        b(view.msg(BOOL, "isHidden", .{})),
        b(view.msg(BOOL, "wantsLayer", .{})),
        b(view.msg(BOOL, "isFlipped", .{})),
    });
    if (view.msg(?id, "appearance", .{})) |a| print(" appearance={s}", .{str(a.msg(?id, "name", .{}))});
    print("\n", .{});
    if (view.msg(?id, "layer", .{})) |layer| {
        indent(depth + 1);
        print("layer: ", .{});
        layerLine(layer);
    }
    if (glassClass()) |gc| if (objc.isKindOf(view, gc)) dumpGlass(view, depth + 1);
    if (objc.getClass("NSVisualEffectView")) |vc| if (objc.isKindOf(view, vc)) {
        indent(depth + 1);
        print("NSVisualEffectView material={d} blendingMode={d} state={d} emphasized={s}\n", .{
            view.msg(NSInteger, "material", .{}),
            view.msg(NSInteger, "blendingMode", .{}),
            view.msg(NSInteger, "state", .{}),
            b(view.msg(BOOL, "isEmphasized", .{})),
        });
        if (view.msg(?id, "layer", .{})) |l| dumpLayerTree(l, depth + 1, depth + 5);
    };
    const subs = view.msg(id, "subviews", .{});
    const n = ak.arrayCount(subs);
    var i: NSUInteger = 0;
    while (i < n) : (i += 1) dumpView(ak.arrayAt(subs, i), depth + 1);
}

fn dumpGlass(view: id, depth: usize) void {
    indent(depth);
    print("NSGlassEffectView:", .{});
    if (responds(view, "style")) print(" style={d}", .{view.msg(NSInteger, "style", .{})});
    if (responds(view, "cornerRadius")) print(" cornerRadius={d:.1}", .{view.msg(CGFloat, "cornerRadius", .{})});
    if (responds(view, "tintColor")) print(" tintColor={s}", .{oneLine(str(view.msg(?id, "tintColor", .{})))});
    if (responds(view, "contentView")) print(" contentView={s}", .{if (view.msg(?id, "contentView", .{})) |c| className(c) else "nil"});
    if (responds(view, "effectIsInteractive")) print(" interactive={s}", .{b(view.msg(BOOL, "effectIsInteractive", .{}))});
    if (view.msg(?id, "effectiveAppearance", .{})) |a| print(" effectiveAppearance={s}", .{str(a.msg(?id, "name", .{}))});
    print("\n", .{});
    indent(depth);
    print("glass layer tree (look for CABackdropLayer + its filters):\n", .{});
    if (view.msg(?id, "layer", .{})) |l| dumpLayerTree(l, depth + 1, depth + 7);
    // The superview chain up to the window's theme frame.
    indent(depth);
    print("superview chain:", .{});
    var sv = view.msg(?id, "superview", .{});
    while (sv) |s| : (sv = s.msg(?id, "superview", .{})) {
        print(" <- {s}", .{className(s)});
        if (s.msg(?id, "layer", .{})) |l| print("(opaque={s} masks={s} mask={s})", .{
            b(l.msg(BOOL, "isOpaque", .{})),
            b(l.msg(BOOL, "masksToBounds", .{})),
            if (l.msg(?id, "mask", .{}) != null) "SET" else "nil",
        });
    }
    print("\n", .{});
}

/// Print everything a Liquid Glass rendering question needs (one block, stderr).
pub fn dump(w: *MacWindow, label: []const u8) void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const win = w.native_window;
    print("==== zpui glass diagnostics: {s} ====\n", .{label});
    const pi = ak.class("NSProcessInfo").msg(id, "processInfo", .{});
    print("os: {s}\n", .{str(pi.msg(?id, "operatingSystemVersionString", .{}))});
    const a = accessibility();
    print("accessibility (NSWorkspace, in-process): reduceTransparency={} increaseContrast={} differentiateWithoutColor={} reduceMotion={} invertColors={}\n", .{
        a.reduce_transparency, a.increase_contrast, a.differentiate_without_color, a.reduce_motion, a.invert_colors,
    });
    print("liquid glass supported: {} (NSGlassEffectView={} NSGlassEffectContainerView={})\n", .{
        native_views.glassSupported(), objc.getClass("NSGlassEffectView") != null, objc.getClass("NSGlassEffectContainerView") != null,
    });
    const device = w.renderer.device;
    print("metal device: {s} lowPower={s} headless={s} removable={s}\n", .{
        str(device.msg(?id, "name", .{})),
        b(device.msg(BOOL, "isLowPower", .{})),
        b(device.msg(BOOL, "isHeadless", .{})),
        b(device.msg(BOOL, "isRemovable", .{})),
    });
    if (win.msg(?id, "screen", .{})) |s| {
        print("screen: frame={any} backingScale={d:.1} colorSpace={s}\n", .{
            rect(ak.frame(s)),
            s.msg(CGFloat, "backingScaleFactor", .{}),
            oneLine(str(s.msg(?id, "colorSpace", .{}))),
        });
    }
    print("window: class={s} frame={any} isOpaque={s} alpha={d:.2} hasShadow={s} styleMask=0x{x} key={s} main={s} occlusionVisible={s}\n", .{
        className(win),
        rect(ak.frame(win)),
        b(win.msg(BOOL, "isOpaque", .{})),
        win.msg(CGFloat, "alphaValue", .{}),
        b(win.msg(BOOL, "hasShadow", .{})),
        win.msg(NSUInteger, "styleMask", .{}),
        b(win.msg(BOOL, "isKeyWindow", .{})),
        b(win.msg(BOOL, "isMainWindow", .{})),
        b(objc.toBOOL(win.msg(NSUInteger, "occlusionState", .{}) & ak.NSWindowOcclusionStateVisible != 0)),
    });
    print("window backgroundColor={s}\n", .{oneLine(str(win.msg(?id, "backgroundColor", .{})))});
    if (win.msg(?id, "effectiveAppearance", .{})) |ea| print("window effectiveAppearance={s}\n", .{str(ea.msg(?id, "name", .{}))});
    print("zpui: background={t} renderer.is_opaque={} main layer opaque={s} overlay plane={} top plane={} native children={d}\n", .{
        w.background,
        w.renderer.is_opaque,
        if (w.renderer.metal_layer) |l| b(l.msg(BOOL, "isOpaque", .{})) else "-",
        w.natives.overlay_view != null,
        w.natives.top_view != null,
        w.natives.children.items.len,
    });
    const content = win.msg(id, "contentView", .{});
    if (content.msg(?id, "superview", .{})) |frame_view| {
        print("theme frame: {s}", .{className(frame_view)});
        if (frame_view.msg(?id, "layer", .{})) |l| {
            print(" layer: ", .{});
            layerLine(l);
        } else print("\n", .{});
    }
    print("content view subtree (back to front):\n", .{});
    dumpView(content, 1);
    print("==== end glass diagnostics ====\n", .{});
}

/// The window frame in CoreGraphics global coordinates (origin at the primary
/// display's top-left), for `CGWindowListCreateImage(rect, OnScreenOnly, 0, ...)`.
pub fn windowRectCG(w: *MacWindow) cf.CGRect {
    const f = ak.frame(w.native_window);
    const screens = ak.class("NSScreen").msg(id, "screens", .{});
    const primary_h: f64 = if (ak.arrayCount(screens) > 0) ak.frame(ak.arrayAt(screens, 0)).size.height else f.origin.y + f.size.height;
    return .{
        .origin = .{ .x = f.origin.x, .y = primary_h - f.origin.y - f.size.height },
        .size = .{ .width = f.size.width, .height = f.size.height },
    };
}

/// A control rectangle in zpui logical coordinates (top-left origin of the content view).
pub const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

pub const Controls = struct {
    /// `NSGlassEffectView` added straight to the content view (no zpui host view).
    direct_glass: ?Rect = null,
    /// Within-window `NSVisualEffectView` (HUD material): does a backdrop see the Metal layer?
    within_window_vev: ?Rect = null,
    /// AppKit-only scene: CALayer stripes with an `NSGlassEffectView` over them.
    appkit_scene: ?Rect = null,
    dark: bool = false,
};

fn toContent(w: *MacWindow, r: Rect) NSRect {
    const content = w.native_window.msg(id, "contentView", .{});
    const h = ak.bounds(content).size.height;
    return .{ .origin = .{ .x = r.x, .y = h - r.y - r.h }, .size = .{ .width = r.w, .height = r.h } };
}

fn insertAboveMain(w: *MacWindow, view: id) void {
    const content = w.native_window.msg(id, "contentView", .{});
    content.msg(void, "addSubview:positioned:relativeTo:", .{ view, ak.NSWindowAbove, w.native_view });
}

fn pinAppearance(view: id, dark: bool) void {
    const name = objc.nsString(if (dark) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua");
    view.msg(void, "setAppearance:", .{ak.class("NSAppearance").msg(?id, "appearanceNamed:", .{name})});
}

fn cgColor(r: CGFloat, g: CGFloat, bl: CGFloat) ?*anyopaque {
    return ak.class("NSColor").msg(id, "colorWithSRGBRed:green:blue:alpha:", .{ r, g, bl, @as(CGFloat, 1) }).msg(?*anyopaque, "CGColor", .{});
}

/// Add the reference views (above the main Metal surface, below zpui's glass hosts and
/// overlay planes). Mouse events still reach them; the lab does not click there.
pub fn addControls(w: *MacWindow, c: Controls) void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    if (c.direct_glass) |r| if (glassClass()) |gc| {
        const g = gc.msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{toContent(w, r)});
        if (responds(g, "setCornerRadius:")) g.msg(void, "setCornerRadius:", .{@as(CGFloat, 24)});
        pinAppearance(g, c.dark);
        insertAboveMain(w, g);
        g.release();
    };
    if (c.within_window_vev) |r| if (objc.getClass("NSVisualEffectView")) |vc| {
        const v = vc.msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{toContent(w, r)});
        v.msg(void, "setMaterial:", .{@as(NSInteger, 13)}); // .hudWindow
        v.msg(void, "setBlendingMode:", .{@as(NSInteger, 1)}); // .withinWindow
        v.msg(void, "setState:", .{@as(NSInteger, 1)}); // .active
        insertAboveMain(w, v);
        v.release();
    };
    if (c.appkit_scene) |r| {
        const host = ak.class("NSView").msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{toContent(w, r)});
        host.msg(void, "setWantsLayer:", .{YES});
        if (host.msg(?id, "layer", .{})) |hl| {
            const colors = [_][3]CGFloat{ .{ 1, 0.1, 0.4 }, .{ 1, 0.85, 0 }, .{ 0.1, 0.8, 0.3 }, .{ 0.1, 0.4, 1 }, .{ 0.05, 0.05, 0.05 }, .{ 1, 1, 1 } };
            const stripe: CGFloat = 12;
            var i: usize = 0;
            var x: CGFloat = 0;
            while (x < r.w) : ({
                x += stripe;
                i += 1;
            }) {
                const l = ak.class("CALayer").msg(id, "new", .{});
                const col = colors[i % colors.len];
                l.msg(void, "setBackgroundColor:", .{cgColor(col[0], col[1], col[2])});
                l.msg(void, "setFrame:", .{NSRect{ .origin = .{ .x = x, .y = 0 }, .size = .{ .width = stripe, .height = r.h } }});
                hl.msg(void, "addSublayer:", .{l});
                l.release();
            }
        }
        if (glassClass()) |gc| {
            const inset: CGFloat = 18;
            const g = gc.msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{NSRect{
                .origin = .{ .x = inset, .y = inset },
                .size = .{ .width = r.w - 2 * inset, .height = r.h - 2 * inset },
            }});
            if (responds(g, "setCornerRadius:")) g.msg(void, "setCornerRadius:", .{@as(CGFloat, 20)});
            pinAppearance(g, c.dark);
            host.msg(void, "addSubview:", .{g});
            g.release();
        }
        insertAboveMain(w, host);
        host.release();
    }
}
