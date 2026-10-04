//! Headless `FilesPanel` tests on zpui's TestPlatform over a temporary local
//! workspace.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const client = @import("client.zig");
const panel_mod = @import("panel.zig");
const editor_actions = @import("../editor/actions.zig");

const testing = std.testing;
const Context = zpui.Context;
const Window = zpui.Window;
const Entity = zpui.Entity;
const FilesPanel = panel_mod.FilesPanel;
const TestWindow = zpui.core.test_platform.TestWindow;
const div = zpui.div;
const px = zpui.px;

const Recorder = struct {
    opened: std.ArrayList([]u8) = .empty,
    renamed: usize = 0,
    deleted: usize = 0,
    subs: zpui.Subscriptions = .{},

    pub fn deinit(self: *Recorder, _: *zpui.App) void {
        for (self.opened.items) |p| testing.allocator.free(p);
        self.opened.deinit(testing.allocator);
        self.subs.deinit(testing.allocator);
    }

    fn onOpen(self: *Recorder, _: Entity(FilesPanel), ev: *const panel_mod.OpenFile, _: *Context(Recorder)) void {
        self.opened.append(testing.allocator, testing.allocator.dupe(u8, ev.path) catch return) catch {};
    }
    fn onRenamed(self: *Recorder, _: Entity(FilesPanel), _: *const panel_mod.EntryRenamed, _: *Context(Recorder)) void {
        self.renamed += 1;
    }
    fn onDeleted(self: *Recorder, _: Entity(FilesPanel), _: *const panel_mod.EntryDeleted, _: *Context(Recorder)) void {
        self.deleted += 1;
    }
};

const Host = struct {
    panel: Entity(FilesPanel),

    fn init(panel: Entity(FilesPanel), _: *Window, _: *Context(Host)) Host {
        return .{ .panel = panel };
    }

    pub fn deinit(self: *Host, app: *zpui.App) void {
        self.panel.release(app);
    }

    pub fn render(self: *Host, _: *Window, _: *Context(Host)) zpui.Div {
        return div().sizeFull().child(div().w(px(286)).hFull().flex().flexCol().child(self.panel));
    }
};

const Harness = struct {
    app: *zpui.App,
    tmp: testing.TmpDir,
    root: []u8,
    files: Entity(client.WorkspaceFiles),
    panel: Entity(FilesPanel),
    rec: Entity(Recorder),
    handle: zpui.WindowHandle(Host),

    fn init() !Harness {
        const gpa = testing.allocator;
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "src");
        try tmp.dir.createDirPath(io, "docs");
        try tmp.dir.writeFile(io, .{ .sub_path = "src/main.rs", .data = "fn main() {}\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "src/stream.rs", .data = "pub struct Pipeline;\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "docs/architecture.md", .data = "# Arch\n" });
        try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "# hi\n" });
        var buf: [4096]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const root = try gpa.dupe(u8, buf[0..n]);
        errdefer gpa.free(root);
        const app = try zpui.App.initTest(gpa);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        try editor_actions.bindDefaults(app);
        try ui.theme.install(app, zt.Theme.light());
        const files = try app.newWith(client.WorkspaceFiles, client.WorkspaceFiles.init, .{ io, client.Source{ .local = root } });
        const panel = try app.newWith(FilesPanel, FilesPanel.init, .{ files, panel_mod.Options{} });
        const rec = try app.new(Recorder, .{});
        {
            var l = rec.lease(app);
            defer l.end();
            try l.value.subs.add(gpa, try l.cx.subscribe(panel, Recorder.onOpen));
            try l.value.subs.add(gpa, try l.cx.subscribe(panel, Recorder.onRenamed));
            try l.value.subs.add(gpa, try l.cx.subscribe(panel, Recorder.onDeleted));
        }
        const handle = try app.openWindow(.{
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 286, .height = 900 } },
        }, Host, Host.init, .{panel.retain(app)});
        var h: Harness = .{ .app = app, .tmp = tmp, .root = root, .files = files, .panel = panel, .rec = rec, .handle = handle };
        h.settle();
        return h;
    }

    fn deinit(h: *Harness) void {
        h.rec.release(h.app);
        h.panel.release(h.app);
        h.files.release(h.app);
        h.app.deinit();
        testing.allocator.free(h.root);
        h.tmp.cleanup();
    }

    fn window(h: *Harness) *Window {
        return h.handle.window(h.app).?;
    }

    fn tw(h: *Harness) *TestWindow {
        return TestWindow.of(h.window().platform_window);
    }

    fn settle(h: *Harness) void {
        for (0..5) |_| {
            h.app.runUntilParked();
            h.tw().frame(true);
        }
    }

    fn key(h: *Harness, ks: []const u8) void {
        h.tw().typeKey(ks);
        h.settle();
    }

    fn rowPaths(h: *Harness, a: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (h.panel.read(h.app).tree.rows()) |r| {
            try out.appendSlice(a, r.path);
            try out.append(a, ' ');
        }
        return out.items;
    }
};

test "loads the root, expands with the keyboard and opens a file" {
    var h = try Harness.init();
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("docs src README.md ", try h.rowPaths(arena.allocator()));
    const Fx = struct {
        fn f(p: *FilesPanel, w: *Window, _: *Context(FilesPanel)) void {
            p.focusTree(w);
        }
    };
    _ = h.panel.update(h.app, Fx.f, .{h.window()});
    h.settle();
    h.key("down"); // docs
    h.key("down"); // src
    h.key("right"); // expand
    try testing.expectEqualStrings("docs src src/main.rs src/stream.rs README.md ", try h.rowPaths(arena.allocator()));
    h.key("right"); // first child
    h.key("down");
    h.key("enter");
    try testing.expectEqual(@as(usize, 1), h.rec.read(h.app).opened.items.len);
    try testing.expectEqualStrings("src/stream.rs", h.rec.read(h.app).opened.items[0]);
}

test "fuzzy search finds files and the eye toggle reloads" {
    var h = try Harness.init();
    defer h.deinit();
    const Fx = struct {
        fn f(p: *FilesPanel, w: *Window, c: *Context(FilesPanel)) void {
            w.focus(p.search.read(c).focusHandle());
        }
    };
    _ = h.panel.update(h.app, Fx.f, .{h.window()});
    h.settle();
    for ("strm") |ch| _ = h.tw().simulateInput(.{ .key_down = .{ .keystroke = .{ .key = &.{ch}, .key_char = &.{ch} } } });
    h.settle();
    h.app.advanceClock(200 * std.time.ns_per_ms);
    h.settle();
    const rows = h.panel.read(h.app).search_tree.rows.items;
    try testing.expect(rows.len >= 2);
    try testing.expectEqualStrings("src", rows[0].path);
    try testing.expectEqualStrings("src/stream.rs", rows[1].path);
    h.key("down");
    h.key("enter");
    try testing.expectEqual(@as(usize, 1), h.rec.read(h.app).opened.items.len);
    // The search cleared and the tree selected the revealed file.
    try testing.expectEqual(@as(usize, 0), h.panel.read(h.app).query.items.len);
    try testing.expectEqualStrings("src/stream.rs", h.panel.read(h.app).tree.selected.?);
}

test "rename and delete through the local backend" {
    var h = try Harness.init();
    defer h.deinit();
    const Rn = struct {
        fn f(p: *FilesPanel, w: *Window, c: *Context(FilesPanel)) void {
            p.beginRename("README.md", w, c);
        }
    };
    _ = h.panel.update(h.app, Rn.f, .{h.window()});
    h.settle();
    try testing.expect(h.panel.read(h.app).rename != null);
    // Replace the stem selection with a new name.
    for ("NOTES") |ch| _ = h.tw().simulateInput(.{ .key_down = .{ .keystroke = .{ .key = &.{ch}, .key_char = &.{ch} } } });
    h.settle();
    h.key("enter");
    try testing.expectEqual(@as(usize, 1), h.rec.read(h.app).renamed);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("docs src NOTES.md ", try h.rowPaths(arena.allocator()));
    const Del = struct {
        fn f(p: *FilesPanel, c: *Context(FilesPanel)) void {
            p.beginDelete("docs", c);
        }
    };
    _ = h.panel.update(h.app, Del.f, .{});
    h.settle();
    try testing.expect(h.panel.read(h.app).delete_flow != null);
    const Confirm = struct {
        fn f(p: *FilesPanel, c: *Context(FilesPanel)) void {
            p.dismissDelete(true, c);
        }
    };
    _ = h.panel.update(h.app, Confirm.f, .{});
    h.settle();
    try testing.expectEqual(@as(usize, 1), h.rec.read(h.app).deleted);
    try testing.expectEqualStrings("src NOTES.md ", try h.rowPaths(arena.allocator()));
}
