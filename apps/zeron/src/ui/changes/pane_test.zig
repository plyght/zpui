//! Headless Changes / History pane tests: the real panes rendered on zpui's
//! TestPlatform from checked-in fixtures (no engine).

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const fixtures_mod = @import("../shell/fixtures.zig");
const changes = @import("root.zig");
const history = @import("../history/root.zig");

const testing = std.testing;
const Context = zpui.Context;
const Window = zpui.Window;

const Host = struct {
    cp: ?zpui.Entity(changes.ChangesPane) = null,
    hp: ?zpui.Entity(history.HistoryPane) = null,

    fn init(cp: ?zpui.Entity(changes.ChangesPane), hp: ?zpui.Entity(history.HistoryPane), _: *Window, _: *Context(Host)) Host {
        return .{ .cp = cp, .hp = hp };
    }

    pub fn deinit(self: *Host, app: *zpui.App) void {
        if (self.cp) |p| p.release(app);
        if (self.hp) |p| p.release(app);
    }

    pub fn render(self: *Host, _: *Window, _: *Context(Host)) zpui.Div {
        var d = div().sizeFull().flex().flexRow();
        if (self.cp) |p| d = d.child(div().w(px(520)).hFull().child(p));
        if (self.hp) |p| d = d.child(div().w(px(520)).hFull().child(p));
        return d;
    }
};

const div = zpui.div;
const px = zpui.px;

const Harness = struct {
    app: *zpui.App,
    fixtures: *fixtures_mod.Fixtures,
    state: zpui.Entity(model.AppState),
    cp: zpui.Entity(changes.ChangesPane),
    hp: zpui.Entity(history.HistoryPane),
    handle: zpui.WindowHandle(Host),

    fn init() !Harness {
        const gpa = testing.allocator;
        const io = std.testing.io;
        const app = try zpui.App.initTest(gpa);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        try model.settings_store.initMemory(app, io);
        try ui.theme.install(app, zt.Theme.light());
        const f = try fixtures_mod.load(gpa, io, "apps/zeron/fixtures/reference");
        const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false, .wake_mode = .poll } });
        f.meta.selectedChat = "75fdc758-a8d5-58bb-a89d-9d5ac5e98425";
        fixtures_mod.applyToState(f, io, app, state);
        const cp = try app.newWith(changes.ChangesPane, changes.ChangesPane.init, .{state});
        const diffs = try std.Io.Dir.cwd().readFileAlloc(io, "apps/zeron/src/ui/changes/testdata/checkout-diffs.json", gpa, .limited(1 << 20));
        defer gpa.free(diffs);
        changes.ChangesStore.applyFixture(cp.read(app).store, app, diffs);
        const hp = try app.newWith(history.HistoryPane, history.HistoryPane.init, .{state});
        const hist = try std.Io.Dir.cwd().readFileAlloc(io, "apps/zeron/src/ui/history/testdata/branchy-history.json", gpa, .limited(1 << 20));
        defer gpa.free(hist);
        history.HistoryStore.applyFixture(hp.read(app).store, app, "local|/x", hist);
        const handle = try app.openWindow(.{
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1040, .height = 800 } },
        }, Host, Host.init, .{ cp.retain(app), hp.retain(app) });
        return .{ .app = app, .fixtures = f, .state = state, .cp = cp, .hp = hp, .handle = handle };
    }

    fn deinit(h: *Harness) void {
        h.cp.release(h.app);
        h.hp.release(h.app);
        h.state.release(h.app);
        h.app.deinit();
        h.fixtures.deinit();
        testing.allocator.destroy(h.fixtures);
    }

    fn window(h: *Harness) *zpui.Window {
        return h.handle.window(h.app).?;
    }

    fn redraw(h: *Harness) void {
        h.window().refresh();
        h.app.runUntilParked();
    }
};

test "changes pane renders the working tree diff and folds files" {
    var h = try Harness.init();
    defer h.deinit();
    h.redraw();
    const p = h.cp.read(h.app);
    try testing.expect(p.parsed != null);
    try testing.expectEqual(@as(usize, 3), p.parsed.?.ps.files.len);
    try testing.expectEqual(@as(u32, 14), p.parsed.?.additions);
    const full_rows = p.flat.rows.items.len;
    try testing.expect(h.window().rendered_frame.scene.monochrome_sprites.items.len > 100);

    // Collapse all → one header row per file; again → everything back.
    h.cp.update(h.app, changes.ChangesPane.toggleCollapseAll, .{});
    try testing.expectEqual(@as(usize, 3), h.cp.read(h.app).flat.rows.items.len);
    h.cp.update(h.app, changes.ChangesPane.toggleCollapseAll, .{});
    try testing.expectEqual(full_rows, h.cp.read(h.app).flat.rows.items.len);

    // A single fold swaps the body for the tween stand-in, then settles.
    h.cp.update(h.app, changes.ChangesPane.toggleFold, .{0});
    try testing.expect(h.cp.read(h.app).flat.rows.items[1] == .folding_body);
    h.redraw();
    h.app.advanceClock(500 * std.time.ns_per_ms);
    h.redraw();
    const after = h.cp.read(h.app);
    try testing.expect(after.flat.rows.items[1] == .file_header);
    try testing.expect(after.foldOf(0).collapsed);

    // Split layout pairs rows (never more rows than unified).
    h.cp.update(h.app, changes.ChangesPane.toggleMode, .{});
    h.redraw();
    try testing.expect(h.cp.read(h.app).mode == .split);
    try testing.expect(h.cp.read(h.app).flat.rows.items.len <= full_rows);
    h.cp.update(h.app, changes.ChangesPane.toggleWrap, .{});
    h.redraw();
    try testing.expect(h.cp.read(h.app).wrap_lines);
}

test "nowrap code rows share one horizontal scroll plane per file" {
    var h = try Harness.init();
    defer h.deinit();
    h.redraw();
    const tw = zpui.core.test_platform.TestWindow.of(h.window().platform_window);
    // Over stream.rs's first code line (toolbar 38 + strip 38 + headers…).
    const y: f32 = 38 + 38 + 38 + 28 + 21 * 7 + 38 + 28 + 10;
    tw.moveMouse(300, y);
    _ = tw.simulateInput(.{ .scroll_wheel = .{ .position = .{ .x = 300, .y = y }, .delta = .{ .pixels = .{ .x = -60, .y = 0 } } } });
    h.redraw();
    const p = h.cp.read(h.app);
    const off = p.parsed.?.scroll[1].offset().x;
    try testing.expect(off < 0);
    // A vertical wheel never moves the code plane (restricted axis).
    _ = tw.simulateInput(.{ .scroll_wheel = .{ .position = .{ .x = 300, .y = y }, .delta = .{ .pixels = .{ .x = 0, .y = -40 } } } });
    h.redraw();
    try testing.expectEqual(off, h.cp.read(h.app).parsed.?.scroll[1].offset().x);
}

test "changes pane discard confirmation and scopes" {
    var h = try Harness.init();
    defer h.deinit();
    h.redraw();
    h.cp.update(h.app, changes.ChangesPane.openDiscard, .{});
    try testing.expect(h.cp.read(h.app).discard != null);
    h.redraw();
    // Branch scope without an engine: no capture yet → the preparing state.
    h.cp.update(h.app, changes.ChangesPane.setScope, .{changes.DiffScope.branch});
    h.redraw();
    try testing.expect(h.cp.read(h.app).parsed == null);
    try testing.expectEqualStrings("Branch changes", h.cp.read(h.app).tabTitle());
}

test "history pane lays out lanes and emits OpenCommit" {
    var h = try Harness.init();
    defer h.deinit();
    h.redraw();
    const p = h.hp.read(h.app);
    try testing.expectEqual(@as(usize, 17), p.visible.len);
    try testing.expect(p.layout.max_lane_count >= 3);
    try testing.expect(h.window().rendered_frame.scene.paths.items.len > 0);

    const Sink = struct {
        var opened: ?[]const u8 = null;
        fn on(_: void, _: zpui.Entity(history.HistoryPane), ev: *const history.OpenCommit, _: *zpui.App) void {
            opened = ev.subject;
        }
    };
    var sub = try h.app.subscribe(h.hp, {}, Sink.on);
    defer sub.deinit();
    const tw = zpui.core.test_platform.TestWindow.of(h.window().platform_window);
    // Header 38 + column header 24 + first row center (18) in the right half.
    tw.click(520 + 200, 38 + 24 + 18);
    h.app.runUntilParked();
    try testing.expect(Sink.opened != null);
    try testing.expect(std.mem.startsWith(u8, Sink.opened.?, "Merge branch"));

    // Branch tips view: only commits with refs.
    var l = h.hp.lease(h.app);
    l.value.view_mode = .branch_tips;
    l.cx.notify();
    l.end();
    h.redraw();
    try testing.expectEqual(@as(usize, 5), h.hp.read(h.app).visible.len);
}

test "commit pane: identity toolbar and tab title" {
    var h = try Harness.init();
    defer h.deinit();
    const pane = try h.app.newWith(changes.ChangesPane, changes.ChangesPane.initCommit, .{ h.state, changes.CommitPin{ .sha = "f5618ff7f1ff8c2accf7e282cbcffc5870f45e17", .subject = "Bump retry default" } });
    defer pane.release(h.app);
    try testing.expectEqualStrings("Bump retry default", pane.read(h.app).tabTitle());
    try testing.expect(pane.read(h.app).scope == .commit);
    const empty = try h.app.newWith(changes.ChangesPane, changes.ChangesPane.initCommit, .{ h.state, changes.CommitPin{ .sha = "abcdef0123", .subject = "  " } });
    defer empty.release(h.app);
    try testing.expectEqualStrings("abcdef0", empty.read(h.app).tabTitle());
}
