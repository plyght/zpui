//! [liquid-glass] `liquidGlass` / `liquidGlassGroup` / `overlayPlane` on the headless
//! test platform (which pretends native glass is available; `liquid_glass_supported`
//! turns that off).

const std = @import("std");
const testing = std.testing;
const App = @import("../app/app.zig").App;
const Context = @import("../app/context.zig").Context;
const TestWindow = @import("../app/test_platform.zig").TestWindow;
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const elements = @import("mod.zig");
const lg = @import("liquid_glass.zig");
const pf = @import("../platform/platform.zig");
const div = elements.div;
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");
const px = geometry.px;

const options: window_mod.WindowOptions = .{ .bounds = .{ .origin = .zero, .size = .{ .width = 400, .height = 300 } } };

const GlassView = struct {
    show: bool = true,
    menu: bool = false,
    group: bool = false,
    style: lg.Style = .regular,
    capsule: bool = false,

    pub fn render(self: *GlassView, _: *Window, _: *Context(GlassView)) elements.Div {
        var root = div().size(px(400)).bg(color.white).child(div().h(px(20)));
        const shape: lg.Shape = if (self.capsule) .capsule else .{ .rounded = 12 };
        if (self.show) root = root.child(lg.liquidGlass("glass", .{ .style = self.style, .shape = shape, .tint = color.blue }, div().w(px(200)).h(px(60))
            .child(div().size(px(10)).bg(color.red))));
        if (self.menu) root = root.child(elements.deferred(lg.liquidGlass("menu-glass", .{ .shape = .{ .rounded = 8 } }, div().size(px(30))
            .child(div().size(px(10)).bg(color.blue)))));
        if (self.group) root = root.child(lg.liquidGlassGroup("tools", .{ .spacing = 12 }, div().flex().gap(px(4))
            .child(lg.liquidGlass("a", .{ .shape = .capsule }, div().w(px(40)).h(px(20))))
            .child(lg.liquidGlass("b", .{ .shape = .capsule }, div().w(px(40)).h(px(20))))));
        return root;
    }
};

fn initView(_: *Window, _: *Context(GlassView)) GlassView {
    return .{};
}

fn update(app: *App, handle: anytype, comptime f: anytype) void {
    var l = handle.rootView(app).?.lease(app);
    f(l.value);
    l.cx.notify();
    l.end();
}

fn glassIds(tw: *const TestWindow, out: []pf.NativeViewId) usize {
    var n: usize = 0;
    for (tw.glass_attach, tw.native_attached, 0..) |g, a, i| if (g != null and a) {
        out[n] = @enumFromInt(i);
        n += 1;
    };
    return n;
}

test "liquidGlass places base-tier glass under an overlay-plane foreground" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    try testing.expect(lg.platformSupportsLiquidGlass(app));
    const handle = try app.openWindow(options, GlassView, initView, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    try testing.expectEqual(@as(usize, 1), tw.glassCount());
    var ids: [8]pf.NativeViewId = undefined;
    _ = glassIds(tw, &ids);
    const i = @intFromEnum(ids[0]);
    try testing.expectEqual(pf.NativeViewZ.above_content, tw.glass_attach[i].?.z);
    try testing.expectEqual(pf.LiquidGlassKind.glass, tw.glass_attach[i].?.kind);
    const cfg = tw.glass_config[i].?;
    try testing.expectEqual(@as(f32, 12), cfg.corner_radius);
    try testing.expect(cfg.tint != null);
    const p = tw.native_placement[i].?;
    try testing.expectEqual(@as(f32, 20), p.bounds.origin.y);
    try testing.expectEqual(@as(f32, 200), p.bounds.size.width);
    try testing.expectEqual(@as(f32, 12), p.corner_radius);
    // The foreground (one red quad) is on the overlay plane; the white page is not.
    try testing.expectEqual(@as(usize, 1), tw.last_overlay_len);
    try testing.expectEqual(pf.OverlayPlane.overlay, tw.last_overlay[0].plane);
    try testing.expect(tw.last_overlay[0].start > 0);
    try testing.expect(!tw.last_capture_input);

    // Restyle → reconfigured in place (same view).
    update(app, handle, struct {
        fn f(v: *GlassView) void {
            v.style = .clear;
            v.capsule = true;
        }
    }.f);
    try testing.expectEqual(@as(usize, 1), tw.glassCount());
    try testing.expectEqual(pf.LiquidGlassStyle.clear, tw.glass_config[i].?.style);
    try testing.expectEqual(@as(f32, 30), tw.glass_config[i].?.corner_radius); // capsule: 60 / 2
    try testing.expectEqual(@as(u32, 1), w.liquid_glass.attach_count);

    // Not painted → hidden, then detached after the idle grace period.
    update(app, handle, struct {
        fn f(v: *GlassView) void {
            v.show = false;
        }
    }.f);
    try testing.expect(tw.native_placement[i] == null);
    try testing.expectEqual(@as(usize, 1), tw.glassCount());
    for (0..window_mod.liquid_glass_mod.keep_idle_presents + 1) |_| w.drawAndPresent();
    try testing.expectEqual(@as(usize, 0), tw.glassCount());
    try testing.expectEqual(@as(usize, 0), w.liquid_glass.entries.items.len);
}

test "liquidGlass inside a deferred menu floats: above the overlay plane, foreground on the top plane" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, GlassView, initView, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    update(app, handle, struct {
        fn f(v: *GlassView) void {
            v.menu = true;
        }
    }.f);
    try testing.expectEqual(@as(usize, 2), tw.glassCount());
    var ids: [8]pf.NativeViewId = undefined;
    _ = glassIds(tw, &ids);
    var floating: usize = 0;
    for (ids[0..2]) |id| {
        if (tw.glass_attach[@intFromEnum(id)].?.z == .above_overlay) floating += 1;
    }
    try testing.expectEqual(@as(usize, 1), floating);
    // Base glass foreground (overlay), menu foreground (top) — disjoint, sorted.
    var saw_top = false;
    var prev_end: usize = 0;
    for (tw.last_overlay[0..tw.last_overlay_len]) |r| {
        try testing.expect(r.start >= prev_end);
        try testing.expect(r.end > r.start);
        prev_end = r.end;
        if (r.plane == .top) saw_top = true;
    }
    try testing.expect(saw_top);
    try testing.expect(tw.last_capture_input);
}

test "liquidGlassGroup members attach inside their container" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, GlassView, initView, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    update(app, handle, struct {
        fn f(v: *GlassView) void {
            v.show = false;
            v.group = true;
        }
    }.f);
    var ids: [8]pf.NativeViewId = undefined;
    const n = glassIds(tw, &ids);
    var container: ?pf.NativeViewId = null;
    for (ids[0..n]) |id| if (tw.glass_attach[@intFromEnum(id)].?.kind == .container) {
        container = id;
    };
    try testing.expect(container != null);
    try testing.expectEqual(@as(f32, 12), tw.glass_config[@intFromEnum(container.?)].?.spacing);
    var members: usize = 0;
    for (ids[0..n]) |id| {
        const a = tw.glass_attach[@intFromEnum(id)].?;
        if (a.kind == .glass and a.parent != null and a.parent.? == container.?) {
            members += 1;
            try testing.expectEqual(@as(f32, 10), tw.glass_config[@intFromEnum(id)].?.corner_radius);
        }
    }
    try testing.expectEqual(@as(usize, 2), members);
    // Dropping the group (after the grace period) detaches members with it.
    update(app, handle, struct {
        fn f(v: *GlassView) void {
            v.group = false;
        }
    }.f);
    for (0..window_mod.liquid_glass_mod.keep_idle_presents + 1) |_| w.drawAndPresent();
    try testing.expectEqual(@as(usize, 0), tw.glassCount());
}

test "without native glass liquidGlass paints its child in place" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    app.test_platform.?.liquid_glass_supported = false;
    try testing.expect(!lg.platformSupportsLiquidGlass(app));
    const handle = try app.openWindow(options, GlassView, initView, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    try testing.expectEqual(@as(usize, 0), tw.glassCount());
    try testing.expectEqual(@as(usize, 0), tw.last_overlay_len);
    try testing.expect(!w.supportsLiquidGlass());
    // The foreground still painted (white page + red quad).
    var red = false;
    for (w.rendered_frame.scene.quads.items) |q| {
        if (std.meta.eql(q.background.solid, color.red)) red = true;
    }
    try testing.expect(red);
}

test "overlayPlane wraps content in an overlay range" {
    const V = struct {
        pub fn render(_: *@This(), _: *Window, _: *Context(@This())) elements.Div {
            return div().size(px(100)).bg(color.white).child(lg.overlayPlane(true, div().size(px(10)).bg(color.red)))
                .child(lg.overlayPlane(false, div().size(px(10)).bg(color.blue)));
        }
    };
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, V, struct {
        fn f(_: *Window, _: *Context(V)) V {
            return .{};
        }
    }.f, .{});
    const tw = TestWindow.of(handle.window(app).?.platform_window);
    try testing.expectEqual(@as(usize, 1), tw.last_overlay_len);
    try testing.expect(tw.last_overlay[0].end > tw.last_overlay[0].start);
}
