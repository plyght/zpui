//! System symbols (SF Symbols) through the TestPlatform's fake renderer: the svg element's
//! symbol source, SVG fallback, fallback names, caching, the resolver and `available`.

const std = @import("std");
const testing = std.testing;
const App = @import("../app/app.zig").App;
const Context = @import("../app/context.zig").Context;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const elements = @import("../elements/mod.zig");
const div = elements.div;
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");
const system_symbol = @import("system_symbol.zig");

const px = geometry.px;
const options: window_mod.WindowOptions = .{ .bounds = .{ .origin = .zero, .size = .{ .width = 400, .height = 300 } } };
const tiny_svg = "<svg width=\"8\" height=\"8\" xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"8\" height=\"8\" fill=\"#000\"/></svg>";

const Mode = enum { symbol, fallback_names, two_weights, symbol_only, plain };
var mode: Mode = .symbol;

const View = struct {
    fn init(_: *Window, _: *Context(View)) View {
        return .{};
    }
    pub fn render(_: *View, _: *Window, _: *Context(View)) elements.Div {
        const icon = elements.svg().source("tiny", tiny_svg).size(px(16)).textColor(color.red);
        const root = div().absolute().left(px(100)).top(px(40)).flex();
        return div().sizeFull().child(switch (mode) {
            .symbol => root.child(icon.symbol("folder", .{ .point_size = 13, .fit = 16 })),
            .fallback_names => root.child(icon.symbols(&.{ "folder.fancy", "folder" }, .{ .point_size = 13, .fit = 16 })),
            .two_weights => root
                .child(icon.symbol("folder", .{ .point_size = 13 }))
                .child(elements.svg().source("tiny", tiny_svg).size(px(16)).symbol("folder", .{ .point_size = 13, .weight = .semibold })),
            .symbol_only => root.child(elements.systemSymbol("folder", .{ .point_size = 13 }).size(px(16))),
            .plain => root.child(icon),
        });
    }
};

fn open(app: *App, m: Mode) !*Window {
    mode = m;
    const handle = try app.openWindow(options, View, View.init, .{});
    return handle.window(app).?;
}

fn redraw(app: *App, w: *Window) void {
    w.refresh();
    _ = app.drawDirtyWindows();
}

test "svg().symbol paints the system symbol centered in the same box, tinted, cached" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    tp.system_symbols = &.{"folder"};
    const w = try open(app, .symbol);
    const sprites = w.rendered_frame.scene.monochrome_sprites.items;
    try testing.expectEqual(@as(usize, 1), sprites.len);
    try testing.expect(sprites[0].color.eql(color.red));
    try testing.expectEqualStrings("folder", tp.lastSymbol());
    // The fake symbol is 15.6 x 13 pt, fit inside 16: centered on the 16px box at (100, 40).
    const s = w.scaleFactor();
    const b = sprites[0].bounds;
    try testing.expectEqual(@ceil(15.6 * s - 0.001), b.size.width);
    try testing.expectEqual(@ceil(13 * s - 0.001), b.size.height);
    try testing.expectApproxEqAbs(108 * s, b.origin.x + b.size.width / 2, 0.51);
    try testing.expectApproxEqAbs(48 * s, b.origin.y + b.size.height / 2, 0.51);
    // Rendered once: later frames reuse the atlas tile.
    const renders = tp.symbol_renders;
    redraw(app, w);
    redraw(app, w);
    try testing.expectEqual(renders, tp.symbol_renders);
    try testing.expectEqual(@as(usize, 1), w.rendered_frame.scene.monochrome_sprites.items.len);
}

test "a missing symbol falls back to the SVG and the miss is remembered" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    // No symbols known (an older macOS / unknown name).
    const w = try open(app, .symbol);
    const sprites = w.rendered_frame.scene.monochrome_sprites.items;
    try testing.expectEqual(@as(usize, 1), sprites.len); // the SVG
    const s = w.scaleFactor();
    try testing.expectEqual(16 * s, sprites[0].bounds.size.width);
    try testing.expectEqual(@as(usize, 1), tp.symbol_renders);
    redraw(app, w);
    try testing.expectEqual(@as(usize, 1), tp.symbol_renders);
    try testing.expectEqual(@as(usize, 1), w.rendered_frame.scene.monochrome_sprites.items.len);
}

test "fallback names are tried in order" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    tp.system_symbols = &.{"folder"};
    const w = try open(app, .fallback_names);
    try testing.expectEqual(@as(usize, 2), tp.symbol_renders);
    try testing.expectEqualStrings("folder", tp.lastSymbol());
    const s = w.scaleFactor();
    try testing.expectEqual(@ceil(13 * s - 0.001), w.rendered_frame.scene.monochrome_sprites.items[0].bounds.size.height);
}

test "symbols are cached per weight; a lone systemSymbol paints nothing when missing" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    tp.system_symbols = &.{"folder"};
    const w = try open(app, .two_weights);
    const sprites = w.rendered_frame.scene.monochrome_sprites.items;
    try testing.expectEqual(@as(usize, 2), sprites.len);
    try testing.expectEqual(@as(usize, 2), tp.symbol_renders);
    try testing.expect(sprites[0].tile.tile_id != sprites[1].tile.tile_id);

    const app2 = try App.initTest(testing.allocator);
    defer app2.deinit();
    const w2 = try open(app2, .symbol_only);
    try testing.expectEqual(@as(usize, 0), w2.rendered_frame.scene.monochrome_sprites.items.len);
}

const Map = struct {
    var calls: usize = 0;
    fn resolve(_: ?*anyopaque, _: *App, path: []const u8, size: geometry.Size(geometry.Pixels)) ?system_symbol.Symbol {
        calls += 1;
        if (!std.mem.eql(u8, path, "tiny")) return null;
        return .{ .names = &.{"folder"}, .options = .{ .point_size = size.width * 0.8, .fit = size.width } };
    }
};

test "the App resolver maps plain svgs to symbols; removing it restores the SVG" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    tp.system_symbols = &.{"folder"};
    system_symbol.setResolver(app, .{ .resolve = Map.resolve });
    const w = try open(app, .plain);
    try testing.expect(Map.calls > 0);
    const s = w.scaleFactor();
    var b = w.rendered_frame.scene.monochrome_sprites.items[0].bounds;
    try testing.expectEqual(@ceil(12.8 * s - 0.001), b.size.height); // the symbol, 0.8 x 16
    system_symbol.setResolver(app, null);
    _ = app.drawDirtyWindows();
    b = w.rendered_frame.scene.monochrome_sprites.items[0].bounds;
    try testing.expectEqual(16 * s, b.size.height); // the SVG again
}

test "available reports the platform's symbols and caches misses" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    tp.system_symbols = &.{"gearshape"};
    try testing.expect(system_symbol.available(app, "gearshape", .{}));
    try testing.expect(!system_symbol.available(app, "gearshape.9", .{}));
    const n = tp.symbol_renders;
    try testing.expect(!system_symbol.available(app, "gearshape.9", .{}));
    try testing.expectEqual(n, tp.symbol_renders);
}
