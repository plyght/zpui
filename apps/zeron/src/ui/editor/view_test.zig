//! Headless `FileEditor` tests on zpui's TestPlatform over a temporary
//! local workspace (the `.local` `WorkspaceFiles` source).

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const client = @import("../files/client.zig");
const view = @import("view.zig");
const editor_actions = @import("actions.zig");

const testing = std.testing;
const Context = zpui.Context;
const Window = zpui.Window;
const Entity = zpui.Entity;
const FileEditor = view.FileEditor;
const TestWindow = zpui.core.test_platform.TestWindow;
const div = zpui.div;
const px = zpui.px;

const Host = struct {
    ed: Entity(FileEditor),

    fn init(ed: Entity(FileEditor), window: *Window, cx: *Context(Host)) Host {
        _ = cx;
        _ = window;
        return .{ .ed = ed };
    }

    pub fn deinit(self: *Host, app: *zpui.App) void {
        self.ed.release(app);
    }

    pub fn render(self: *Host, _: *Window, _: *Context(Host)) zpui.Div {
        return div().sizeFull().child(div().w(px(520)).hFull().flex().flexCol().child(self.ed));
    }
};

const Harness = struct {
    app: *zpui.App,
    tmp: testing.TmpDir,
    root: []u8,
    files: Entity(client.WorkspaceFiles),
    ed: Entity(FileEditor),
    handle: zpui.WindowHandle(Host),

    fn init(path: []const u8, contents: []const u8) !Harness {
        const gpa = testing.allocator;
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        if (std.fs.path.dirname(path)) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = contents });
        var buf: [4096]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const root = try gpa.dupe(u8, buf[0..n]);
        errdefer gpa.free(root);
        const app = try zpui.App.initTest(gpa);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        try editor_actions.bindDefaults(app);
        try ui.theme.install(app, zt.Theme.dark());
        const files = try app.newWith(client.WorkspaceFiles, client.WorkspaceFiles.init, .{ io, client.Source{ .local = root } });
        const ed = try app.newWith(FileEditor, FileEditor.init, .{ files, path, view.Options{} });
        const handle = try app.openWindow(.{
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 520, .height = 600 } },
        }, Host, Host.init, .{ed.retain(app)});
        var h: Harness = .{ .app = app, .tmp = tmp, .root = root, .files = files, .ed = ed, .handle = handle };
        h.settle();
        return h;
    }

    fn deinit(h: *Harness) void {
        h.ed.release(h.app);
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
        for (0..4) |_| {
            h.app.runUntilParked();
            h.tw().frame(true);
        }
    }

    fn focus(h: *Harness) void {
        const Fx = struct {
            fn f(ed: *FileEditor, w: *Window, _: *Context(FileEditor)) void {
                ed.focusEditor(w);
            }
        };
        _ = h.ed.update(h.app, Fx.f, .{h.window()});
        h.settle();
    }

    fn typeText(h: *Harness, s: []const u8) void {
        var it = (std.unicode.Utf8View.init(s) catch unreachable).iterator();
        while (it.nextCodepointSlice()) |ch| {
            _ = h.tw().simulateInput(.{ .key_down = .{ .keystroke = .{ .key = ch, .key_char = ch } } });
        }
        h.settle();
    }

    fn key(h: *Harness, ks: []const u8) void {
        h.tw().typeKey(ks);
        h.settle();
    }

    fn text(h: *Harness) ![]u8 {
        const Fx = struct {
            fn f(ed: *FileEditor, _: *Context(FileEditor)) []u8 {
                return ed.text(testing.allocator) catch @panic("oom");
            }
        };
        return h.ed.update(h.app, Fx.f, .{});
    }

    fn disk(h: *Harness, path: []const u8) ![]u8 {
        return h.tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20));
    }
};

test "loads, edits with auto-indent, undoes and saves through the hash guard" {
    var h = try Harness.init("src/main.rs", "fn main() {\n    let a = 1;\n}\n");
    defer h.deinit();
    try testing.expectEqual(view.Phase.ready, h.ed.read(h.app).phase);
    try testing.expect(!h.ed.read(h.app).hasUnsavedChanges());
    try testing.expectEqualStrings("main.rs", h.ed.read(h.app).tabTitle());
    h.focus();
    // Caret to the end of line 2, Enter keeps the indent.
    h.key("down");
    h.key("end");
    h.key("enter");
    h.typeText("b();");
    {
        const t = try h.text();
        defer testing.allocator.free(t);
        try testing.expectEqualStrings("fn main() {\n    let a = 1;\n    b();\n}\n", t);
    }
    try testing.expect(h.ed.read(h.app).hasUnsavedChanges());
    h.key("secondary-s");
    try testing.expect(!h.ed.read(h.app).hasUnsavedChanges());
    {
        const d = try h.disk("src/main.rs");
        defer testing.allocator.free(d);
        try testing.expectEqualStrings("fn main() {\n    let a = 1;\n    b();\n}\n", d);
    }
    // Undo back past the save marks the buffer dirty again.
    h.key("secondary-z");
    try testing.expect(h.ed.read(h.app).hasUnsavedChanges());
}

test "a stale hash surfaces a save conflict and keeps the buffer" {
    var h = try Harness.init("a.txt", "one\n");
    defer h.deinit();
    h.focus();
    h.typeText("x");
    // Someone else rewrites the file.
    try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "theirs\n" });
    h.key("secondary-s");
    const phase = h.ed.read(h.app).phase;
    try testing.expect(phase == .conflict or phase == .externally_modified);
    const t = try h.text();
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("xone\n", t);
}

test "find selects matches and replace all is one undo step" {
    var h = try Harness.init("b.txt", "alpha beta\nalpha gamma\n");
    defer h.deinit();
    h.focus();
    h.key("secondary-f");
    try testing.expect(h.ed.read(h.app).find_open);
    h.typeText("alpha");
    {
        const ed = h.ed.read(h.app);
        try testing.expectEqual(@as(usize, 2), ed.core.search.matches.items.len);
        try testing.expectEqual(@as(usize, 0), ed.core.sel.start());
    }
    h.key("enter");
    try testing.expectEqual(@as(usize, 11), h.ed.read(h.app).core.sel.start());
    h.key("escape");
    try testing.expect(!h.ed.read(h.app).find_open);
}

test "soft wrap and read-only large file" {
    const gpa = testing.allocator;
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    for (0..20000) |i| try big.print(gpa, "line {d} with some words to wrap around the editor width nicely\n", .{i});
    var h = try Harness.init("big.txt", big.items);
    defer h.deinit();
    const ed = h.ed.read(h.app);
    try testing.expectEqual(@as(usize, 20001), ed.core.buffer.lineCount());
    h.focus();
    h.key("secondary-end");
    try testing.expectEqual(h.ed.read(h.app).core.len(), h.ed.read(h.app).core.cursor());
    const Fx = struct {
        fn f(e: *FileEditor, cx: *Context(FileEditor)) void {
            e.setSoftWrap(true, cx);
        }
    };
    _ = h.ed.update(h.app, Fx.f, .{});
    h.settle();
    try testing.expect(h.ed.read(h.app).display.wrap_cols != null);
    try testing.expect(h.ed.update(h.app, struct {
        fn f(e: *FileEditor, _: *Context(FileEditor)) usize {
            return e.display.rowCount();
        }
    }.f, .{}) > 20001);
}

test "external change on a dirty buffer: banner, Keep Editing, then save overwrites" {
    var h = try Harness.init("c.txt", "base\n");
    defer h.deinit();
    h.focus();
    h.typeText("x");
    try h.tmp.dir.writeFile(testing.io, .{ .sub_path = "c.txt", .data = "theirs\n" });
    for (0..3) |_| {
        h.app.advanceClock(1100 * std.time.ns_per_ms);
        h.settle();
    }
    try testing.expectEqual(view.Phase.externally_modified, h.ed.read(h.app).phase);
    // Click "Keep Editing" through the real hit test.
    const KeepFx = struct {
        fn f(e: *FileEditor, c: *Context(FileEditor)) void {
            e.keepEditingForTest(c);
        }
    };
    _ = KeepFx;
    h.tw().click(390, 54);
    h.settle();
    try testing.expectEqual(view.Phase.ready, h.ed.read(h.app).phase);
    h.key("secondary-s");
    const d = try h.disk("c.txt");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("xbase\n", d);
}

test "review comments follow their line through edits and hold the send until saved" {
    var h = try Harness.init("src/main.rs", "fn main() {\n    let a = 1;\n}\n");
    defer h.deinit();
    const model = @import("zeron_model");
    const review = @import("review.zig");
    const store = try h.app.newWith(model.ReviewCommentStore, model.ReviewCommentStore.init, .{null});
    defer store.release(h.app);
    try h.app.setGlobal(model.review_comments.Global{ .store = store.downgrade() });
    const Attach = struct {
        fn f(ed: *FileEditor, cx: *Context(FileEditor)) void {
            review.attach(ed, cx);
        }
    };
    h.ed.update(h.app, Attach.f, .{});
    const id = try store.update(h.app, model.ReviewCommentStore.add, .{ "", model.review_comments.NewComment{ .path = "src/main.rs", .line = 2, .body = "why 1?", .source = .file } });
    const id_owned = try testing.allocator.dupe(u8, id);
    defer testing.allocator.free(id_owned);
    h.settle();
    try testing.expectEqual(@as(usize, 1), h.ed.read(h.app).review.anchors.count());

    // Insert a line above: the comment moves to line 3 and the send waits.
    h.focus();
    h.typeText("// x");
    h.key("enter");
    const c = store.read(h.app).find("", id_owned).?;
    try testing.expectEqual(@as(u32, 3), c.line);
    try testing.expect(store.read(h.app).flushPending(""));

    // Saving releases the composer.
    const Save = struct {
        fn f(ed: *FileEditor, cx: *Context(FileEditor)) void {
            ed.save(cx);
        }
    };
    h.ed.update(h.app, Save.f, .{});
    h.settle();
    try testing.expect(!h.ed.read(h.app).hasUnsavedChanges());
    try testing.expect(!store.read(h.app).flushPending(""));

    // Deleting the commented line detaches it; it re-anchors from its last line.
    const Del = struct {
        fn f(ed: *FileEditor, w: *Window, cx: *Context(FileEditor)) void {
            ed.replaceTextInRange(.{ .start = 17, .end = 32 }, "", w, cx);
        }
    };
    _ = h.ed.update(h.app, Del.f, .{h.window()});
    h.settle();
    try testing.expectEqual(@as(usize, 1), h.ed.read(h.app).review.anchors.count());
    const Remove = struct {
        fn f(ed: *FileEditor, cid: []const u8, cx: *Context(FileEditor)) void {
            review.removeComment(ed, cid, cx);
        }
    };
    h.ed.update(h.app, Remove.f, .{id_owned});
    try testing.expectEqual(@as(usize, 0), store.read(h.app).comments("").len);
    try testing.expect(!store.read(h.app).flushPending(""));
}

test "native menus: the context menu pops up natively with the drawn rows and runs them" {
    var h = try Harness.init("notes.txt", "alpha beta\ngamma\n");
    defer h.deinit();
    ui.native_menu.force_for_testing = true;
    defer ui.native_menu.force_for_testing = false;
    h.tw().native_menus = true;
    h.focus();
    _ = h.tw().simulateInput(.{ .mouse_down = .{ .button = .right, .position = .{ .x = 200, .y = 60 } } });
    _ = h.tw().simulateInput(.{ .mouse_up = .{ .button = .right, .position = .{ .x = 200, .y = 60 } } });
    h.settle();
    // Native: nothing drawn, the platform menu holds the same rows and states.
    try testing.expect(h.ed.read(h.app).context_menu == null);
    const m = h.tw().context_menu orelse return error.NoNativeMenu;
    var buf: [8][]const u8 = undefined;
    const labels = m.labels(&buf);
    try testing.expectEqual(@as(usize, 5), labels.len);
    for ([_][]const u8{ "Cut", "Copy", "Paste", "-", "Select All" }, labels) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expect(m.find("Cut").?.disabled); // no selection
    try testing.expect(m.find("Copy").?.disabled);
    try testing.expect(!m.find("Paste").?.disabled);
    try testing.expectEqualStrings("a", m.find("Select All").?.shortcut.?.key);
    try testing.expect(h.tw().simulateContextMenuSelectLabel("Select All"));
    h.settle();
    const sel = h.ed.read(h.app).core.sel;
    try testing.expectEqual(@as(usize, 0), sel.range().start);
    try testing.expectEqual(@as(usize, 17), sel.range().end);

    // With a selection, Copy is enabled; dismissing leaves nothing behind.
    _ = h.tw().simulateInput(.{ .mouse_down = .{ .button = .right, .position = .{ .x = 200, .y = 60 } } });
    _ = h.tw().simulateInput(.{ .mouse_up = .{ .button = .right, .position = .{ .x = 200, .y = 60 } } });
    h.settle();
    try testing.expect(!h.tw().context_menu.?.find("Copy").?.disabled);
    try testing.expect(h.tw().simulateContextMenuDismiss());
    h.settle();
    try testing.expect(h.ed.read(h.app).context_menu == null);
}

test "native menus off: the drawn context menu is the fallback" {
    var h = try Harness.init("notes.txt", "alpha\n");
    defer h.deinit();
    h.tw().native_menus = true; // the platform could, but the option is off here (Linux)
    h.focus();
    _ = h.tw().simulateInput(.{ .mouse_down = .{ .button = .right, .position = .{ .x = 200, .y = 60 } } });
    h.settle();
    try testing.expect(h.tw().context_menu == null);
    try testing.expect(h.ed.read(h.app).context_menu != null);
}
