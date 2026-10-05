//! Settings → General → New threads, end to end through the real Shell
//! (TestPlatform, reference fixtures, in-memory stores): the Default agent /
//! Default model selects feed the composer's new-thread resolution, existing
//! threads keep their own config, and a disabled default agent falls back.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const prefs_mod = @import("../shell/prefs.zig");
const fixtures_mod = @import("../shell/fixtures.zig");
const shell_mod = @import("../shell/shell.zig");
const store = @import("store.zig");
const select = @import("select.zig");
const view_mod = @import("view.zig");
const ntd = @import("new_thread_defaults.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestWindow = zpui.core.test_platform.TestWindow;
const SettingsView = view_mod.SettingsView;
const HarnessId = engine.protocol.HarnessId;
const composer_store = model.composer_store;
const mod = if (builtin.os.tag == .macos) "cmd" else "ctrl";

const Harness = struct {
    app: *zpui.App,
    fixtures: *fixtures_mod.Fixtures,
    state: zpui.Entity(model.AppState),
    handle: zpui.WindowHandle(shell_mod.Shell),

    fn init() !Harness {
        const app = try zpui.App.initTest(gpa);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        const f = try fixtures_mod.load(gpa, io, "apps/zeron/fixtures/reference");
        f.meta.selectedChat = null; // the new-thread canvas
        var prefs: prefs_mod.Prefs = .{ .gpa = gpa };
        fixtures_mod.applyPrefs(f, &prefs);
        try ui.theme.install(app, zt.Theme.dark());
        try prefs_mod.install(app, prefs);
        store.boot(app, io, .dark);
        try composer_store.initMemory(app);
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
        gpa.destroy(h.fixtures);
    }

    fn window(h: *Harness) *zpui.Window {
        return h.handle.window(h.app).?;
    }

    fn frames(h: *Harness, n: usize) void {
        for (0..n) |_| {
            h.window().drawAndPresent();
            h.app.runUntilParked();
            h.app.advanceClock(400 * std.time.ns_per_ms);
        }
    }

    fn openGeneral(h: *Harness) zpui.Entity(SettingsView) {
        TestWindow.of(h.window().platform_window).typeKey(mod ++ "-,");
        h.app.runUntilParked();
        const v = h.handle.rootView(h.app).?.read(h.app).settings_view.?;
        v.update(h.app, openSection, .{view_mod.Section.general});
        h.frames(2);
        return v;
    }

    /// What the composer would send right now.
    fn resolved(h: *Harness) @import("zeron_composer").run_config.Resolved {
        const composer = h.handle.rootView(h.app).?.read(h.app).main.read(h.app).slots.composer_view;
        return composer.read(h.app).picker.read(h.app).resolved(h.app);
    }

    fn selectChat(h: *Harness, id: ?[]const u8) void {
        h.state.read(h.app).workspace.update(h.app, model.WorkspaceStore.selectChat, .{id});
        h.app.runUntilParked();
    }

    fn setEnabled(h: *Harness, id: HarnessId, on: bool) void {
        const catalog = h.state.read(h.app).catalog;
        var l = catalog.lease(h.app);
        defer l.end();
        for (l.value.harnesses.?.value) |*d| if (d.id == id) {
            d.enabled = on;
        };
        l.cx.notify();
    }
};

fn openSection(v: *SettingsView, section: view_mod.Section, cx: *zpui.Context(SettingsView)) void {
    v.openSection(section, cx);
}

/// Select specs and commits build their rows in the frame arena; outside a
/// draw the view's scratch scope provides it (as `onNativeSelect` does).
fn commitSelect(v: *SettingsView, id: select.SelectId, ix: usize, cx: *zpui.Context(SettingsView)) void {
    var sc = view_mod.scratch(gpa);
    sc.begin();
    defer sc.end();
    select.commit(v, id, ix, cx);
}

/// The parts of a select's spec the test checks (copied out of the arena).
const Summary = struct {
    selected: usize,
    count: usize,
    first_is_last_used: bool,
    third: ?[]const u8 = null,
    third_unavailable: bool = false,
};

fn specOf(v: *SettingsView, id: select.SelectId, cx: *zpui.Context(SettingsView)) Summary {
    var sc = view_mod.scratch(gpa);
    sc.begin();
    defer sc.end();
    const sp = select.spec(v, id, cx);
    var out: Summary = .{
        .selected = sp.selected,
        .count = sp.options.len,
        .first_is_last_used = sp.options.len > 0 and std.mem.eql(u8, sp.options[0].label, ntd.last_used),
    };
    if (sp.options.len > 2) {
        // Labels of interest are static fixture names; compare, don't keep.
        out.third = if (std.mem.eql(u8, sp.options[2].label, "Pi")) "Pi" else "other";
        out.third_unavailable = sp.options[2].detail != null;
    }
    return out;
}

test "Default agent / Default model drive new threads; existing threads keep theirs; disabled agents fall back" {
    var h = try Harness.init();
    defer h.deinit();

    // Out of the box: Last used (nothing remembered) → the first offered agent.
    try testing.expectEqual(HarnessId.@"claude-code", h.resolved().harness.?);

    const v = h.openGeneral();
    const agent_spec = v.update(h.app, specOf, .{select.SelectId.default_agent});
    try testing.expectEqual(@as(usize, 0), agent_spec.selected);
    try testing.expect(agent_spec.first_is_last_used);
    // Installed + enabled agents only (the fixture enables Claude Code and Pi).
    try testing.expectEqual(@as(usize, 3), agent_spec.count);
    try testing.expectEqualStrings("Pi", agent_spec.third.?);
    try testing.expect(!agent_spec.third_unavailable);

    // Default agent → Pi; the new-thread composer follows it.
    v.update(h.app, commitSelect, .{ select.SelectId.default_agent, 2 });
    h.frames(1);
    try testing.expectEqual(HarnessId.pi, composer_store.preferred(h.app).?.harness.?);
    try testing.expectEqual(HarnessId.pi, h.resolved().harness.?);
    try testing.expectEqualStrings("anthropic/claude-sonnet-5", h.resolved().model.?); // catalog default

    // Default model → Pi's second model.
    const model_spec = v.update(h.app, specOf, .{select.SelectId.default_model});
    try testing.expectEqual(@as(usize, 3), model_spec.count);
    try testing.expect(model_spec.first_is_last_used);
    v.update(h.app, commitSelect, .{ select.SelectId.default_model, 2 });
    h.frames(1);
    try testing.expectEqualStrings("openai/gpt-5.5", composer_store.preferred(h.app).?.model.?.id);
    try testing.expectEqualStrings("openai/gpt-5.5", h.resolved().model.?);
    try testing.expectEqual(@as(usize, 2), v.update(h.app, specOf, .{select.SelectId.default_model}).selected);

    // An existing thread keeps its own agent and model.
    h.selectChat("75fdc758-a8d5-58bb-a89d-9d5ac5e98425");
    try testing.expectEqual(HarnessId.@"claude-code", h.resolved().harness.?);
    try testing.expectEqualStrings("claude-opus-5-5", h.resolved().model.?);
    h.selectChat(null);
    try testing.expectEqual(HarnessId.pi, h.resolved().harness.?);

    // Pi switched off in Providers: back to the first offered agent; the
    // setting itself stays (and is shown as unavailable).
    h.setEnabled(.pi, false);
    try testing.expectEqual(HarnessId.@"claude-code", h.resolved().harness.?);
    const stale = v.update(h.app, specOf, .{select.SelectId.default_agent});
    try testing.expectEqual(@as(usize, 2), stale.selected);
    try testing.expect(stale.third_unavailable);
    h.setEnabled(.pi, true);
    try testing.expectEqual(HarnessId.pi, h.resolved().harness.?);

    // Back to Last used clears the model too.
    v.update(h.app, commitSelect, .{ select.SelectId.default_agent, 0 });
    try testing.expect(composer_store.preferred(h.app).?.harness == null);
    try testing.expect(composer_store.preferred(h.app).?.model == null);
    try testing.expectEqual(HarnessId.@"claude-code", h.resolved().harness.?);
}
