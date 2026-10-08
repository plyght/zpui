//! [liquid-glass] Settings → Appearance → Glass → "Liquid Glass": offered only where
//! native glass exists, falls back to frosted elsewhere, and puts native glass views
//! under the shell chrome when on (headless TestPlatform; it pretends macOS 26 unless
//! `liquid_glass_supported = false`).

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
const select = @import("select.zig");
const view_mod = @import("view.zig");

const testing = std.testing;
const TestWindow = zpui.core.test_platform.TestWindow;
const SettingsView = view_mod.SettingsView;
const mod = if (builtin.os.tag == .macos) "cmd" else "ctrl";

const Harness = struct {
    app: *zpui.App,
    fixtures: *fixtures_mod.Fixtures,
    state: zpui.Entity(model.AppState),
    handle: zpui.WindowHandle(shell_mod.Shell),

    fn init(supported: bool) !Harness {
        const gpa = testing.allocator;
        const io = std.testing.io;
        const app = try zpui.App.initTest(gpa);
        errdefer app.deinit();
        app.test_platform.?.liquid_glass_supported = supported;
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

    fn window(h: *Harness) *zpui.Window {
        return h.handle.window(h.app).?;
    }

    fn openSettings(h: *Harness) zpui.Entity(SettingsView) {
        h.tw().typeKey(mod ++ "-,");
        h.app.runUntilParked();
        return h.handle.rootView(h.app).?.read(h.app).settings_view.?;
    }

    fn closeSettings(h: *Harness) void {
        h.tw().typeKey("escape");
        h.app.runUntilParked();
    }

    /// Let unpainted glass age out (zpui detaches it after a grace period).
    fn settle(h: *Harness) void {
        for (0..zpui.window.liquid_glass_mod.keep_idle_presents + 1) |_| h.window().drawAndPresent();
    }
};

const Probe = struct {
    count: usize = 0,
    selected: usize = 0,
    label: []const u8 = "",
};

fn probeSurface(v: *SettingsView, out: *Probe, cx: *zpui.Context(SettingsView)) void {
    // `spec` builds labels in the frame arena (normally inside a draw).
    const arena_mod = zpui.window.arena_mod;
    var arena = arena_mod.ElementArena.init(testing.allocator);
    defer arena.deinit();
    const prev = arena_mod.enter(&arena);
    defer arena_mod.exit(prev);
    const sp = select.spec(v, .surface, cx);
    out.* = .{ .count = sp.options.len, .selected = sp.selected, .label = if (sp.options.len > 3) sp.options[3].label else "" };
}

fn commitSelect(v: *SettingsView, id: select.SelectId, ix: usize, cx: *zpui.Context(SettingsView)) void {
    select.commit(v, id, ix, cx);
}

fn setSurface(p: zt.SurfacePreference, s: *model.UiSettings, _: std.mem.Allocator) void {
    s.theme.surface = p;
}

test "Liquid Glass is offered where supported and puts native glass under the chrome" {
    var h = try Harness.init(true);
    defer h.deinit();
    // Default: no glass at all (pixel-identical frosted chrome).
    try testing.expect(!ui.theme.get(h.app).isLiquid());
    try testing.expectEqual(@as(usize, 0), h.tw().glassCount());

    const v = h.openSettings();
    var probe: Probe = .{};
    v.update(h.app, probeSurface, .{&probe});
    try testing.expectEqual(@as(usize, 4), probe.count);
    try testing.expectEqualStrings("Liquid Glass", probe.label);

    v.update(h.app, commitSelect, .{ select.SelectId.surface, 3 });
    h.app.runUntilParked();
    try testing.expectEqual(zt.SurfacePreference.liquid, store.current(h.app).theme.surface);
    const theme = ui.theme.get(h.app);
    try testing.expect(theme.isLiquid());
    try testing.expect(theme.surface_treatment == .frosted);
    v.update(h.app, probeSurface, .{&probe});
    try testing.expectEqual(@as(usize, 3), probe.selected);

    // Back in the shell: sidebar + titlebar (+ composer) glass, foreground on the overlay plane.
    h.closeSettings();
    try testing.expect(h.tw().glassCount() >= 2);
    try testing.expect(h.tw().last_overlay_len >= 1);

    // Frosted again → no glass is placed; idle views are detached.
    const v2 = h.openSettings();
    v2.update(h.app, commitSelect, .{ select.SelectId.surface, 1 });
    h.app.runUntilParked();
    h.closeSettings();
    try testing.expect(!ui.theme.get(h.app).isLiquid());
    h.settle();
    try testing.expectEqual(@as(usize, 0), h.tw().glassCount());
}

test "a stored Liquid Glass preference falls back to frosted where unsupported" {
    var h = try Harness.init(false);
    defer h.deinit();
    store.update(h.app, .debounced, zt.SurfacePreference.liquid, setSurface);
    store.applyTheme(h.app);
    h.app.runUntilParked();
    const theme = ui.theme.get(h.app);
    try testing.expect(!theme.isLiquid());
    try testing.expect(theme.isFrost()); // renders exactly like Frosted
    try testing.expectEqual(@as(usize, 0), h.tw().glassCount());

    const v = h.openSettings();
    var probe: Probe = .{};
    v.update(h.app, probeSurface, .{&probe});
    try testing.expectEqual(@as(usize, 3), probe.count); // not offered
    try testing.expectEqual(@as(usize, 1), probe.selected); // shown as Frosted
    // An out-of-range commit (a stale 4th row) is ignored.
    v.update(h.app, commitSelect, .{ select.SelectId.surface, 3 });
    try testing.expectEqual(zt.SurfacePreference.liquid, store.current(h.app).theme.surface);
    try testing.expectEqual(@as(usize, 0), h.tw().glassCount());
}

test "ZERON_LIQUID_GLASS forces the mode for one run without persisting it" {
    var h = try Harness.init(true);
    defer h.deinit();
    store.force_liquid = true;
    defer store.force_liquid = false;
    store.applyTheme(h.app);
    h.app.runUntilParked();
    try testing.expect(ui.theme.get(h.app).isLiquid());
    try testing.expect(store.current(h.app).theme.surface != .liquid);
    h.window().drawAndPresent();
    try testing.expect(h.tw().glassCount() >= 2);
}

test "liquid resolves to frosted tokens and extends the offered list" {
    try testing.expectEqual(zt.SurfaceTreatment.frosted, zt.SurfacePreference.liquid.resolve(.opaque_));
    try testing.expectEqual(@as(usize, 3), zt.SurfacePreference.offered(false).len);
    try testing.expectEqual(zt.SurfacePreference.liquid, zt.SurfacePreference.offered(true)[3]);
    for (zt.SurfacePreference.all, 0..) |p, i| try testing.expectEqual(p, zt.SurfacePreference.all_with_liquid[i]);
}

test "Theme default means Liquid Glass only on a real macOS 26+" {
    // (is_macos, real platform, supported, ZERON_LIQUID_GLASS=0)
    try testing.expect(store.defaultLiquidPolicy(true, true, true, false));
    try testing.expect(!store.defaultLiquidPolicy(false, true, true, false)); // Linux / Windows
    try testing.expect(!store.defaultLiquidPolicy(true, true, false, false)); // macOS < 26
    try testing.expect(!store.defaultLiquidPolicy(true, false, true, false)); // headless tests
    try testing.expect(!store.defaultLiquidPolicy(true, true, true, true)); // opted out
    // The headless platform never flips the default (frosted stays pixel-identical).
    var h = try Harness.init(true);
    defer h.deinit();
    try testing.expect(!store.defaultIsLiquid(h.app));
    try testing.expectEqual(zt.SurfacePreference.theme_default, store.current(h.app).theme.surface);
    try testing.expect(!ui.theme.get(h.app).isLiquid());
}

fn countKind(tw: *TestWindow, kind: zpui.platform.LiquidGlassKind) usize {
    var n: usize = 0;
    for (tw.glass_attach, tw.native_attached) |g, a| {
        if (g != null and a and g.?.kind == kind) n += 1;
    }
    return n;
}

test "Liquid Glass window is Ghostty's macos-glass-regular: one regular glass behind the content, no blur, no hole" {
    var h = try Harness.init(true);
    defer h.deinit();
    store.force_liquid = true;
    defer store.force_liquid = false;
    const prev_mode = shell_mod.sidebar_glass_mode;
    defer shell_mod.sidebar_glass_mode = prev_mode;
    shell_mod.sidebar_glass_mode = .glass;
    store.applyTheme(h.app);
    h.app.runUntilParked();
    h.window().drawAndPresent();
    const tw = h.tw();
    // No window blur to cut a hole into, no AppKit sidebar material.
    try testing.expect(tw.backdrop_hole == null);
    try testing.expectEqual(@as(usize, 0), countKind(tw, .sidebar_material));
    // Exactly one glass under the main surface, covering the window, regular, untinted,
    // with the window's corner radius.
    var behind: usize = 0;
    for (tw.glass_attach, tw.glass_config, tw.native_attached, tw.native_placement) |g, c, a, p| {
        if (g == null or !a or g.?.kind != .glass or g.?.z != .below_content) continue;
        behind += 1;
        const cfg = c orelse return error.NoGlassConfig;
        try testing.expect(cfg.behind_content);
        try testing.expectEqual(zpui.LiquidGlassStyle.regular, cfg.style);
        try testing.expect(cfg.tint == null);
        try testing.expectEqual(@as(f32, 16), cfg.corner_radius);
        const pl = p orelse return error.NoPlacement;
        try testing.expectEqual(@as(f32, 0), pl.bounds.origin.x);
        try testing.expectEqual(@as(f32, 0), pl.bounds.origin.y);
        try testing.expectEqual(h.window().viewportSize().width, pl.bounds.size.width);
        try testing.expectEqual(h.window().viewportSize().height, pl.bounds.size.height);
    }
    try testing.expectEqual(@as(usize, 1), behind);
    // One titlebar container; its capsules are members (no full-width strip).
    try testing.expectEqual(@as(usize, 1), countKind(tw, .container));
    var members: usize = 0;
    var full_width = false;
    for (tw.glass_attach, tw.native_attached, tw.native_placement) |g, a, p| {
        if (g == null or !a or g.?.kind != .glass) continue;
        if (g.?.parent != null) members += 1;
        if (p) |pl| if (pl.bounds.size.width >= 1000 and pl.bounds.size.height <= 40) {
            full_width = true;
        };
    }
    try testing.expect(members >= 2); // title + session controls / pane toggles
    try testing.expect(!full_width);

    // vev: AppKit's sidebar material under the pane, no window glass, no hole.
    shell_mod.sidebar_glass_mode = .vev;
    h.window().refresh();
    h.window().drawAndPresent();
    try testing.expectEqual(@as(usize, 1), countKind(tw, .sidebar_material));
    try testing.expect(tw.backdrop_hole == null);
}

const titlebar_mod = @import("../shell/titlebar.zig");

const PlacedGlass = struct { bounds: zpui.Bounds(zpui.Pixels), radius: f32, tint: ?[4]f32 };

/// The attached titlebar glass views (members of the titlebar container).
fn titlebarGlass(tw: *TestWindow, out: []PlacedGlass) []PlacedGlass {
    var n: usize = 0;
    for (tw.glass_attach, tw.native_attached, tw.native_placement, tw.glass_config) |g, a, p, c| {
        if (g == null or !a or g.?.kind != .glass or g.?.parent == null or p == null or c == null) continue;
        if (p.?.bounds.origin.y > zt.layout.titlebar_height) continue;
        out[n] = .{ .bounds = p.?.bounds, .radius = c.?.corner_radius, .tint = c.?.tint };
        n += 1;
    }
    return out[0..n];
}

test "Liquid Glass: with the sidebar collapsed, one island wraps the traffic lights and the nav controls" {
    var h = try Harness.init(true);
    defer h.deinit();
    store.force_liquid = true;
    defer store.force_liquid = false;
    store.applyTheme(h.app);
    h.app.runUntilParked();
    h.window().drawAndPresent();
    const tw = h.tw();
    var buf: [32]PlacedGlass = undefined;

    // Sidebar expanded: the controls sit bare on the sidebar pane (no island at x = 6).
    for (titlebarGlass(tw, &buf)) |g| try testing.expect(g.bounds.origin.x != titlebar_mod.lead_capsule_left);

    h.app.globalMut(prefs_mod.Prefs).sidebar_collapsed = true;
    h.window().refresh();
    h.window().drawAndPresent();
    h.settle();
    const has_chat = h.state.read(h.app).workspace.read(h.app).selected_chat != null;
    const placed = titlebarGlass(tw, &buf);
    var island: ?PlacedGlass = null;
    for (placed) |g| if (g.bounds.origin.x == titlebar_mod.lead_capsule_left) {
        try testing.expect(island == null); // exactly one
        island = g;
    };
    const lead = island orelse return error.NoLeadingIsland;
    try testing.expectEqual(titlebar_mod.lead_capsule_radius, lead.radius);
    // zeron's titlebar island: from x = 6 (left of the traffic lights at 14,14), 32
    // high centred on the controls (y 5..37, offset here by the phase fade-in's slide,
    // like every capsule), to the cluster's trailing pad.
    try testing.expectEqual(@as(f32, 6), lead.bounds.origin.x);
    try testing.expectEqual(@as(f32, 32), lead.bounds.size.height);
    try testing.expectEqual(titlebar_mod.leadCapsuleRight(has_chat), lead.bounds.origin.x + lead.bounds.size.width);
    try testing.expect(lead.bounds.origin.x < 14); // covers the traffic lights on macOS
    // Tinted with the island's dark `glass_overlay` fill.
    const want = ui.theme.get(h.app).glassOverlay().toRgba();
    const tint = lead.tint orelse return error.NoTint;
    try testing.expectApproxEqAbs(want.a, tint[3], 0.001);
    try testing.expect(tint[0] < 0.2 and tint[1] < 0.2 and tint[2] < 0.2);

    // The title and right-hand groups match the island (radius, height, fill) and
    // stay clear of it (farther than the container's merge spacing).
    var others: usize = 0;
    for (placed) |g| if (g.bounds.origin.x != titlebar_mod.lead_capsule_left) {
        others += 1;
        try testing.expectEqual(titlebar_mod.lead_capsule_radius, g.radius);
        try testing.expectEqual(lead.bounds.size.height, g.bounds.size.height);
        const gt = g.tint orelse return error.NoTint;
        try testing.expectApproxEqAbs(tint[3], gt[3], 0.001);
        // Same vertical centre (the controls' y = 21).
        try testing.expectEqual(g.bounds.origin.y + g.bounds.size.height / 2, lead.bounds.origin.y + lead.bounds.size.height / 2);
        try testing.expect(g.bounds.origin.x >= lead.bounds.origin.x + lead.bounds.size.width + titlebar_mod.capsule_spacing);
    };
    if (has_chat) try testing.expect(others >= 1);
}
