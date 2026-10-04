//! gpui `ExternalPaths`: the payload of a drag that started outside the app (files
//! dropped from a file manager). Platforms report `FileDropEvent`s; the window turns
//! `entered` into an active drag of `ExternalPaths` (so `div().onDrop(ExternalPaths, l)`,
//! `dragOver(ExternalPaths, style)` and `canDrop` work like for internal drags),
//! `pending` into mouse moves, `submit` into a left mouse-up (dropping it) and
//! `exited` into a canceled drag.

const std = @import("std");
const App = @import("../app/app.zig").App;
const AnyView = @import("view.zig").AnyView;
const type_id = @import("../app/type_id.zig");
const geometry = @import("../geometry.zig");
const Window = @import("window.zig").Window;
const div = @import("../elements/div.zig").div;

pub const ExternalPaths = struct {
    /// Absolute paths, valid for the duration of the drag (copy what you keep).
    paths: []const []const u8,
};

/// The (empty) preview view of an external drag; the OS draws its own drag image.
pub const ExternalPathsView = struct {
    pub fn render(_: *ExternalPathsView, _: *Window, _: *@import("../app/context.zig").Context(ExternalPathsView)) @import("../elements/div.zig").Div {
        return div();
    }
};

/// Starts an `ExternalPaths` drag (replacing any drag in progress). The payload
/// lives in one block: the struct, the slice table, then the bytes.
pub fn beginExternalDrag(app: *App, paths: []const []const u8, position: geometry.Point(geometry.Pixels)) void {
    var size: usize = @sizeOf(ExternalPaths) + paths.len * @sizeOf([]const u8);
    for (paths) |p| size += p.len;
    const storage = app.gpa.alignedAlloc(u8, .@"16", size) catch return;
    const header: *ExternalPaths = @ptrCast(@alignCast(storage.ptr));
    const table_ptr: [*][]const u8 = @ptrCast(@alignCast(storage.ptr + @sizeOf(ExternalPaths)));
    var at: usize = @sizeOf(ExternalPaths) + paths.len * @sizeOf([]const u8);
    for (paths, 0..) |p, i| {
        @memcpy(storage[at..][0..p.len], p);
        table_ptr[i] = storage[at..][0..p.len];
        at += p.len;
    }
    header.* = .{ .paths = table_ptr[0..paths.len] };
    const view = app.new(ExternalPathsView, .{}) catch {
        app.gpa.free(storage);
        return;
    };
    app.cancelDrag();
    app.active_drag = .{
        .value = header,
        .storage = storage,
        .type_id = type_id.typeId(ExternalPaths),
        .view = AnyView.fromEntity(view),
        .cursor_offset = position,
    };
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;
const Context = @import("../app/context.zig").Context;
const TestWindow = @import("../app/test_platform.zig").TestWindow;
const color = @import("../color.zig");
const StyleBuilder = @import("../styled.zig").StyleBuilder;
const px = geometry.px;

const DropView = struct {
    dropped: std.ArrayList([]u8) = .empty,
    fn init(_: *Window, _: *Context(DropView)) DropView {
        return .{};
    }
    pub fn deinit(self: *DropView, app: *App) void {
        for (self.dropped.items) |p| app.gpa.free(p);
        self.dropped.deinit(app.gpa);
    }
    fn onDrop(self: *DropView, ev: *const ExternalPaths, _: *Window, cx: *Context(DropView)) void {
        for (ev.paths) |p| self.dropped.append(cx.gpa(), cx.gpa().dupe(u8, p) catch unreachable) catch unreachable;
        cx.notify();
    }
    pub fn render(_: *DropView, _: *Window, cx: *Context(DropView)) @import("../elements/div.zig").Div {
        return div().size(px(400)).child(div().id("target").absolute().top(px(100)).left(px(100)).size(px(100)).bg(color.black)
            .dragOver(ExternalPaths, StyleBuilder.init.bg(color.green)).onDrop(ExternalPaths, cx.listener(DropView.onDrop)));
    }
};

test "external file drops become ExternalPaths drags" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 400, .height = 300 } } }, DropView, DropView.init, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    const paths = [_][]const u8{ "/tmp/a.png", "/tmp/b c.jpg" };
    _ = tw.simulateInput(.{ .file_drop = .{ .entered = .{ .position = .{ .x = 10, .y = 10 }, .paths = &paths } } });
    try testing.expect(app.hasActiveDrag());
    try testing.expectEqualStrings("/tmp/b c.jpg", app.activeDrag(ExternalPaths).?.paths[1]);
    _ = tw.simulateInput(.{ .file_drop = .{ .pending = .{ .position = .{ .x = 150, .y = 150 } } } });
    _ = tw.simulateInput(.{ .file_drop = .{ .submit = .{ .position = .{ .x = 150, .y = 150 } } } });
    try testing.expect(!app.hasActiveDrag());
    const v = handle.rootView(app).?.read(app);
    try testing.expectEqual(@as(usize, 2), v.dropped.items.len);
    try testing.expectEqualStrings("/tmp/a.png", v.dropped.items[0]);
    // A drag that leaves never drops.
    _ = tw.simulateInput(.{ .file_drop = .{ .entered = .{ .position = .{ .x = 150, .y = 150 } , .paths = &paths } } });
    _ = tw.simulateInput(.{ .file_drop = .exited });
    try testing.expect(!app.hasActiveDrag());
    try testing.expectEqual(@as(usize, 2), handle.rootView(app).?.read(app).dropped.items.len);
}
