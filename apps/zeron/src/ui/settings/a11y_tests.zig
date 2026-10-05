//! Accessibility tree of the real shell + settings on the TestPlatform: the shared
//! components (buttons, switches, inputs, dialogs) and the settings navigation expose
//! the roles and names zeron's Rust UI gives them (`.role()` / `.aria_label()`).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const prefs_mod = @import("../shell/prefs.zig");
const fixtures_mod = @import("../shell/fixtures.zig");
const shell_mod = @import("../shell/shell.zig");
const store = @import("store.zig");
const view_mod = @import("view.zig");

const testing = std.testing;
const a11y = zpui.a11y;
const TestWindow = zpui.core.test_platform.TestWindow;
const mod = if (builtin.os.tag == .macos) "cmd" else "ctrl";

const Harness = struct {
    app: *zpui.App,
    fixtures: *fixtures_mod.Fixtures,
    state: zpui.Entity(model.AppState),
    handle: zpui.WindowHandle(shell_mod.Shell),

    fn init() !Harness {
        const gpa = testing.allocator;
        const io = std.testing.io;
        const app = try zpui.App.initTest(gpa);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        const f = try fixtures_mod.load(gpa, io, "apps/zeron/fixtures/reference");
        var prefs: prefs_mod.Prefs = .{ .gpa = gpa };
        fixtures_mod.applyPrefs(f, &prefs);
        try ui.theme.install(app, zt.Theme.dark());
        try prefs_mod.install(app, prefs);
        store.boot(app, io, .dark);
        const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false, .wake_mode = .poll } });
        fixtures_mod.applyToState(f, io, app, state);
        const handle = try app.openWindow(.{
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1600, .height = 1000 } },
        }, shell_mod.Shell, shell_mod.Shell.init, .{ state, f, true });
        return .{ .app = app, .fixtures = f, .state = state, .handle = handle };
    }

    fn deinit(h: *Harness) void {
        h.state.release(h.app);
        h.app.deinit();
        h.fixtures.deinit();
        testing.allocator.destroy(h.fixtures);
    }

    fn tw(h: *Harness) *TestWindow {
        return TestWindow.of(h.handle.window(h.app).?.platform_window);
    }

    fn tree(h: *Harness) *const a11y.Tree {
        return h.handle.window(h.app).?.a11yTree();
    }

    /// Turn accessibility on and draw a frame.
    fn activate(h: *Harness) void {
        h.tw().simulateA11yActivation(true);
        h.tw().frame(false);
        h.app.runUntilParked();
    }

    fn settings(h: *Harness) *const model.UiSettings {
        return store.current(h.app);
    }

    fn redraw(h: *Harness) void {
        h.app.runUntilParked();
        h.tw().frame(false);
    }
};

fn find(t: *const a11y.Tree, role: a11y.Role, name: []const u8) ?*const a11y.Node {
    for (t.nodes.items) |*n| {
        if (n.role != role) continue;
        const got = t.name(n) orelse continue;
        if (std.mem.eql(u8, got, name)) return n;
    }
    return null;
}

fn expectNode(t: *const a11y.Tree, role: a11y.Role, name: []const u8) !*const a11y.Node {
    return find(t, role, name) orelse {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        t.dump(&out.writer) catch {};
        std.debug.print("no {t} \"{s}\" in tree:\n{s}\n", .{ role, name, out.written() });
        return error.MissingNode;
    };
}

fn openSection(v: *view_mod.SettingsView, section: view_mod.Section, cx: *zpui.Context(view_mod.SettingsView)) void {
    v.openSection(section, cx);
}

test "settings: navigation tabs, back button and named switches" {
    var h = try Harness.init();
    defer h.deinit();
    h.tw().typeKey(mod ++ "-,");
    h.app.runUntilParked();
    const v = h.handle.rootView(h.app).?.read(h.app).settings_view.?;
    v.update(h.app, openSection, .{.general});
    h.activate();
    const t = h.tree();

    _ = try expectNode(t, .group, "Settings");
    _ = try expectNode(t, .tab_list, "Settings sections");
    const general = try expectNode(t, .tab, view_mod.sectionLabel(.general));
    try testing.expect(general.selected.?);
    try testing.expect(!(try expectNode(t, .tab, view_mod.sectionLabel(.appearance))).selected.?);
    const back = try expectNode(t, .button, "Back");
    try testing.expect(back.actions.contains(.click));

    // General page switches carry zeron's labels and their state.
    const compact = try expectNode(t, .@"switch", "Compact mode");
    try testing.expectEqual(if (h.settings().transcriptCompactMode) a11y.Toggled.on else a11y.Toggled.off, compact.toggled.?);

    // Pressing the switch through assistive technology flips the setting.
    const before = h.settings().transcriptCompactMode;
    h.tw().simulateA11yAction(.{ .target = compact.id, .action = .click });
    h.redraw();
    try testing.expectEqual(!before, h.settings().transcriptCompactMode);
    const after = try expectNode(h.tree(), .@"switch", "Compact mode");
    try testing.expectEqual(if (!before) a11y.Toggled.on else a11y.Toggled.off, after.toggled.?);

    // Switching sections moves the selected tab.
    h.tw().simulateA11yAction(.{ .target = (try expectNode(h.tree(), .tab, view_mod.sectionLabel(.files))).id, .action = .click });
    h.redraw();
    try testing.expect((try expectNode(h.tree(), .tab, view_mod.sectionLabel(.files))).selected.?);
    _ = try expectNode(h.tree(), .@"switch", "Word wrap");
}

test "shell: titlebar controls are named buttons" {
    var h = try Harness.init();
    defer h.deinit();
    h.activate();
    const t = h.tree();
    var buttons: usize = 0;
    var named: usize = 0;
    for (t.nodes.items) |*n| if (n.role == .button) {
        buttons += 1;
        if (t.name(n) != null) named += 1;
    };
    try testing.expect(buttons > 0);
    try testing.expectEqual(buttons, named);
}

/// Every interactive element (click listener or tab-stop focus handle) must be a node
/// with a role, and every interactive node must have a name. Prints all offenders and
/// returns their number.
fn audit(t: *const a11y.Tree, what: []const u8) usize {
    var bad: usize = 0;
    for (t.unroled.items) |u| {
        bad += 1;
        const parent = t.at(u.parent);
        std.debug.print("[{s}] no role: element \"{s}\" ({s}{s}) at {d:.0},{d:.0} {d:.0}x{d:.0} in {t} \"{s}\"\n", .{
            what,                              t.str(u.element) orelse "",
            if (u.clickable) "click " else "", if (u.focusable) "focus" else "",
            u.bounds.origin.x,                 u.bounds.origin.y,
            u.bounds.size.width,               u.bounds.size.height,
            parent.role,                       t.name(parent) orelse "",
        });
    }
    for (t.nodes.items, 0..) |*n, ix| {
        if (ix == 0 or n.synthetic) continue;
        const interactive = n.actions.contains(.click) or n.isFocusable();
        if (!interactive) continue;
        if (t.name(n)) |nm| if (std.mem.trim(u8, nm, " ").len > 0) continue;
        bad += 1;
        const parent = if (t.parentOf(@intCast(ix))) |p| t.at(p) else t.at(0);
        std.debug.print("[{s}] no name: {t} at {d:.0},{d:.0} {d:.0}x{d:.0} in {t} \"{s}\"\n", .{ what, n.role, n.bounds.origin.x, n.bounds.origin.y, n.bounds.size.width, n.bounds.size.height, parent.role, t.name(parent) orelse "" });
    }
    return bad;
}

/// A node whose name starts with `prefix`.
fn findPrefix(t: *const a11y.Tree, role: a11y.Role, prefix: []const u8) ?*const a11y.Node {
    for (t.nodes.items) |*n| {
        if (n.role != role) continue;
        const got = t.name(n) orelse continue;
        if (std.mem.startsWith(u8, got, prefix)) return n;
    }
    return null;
}

const Audit = struct {
    h: *Harness,
    bad: usize = 0,
    states: usize = 0,

    /// Redraw from scratch (no cached views) and audit the tree.
    fn check(self: *Audit, what: []const u8) void {
        const tw = self.h.tw();
        self.h.app.runUntilParked();
        tw.simulateA11yActivation(false);
        tw.frame(false);
        tw.simulateA11yActivation(true);
        tw.frame(false);
        self.h.app.runUntilParked();
        self.bad += audit(self.h.tree(), what);
        self.states += 1;
    }

    /// Press the node `role` named `prefix…` through assistive technology.
    fn press(self: *Audit, role: a11y.Role, prefix: []const u8) !void {
        const n = findPrefix(self.h.tree(), role, prefix) orelse {
            var out: std.Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            self.h.tree().dump(&out.writer) catch {};
            std.debug.print("no {t} \"{s}…\" in tree:\n{s}\n", .{ role, prefix, out.written() });
            return error.MissingNode;
        };
        self.h.tw().simulateA11yAction(.{ .target = n.id, .action = .click });
        self.h.redraw();
    }

    fn key(self: *Audit, k: []const u8) void {
        self.h.tw().typeKey(k);
        self.h.app.advanceClock(400 * std.time.ns_per_ms);
        self.h.redraw();
    }
};

test "audit: every interactive element of the shell has a role and a name" {
    var h = try Harness.init();
    defer h.deinit();
    h.activate();
    var a: Audit = .{ .h = &h };
    a.check("shell");

    // Sidebar menus.
    try a.press(.button, "Account menu");
    a.check("user menu");
    a.key("escape");
    try a.press(.button, "Account menu");
    try a.press(.button, "Sidebar view options");
    a.check("view options");
    try a.press(.button, "Sidebar view options");
    try a.press(.button, "All projects");
    a.check("spaces menu");
    try a.press(.button, "All projects");
    _ = h.tw().simulateInput(.{ .mouse_down = .{ .button = .right, .position = .{ .x = 120, .y = 129 }, .click_count = 1 } });
    _ = h.tw().simulateInput(.{ .mouse_up = .{ .button = .right, .position = .{ .x = 120, .y = 129 }, .click_count = 1 } });
    h.redraw();
    a.check("chat context menu");
    a.key("escape");

    // Composer model picker.
    try a.press(.button, "Model:");
    a.check("model picker");
    a.key("escape");

    // Right pane: launcher, surfaces and the + menu.
    a.key(mod ++ "-r");
    a.check("right pane launcher");
    h.tw().click(1340, 544);
    h.redraw();
    a.check("right pane diffs");
    h.tw().click(1215, 20);
    h.redraw();
    a.check("right pane + menu");
    h.tw().click(1260, 204);
    h.redraw();
    a.check("right pane history");
    a.key(mod ++ "-e");
    a.check("files");
    a.key(mod ++ "-r");

    // Command palette.
    a.key(mod ++ "-k");
    a.check("command palette");
    a.key("escape");

    // New session page.
    a.key(mod ++ "-n");
    a.check("new session");

    // Settings, every section. Close anything the coordinate clicks above may have left
    // open first (layout, and so what a fixed point hits, depends on the installed fonts).
    a.key("escape");
    a.key("escape");
    a.key(mod ++ "-,");
    const v = h.handle.rootView(h.app).?.read(h.app).settings_view orelse {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        h.tree().dump(&out.writer) catch {};
        std.debug.print("settings did not open on {s}-,; tree:\n{s}\n", .{ mod, out.written() });
        return error.SettingsDidNotOpen;
    };
    inline for (@typeInfo(view_mod.Section).@"enum".field_names) |name| {
        v.update(h.app, openSection, .{@field(view_mod.Section, name)});
        a.check("settings " ++ name);
    }

    // Settings dialogs and expanded rows.
    v.update(h.app, openSection, .{.appearance});
    h.redraw();
    try a.press(.button, "Add theme");
    a.check("theme import dialog");

    if (a.bad > 0) {
        std.debug.print("{d} accessibility offenders in {d} states\n", .{ a.bad, a.states });
        return error.A11yAudit;
    }
}
