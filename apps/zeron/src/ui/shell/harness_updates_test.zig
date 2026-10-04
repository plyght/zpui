//! Parity + behavior of Home's agent-update island (`harness_updates.zig`)
//! against zeron `crates/ui/src/shell/harness_updates.rs`.
//!
//! - testdata/harness_updates_parity.json is dumped by
//!   apps/zeron/scripts/harness_updates_parity.rs from the Rust helpers
//!   themselves (lifted verbatim) plus the card's transcribed title /
//!   activity / geometry code; every status carries its engine JSON.
//! - The Rust module's own unit tests are ported below.
//! - A headless window checks the mounted surface: compact size, the chevron
//!   expanding to the 360px list, the Update button's RPC, and the outside
//!   click collapsing it.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const prefs_mod = @import("prefs.zig");
const hu = @import("harness_updates.zig");

const testing = std.testing;
const json = std.json;
const Allocator = std.mem.Allocator;
const TestWindow = zpui.core.test_platform.TestWindow;
const Island = hu.HarnessUpdateIsland;

const fixture = @embedFile("testdata/harness_updates_parity.json");

const Names = struct {
    map: *const std.StringHashMapUnmanaged([]const u8),
    pub fn name(n: Names, id: []const u8) []const u8 {
        return n.map.get(id) orelse id;
    }
};

fn optStr(v: ?json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn num(v: json.Value) f32 {
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => unreachable,
    };
}

fn expectClose(expected: f32, actual: f32) !void {
    try testing.expectApproxEqAbs(expected, actual, 1e-3);
}

test "parity: rows, copy, actions, title, activity and geometry match the Rust island" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try json.parseFromSliceLeaky(json.Value, a, fixture, .{});

    const k = root.object.get("constants").?.object;
    try expectClose(num(k.get("chipHeight").?), hu.chip_height);
    try expectClose(num(k.get("rowHeight").?), hu.row_height);
    try expectClose(num(k.get("maxVisibleRows").?), hu.max_visible_rows);
    try expectClose(num(k.get("listFadeBand").?), hu.list_fade_band);
    try expectClose(num(k.get("listWidth").?), hu.list_width);
    try expectClose(num(k.get("markSize").?), hu.mark_size);
    try expectClose(num(k.get("markStep").?), hu.mark_step);
    try testing.expectEqual(@as(i64, hu.max_marks), k.get("maxMarks").?.integer);

    var checked_rows: usize = 0;
    for (root.object.get("cases").?.array.items) |case| {
        var inv: hu.Inventory = .{ .gpa = testing.allocator };
        defer inv.deinit();
        var names: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (case.object.get("devices").?.array.items) |d| {
            const id = d.object.get("id").?.string;
            try names.put(a, id, d.object.get("name").?.string);
            var start: std.ArrayList([]const u8) = .empty;
            // Insert through the reconciler (sorted), then set the flags.
            var desired: std.ArrayList(hu.Desired) = .empty;
            for (inv.devices.items) |e| try desired.append(a, .{ .id = e.id, .online = e.online });
            try desired.append(a, .{ .id = id, .online = d.object.get("online").?.bool });
            try inv.reconcile(desired.items, &start, a);
            const dev = inv.get(id).?;
            dev.connected = d.object.get("connected").?.bool;
            dev.statuses = try json.parseFromValueLeaky([]hu.Status, a, d.object.get("statuses").?, .{ .ignore_unknown_fields = true });
        }
        const rows = try hu.visibleRows(a, &inv, Names{ .map = &names });
        const want = case.object.get("rows").?.array.items;
        try testing.expectEqual(want.len, rows.len);
        for (want, rows) |w, r| {
            const o = w.object;
            try testing.expectEqualStrings(o.get("deviceId").?.string, r.device_id);
            try testing.expectEqualStrings(o.get("deviceName").?.string, r.device_name);
            try testing.expectEqual(o.get("connected").?.bool, r.connected);
            try testing.expectEqualStrings(o.get("harness").?.string, @tagName(r.status.harness));
            try testing.expectEqualStrings(o.get("agentName").?.string, hu.agentName(r.status.harness));
            try testing.expectEqualStrings(o.get("detail").?.string, try hu.detail(a, r.status));
            try testing.expectEqual(o.get("active").?.bool, hu.isActive(r.status));
            const act = hu.action(r.status);
            if (optStr(o.get("action"))) |label| {
                try testing.expectEqualStrings(label, act.?.label);
                if (optStr(o.get("method"))) |m| try testing.expectEqualStrings(m, act.?.method.?.name()) else try testing.expect(act.?.method == null);
            } else try testing.expect(act == null);
            try expectClose(num(o.get("rightInset").?), hu.rightInset(act != null));
            checked_rows += 1;
        }
        if (rows.len == 0) continue;
        const t = try hu.title(a, rows);
        if (optStr(case.object.get("title"))) |wt| try testing.expectEqualStrings(wt, t.?) else try testing.expect(t == null);
        const act_kind = hu.activity(rows);
        if (optStr(case.object.get("activity"))) |wk| try testing.expectEqualStrings(wk, @tagName(act_kind.?)) else try testing.expect(act_kind == null);
        const g = case.object.get("geometry").?.object;
        const got = hu.geometry(rows, num(g.get("titleWidth").?), num(g.get("actionWidth").?), num(g.get("mainWidth").?), num(g.get("viewportHeight").?));
        try expectClose(num(g.get("trailing").?), got.trailing);
        try expectClose(num(g.get("marksWidth").?), got.marks_width);
        try expectClose(num(g.get("compactWidth").?), got.compact_width);
        try expectClose(num(g.get("listWidth").?), got.list_width);
        try expectClose(num(g.get("listHeight").?), got.list_height);
    }
    try testing.expect(checked_rows > 200);
}

test "parity: presence reconciliation matches reconcile_devices" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try json.parseFromSliceLeaky(json.Value, a, fixture, .{});
    for (root.object.get("reconcile").?.array.items) |case| {
        var inv: hu.Inventory = .{ .gpa = testing.allocator };
        defer inv.deinit();
        var scratch: std.ArrayList([]const u8) = .empty;
        var seed: std.ArrayList(hu.Desired) = .empty;
        for (case.object.get("before").?.array.items) |b| try seed.append(a, .{ .id = b.object.get("id").?.string, .online = false });
        try inv.reconcile(seed.items, &scratch, a);
        for (case.object.get("before").?.array.items) |b| {
            const d = inv.get(b.object.get("id").?.string).?;
            d.online = b.object.get("online").?.bool;
            d.connected = b.object.get("connected").?.bool;
            d.watching = b.object.get("watching").?.bool;
        }
        var desired: std.ArrayList(hu.Desired) = .empty;
        for (case.object.get("desired").?.array.items) |d| try desired.append(a, .{ .id = d.object.get("id").?.string, .online = d.object.get("online").?.bool });
        var start: std.ArrayList([]const u8) = .empty;
        try inv.reconcile(desired.items, &start, a);
        const want_start = case.object.get("start").?.array.items;
        try testing.expectEqual(want_start.len, start.items.len);
        for (want_start, start.items) |w, s| try testing.expectEqualStrings(w.string, s);
        const after = case.object.get("after").?.array.items;
        try testing.expectEqual(after.len, inv.devices.items.len);
        for (after, inv.devices.items) |w, d| {
            try testing.expectEqualStrings(w.object.get("id").?.string, d.id);
            try testing.expectEqual(w.object.get("online").?.bool, d.online);
            try testing.expectEqual(w.object.get("connected").?.bool, d.connected);
            // Rust's `watch` is the task handle; ours is set when the watch starts.
            if (!w.object.get("watching").?.bool) try testing.expect(!d.watching);
        }
    }
}

// ---- the Rust module's unit tests -----------------------------------------------------

fn status(phase: hu.Phase) hu.Status {
    return .{ .harness = .codex, .installedVersion = "1.0", .latestVersion = "2.0", .phase = phase, .canApply = true };
}

const Ident = struct {
    pub fn name(_: Ident, id: []const u8) []const u8 {
        return id;
    }
};

fn addDevice(inv: *hu.Inventory, a: Allocator, id: []const u8, statuses: []const hu.Status) !*hu.DeviceUpdates {
    var desired: std.ArrayList(hu.Desired) = .empty;
    for (inv.devices.items) |e| try desired.append(a, .{ .id = e.id, .online = e.online });
    try desired.append(a, .{ .id = id, .online = true });
    var start: std.ArrayList([]const u8) = .empty;
    try inv.reconcile(desired.items, &start, a);
    const d = inv.get(id).?;
    d.connected = true;
    d.watching = true;
    d.statuses = statuses;
    return d;
}

test "same agent on two hosts keeps both identities and progress" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inv: hu.Inventory = .{ .gpa = testing.allocator };
    defer inv.deinit();
    var desktop = [_]hu.Status{status(.available)};
    var laptop = [_]hu.Status{status(.installing)};
    _ = try addDevice(&inv, a, "desktop", &desktop);
    _ = try addDevice(&inv, a, "laptop", &laptop);
    var rows = try hu.visibleRows(a, &inv, Ident{});
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("desktop", rows[0].device_id);
    try testing.expectEqualStrings("laptop", rows[1].device_id);
    try testing.expectEqualStrings("Update", hu.action(rows[0].status).?.label);
    try testing.expect(hu.action(rows[1].status) == null);
    try testing.expect(hu.isActive(rows[1].status));
    // A phase transition must not move the clicked device's row.
    desktop[0].phase = .downloading;
    laptop[0].phase = .updated;
    rows = try hu.visibleRows(a, &inv, Ident{});
    try testing.expectEqualStrings("desktop", rows[0].device_id);
    try testing.expectEqualStrings("laptop", rows[1].device_id);
    try testing.expectEqualStrings("Cancel", hu.action(rows[0].status).?.label);
    try testing.expectEqual(hu.Phase.updated, rows[1].status.phase);
}

test "disconnect retains the notice but reconnect waits for fresh status" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inv: hu.Inventory = .{ .gpa = testing.allocator };
    defer inv.deinit();
    const st = [_]hu.Status{status(.available)};
    _ = try addDevice(&inv, a, "laptop", &st);
    var start: std.ArrayList([]const u8) = .empty;
    try inv.reconcile(&.{.{ .id = "laptop", .online = false }}, &start, a);
    try testing.expectEqual(@as(usize, 0), start.items.len);
    var rows = try hu.visibleRows(a, &inv, Ident{});
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expect(!rows[0].connected);
    try testing.expectEqual(hu.Phase.available, rows[0].status.phase);

    try inv.reconcile(&.{.{ .id = "laptop", .online = true }}, &start, a);
    try testing.expectEqual(@as(usize, 1), start.items.len);
    try testing.expectEqualStrings("laptop", start.items[0]);
    rows = try hu.visibleRows(a, &inv, Ident{});
    try testing.expect(!rows[0].connected);
    inv.get("laptop").?.connected = true;
    rows = try hu.visibleRows(a, &inv, Ident{});
    try testing.expect(rows[0].connected);
}

test "presence changes only restart the affected host" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inv: hu.Inventory = .{ .gpa = testing.allocator };
    defer inv.deinit();
    const st = [_]hu.Status{status(.available)};
    _ = try addDevice(&inv, a, "desktop", &st);
    _ = try addDevice(&inv, a, "laptop", &st);
    var start: std.ArrayList([]const u8) = .empty;
    try inv.reconcile(&.{ .{ .id = "desktop", .online = true }, .{ .id = "laptop", .online = true } }, &start, a);
    try testing.expectEqual(@as(usize, 0), start.items.len);
    try inv.reconcile(&.{ .{ .id = "desktop", .online = true }, .{ .id = "laptop", .online = false } }, &start, a);
    try testing.expectEqual(@as(usize, 0), start.items.len);
    try testing.expect(inv.get("desktop").?.watching);
    try testing.expect(inv.get("desktop").?.connected);
    try testing.expect(!inv.get("laptop").?.watching);
    try inv.reconcile(&.{ .{ .id = "desktop", .online = true }, .{ .id = "laptop", .online = true } }, &start, a);
    try testing.expectEqual(@as(usize, 1), start.items.len);
    try testing.expectEqualStrings("laptop", start.items[0]);
}

test "inventory removes departed hosts and hides current agents" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inv: hu.Inventory = .{ .gpa = testing.allocator };
    defer inv.deinit();
    const avail = [_]hu.Status{status(.available)};
    const current = [_]hu.Status{status(.current)};
    _ = try addDevice(&inv, a, "removed", &avail);
    const cur = try addDevice(&inv, a, "current", &current);
    cur.watching = false;
    var start: std.ArrayList([]const u8) = .empty;
    try inv.reconcile(&.{ .{ .id = "current", .online = true }, .{ .id = "new", .online = true }, .{ .id = "offline", .online = false } }, &start, a);
    try testing.expectEqual(@as(usize, 2), start.items.len);
    try testing.expectEqualStrings("current", start.items[0]);
    try testing.expectEqualStrings("new", start.items[1]);
    try testing.expect(inv.get("removed") == null);
    try testing.expectEqual(@as(usize, 0), (try hu.visibleRows(a, &inv, Ident{})).len);
    const new = inv.get("new").?;
    new.statuses = &avail;
    new.connected = true;
    const rows = try hu.visibleRows(a, &inv, Ident{});
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("new", rows[0].device_id);
}

// ---- the mounted surface ----------------------------------------------------------------

const Call = struct { method: engine.Method, json: []u8 };
var calls: std.ArrayList(Call) = .empty;

fn sink(method: engine.Method, params: []const u8) void {
    calls.append(testing.allocator, .{ .method = method, .json = testing.allocator.dupe(u8, params) catch return }) catch {};
}

/// Home's mount: the island anchored 24px above the window bottom, centered.
const Host = struct {
    island: zpui.Entity(Island),

    fn init(state: zpui.Entity(model.AppState), _: *zpui.Window, cx: *zpui.Context(Host)) !Host {
        return .{ .island = try cx.newWith(Island, Island.init, .{state}) };
    }

    pub fn deinit(self: *Host, app: *zpui.App) void {
        self.island.release(app);
    }

    pub fn render(self: *Host, window: *zpui.Window, cx: *zpui.Context(Host)) zpui.Div {
        {
            var l = self.island.lease(cx);
            defer l.end();
            l.value.main_width = 900;
            l.value.viewport_height = window.viewportSize().height;
        }
        return zpui.div().relative().size(zpui.px(900))
            .child(zpui.div().absolute().left(zpui.px(0)).right(zpui.px(0)).bottom(zpui.px(hu.bottom_inset))
            .flex().justifyCenter().child(self.island));
    }
};

const statuses_json =
    \\[{"harness":"claude-code","installedVersion":"2.0.1","latestVersion":"2.0.5","phase":"available","canApply":true},
    \\ {"harness":"codex","installedVersion":"0.40.0","latestVersion":"0.41.0","phase":"available","canApply":true},
    \\ {"harness":"cursor","phase":"downloading","progress":{"message":"Fetching 12 MB…"},"canApply":true},
    \\ {"harness":"grok","phase":"current","canApply":true},
    \\ {"harness":"opencode","phase":"failed","error":{"message":"npm exited with 1"},"canApply":false}]
;

test "the island mounts on Home, expands to the list, and runs Update on the host" {
    model.engine_state.test_sink = sink;
    defer {
        model.engine_state.test_sink = null;
        for (calls.items) |c| testing.allocator.free(c.json);
        calls.deinit(testing.allocator);
        calls = .empty;
    }
    const app = try zpui.App.initTest(testing.allocator);
    defer app.deinit();
    try actions.registerAll(app);
    try ui.theme.install(app, zt.Theme.dark());
    try prefs_mod.install(app, .{ .gpa = testing.allocator, .now_override = model.time.parse("2026-10-04T12:00:30Z").? });
    const state = try app.newWith(model.AppState, model.AppState.init, .{ testing.io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false, .wake_mode = .poll } });
    defer state.release(app);
    const devices = try json.parseFromSlice([]engine.protocol.Device, testing.allocator,
        \\[{"id":"dev-mbp","name":"MacBook Pro (2)","platform":"macos","lastSeenAt":"2026-10-04T12:00:00Z","capabilities":["harness-updates-v1"]}]
    , .{ .ignore_unknown_fields = true });
    state.read(app).workspace.update(app, model.WorkspaceStore.applyDevices, .{devices});

    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 900, .height = 900 } } }, Host, Host.init, .{state});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    const island = handle.rootView(app).?.read(app).island;

    {
        var l = island.lease(app);
        defer l.end();
        const isl = l.value;
        isl.injected = true;
        var start: std.ArrayList([]const u8) = .empty;
        defer start.deinit(testing.allocator);
        try isl.inv.reconcile(&.{.{ .id = "dev-mbp", .online = true }}, &start, testing.allocator);
        const d = isl.inv.get("dev-mbp").?;
        d.watching = true;
        d.connected = true;
        d.setFrame(try json.parseFromSlice([]hu.Status, testing.allocator, statuses_json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }));
    }
    island.update(app, struct {
        fn f(_: *Island, cx: *zpui.Context(Island)) void {
            cx.notify();
        }
    }.f, .{});
    tw.frame(true);

    // Compact: the 38px capsule, title width + marks + chevron.
    const compact = island.read(app).last_size;
    try testing.expectEqual(hu.chip_height, compact[1]);
    try testing.expect(compact[0] > 120 and compact[0] < 900 - 32);
    {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const rows = try hu.visibleRows(arena.allocator(), &island.read(app).inv, Ident2{ .ws = state.read(app).workspace.read(app) });
        try testing.expectEqual(@as(usize, 4), rows.len);
        try testing.expectEqualStrings("4 agent updates · MacBook Pro (2)", (try hu.title(arena.allocator(), rows)).?);
    }

    // The summary toggles the list; RESIZE settles in 200ms.
    tw.click(450, 900 - hu.bottom_inset - hu.chip_height / 2);
    tw.frame(true);
    try testing.expect(island.read(app).expanded);
    app.advanceClock(400 * std.time.ns_per_ms);
    tw.frame(true);
    tw.frame(true);
    const list_h = hu.chip_height + hu.row_height * hu.max_visible_rows;
    try testing.expectEqual(hu.list_width, island.read(app).last_size[0]);
    try testing.expectEqual(list_h, island.read(app).last_size[1]);

    // Row 0 (Claude Code · Update) sits right under the summary; its button
    // is right-aligned in the 358px list. Sweep the trailing edge for it.
    const top = 900 - hu.bottom_inset - list_h;
    const row_y = top + hu.chip_height + hu.row_height / 2;
    var x: f32 = 450 + hu.list_width / 2 - 14;
    while (x > 450 + 60 and calls.items.len == 0) : (x -= 6) tw.click(x, row_y);
    try testing.expectEqual(@as(usize, 1), calls.items.len);
    try testing.expectEqual(engine.Method.ApplyHarnessUpdate, calls.items[0].method);
    try testing.expectEqualStrings("{\"harness\":\"claude-code\",\"targetDeviceId\":\"dev-mbp\"}", calls.items[0].json);

    // Cancel on the downloading row goes to the same host.
    island.update(app, Island.runAction, .{ "dev-mbp", engine.Method.CancelHarnessUpdate, engine.protocol.HarnessId.cursor });
    try testing.expectEqual(engine.Method.CancelHarnessUpdate, calls.items[1].method);
    // A disconnected host refuses actions.
    island.update(app, struct {
        fn f(i: *Island, _: *zpui.Context(Island)) void {
            i.inv.get("dev-mbp").?.connected = false;
        }
    }.f, .{});
    island.update(app, Island.runAction, .{ "dev-mbp", engine.Method.ApplyHarnessUpdate, engine.protocol.HarnessId.codex });
    try testing.expectEqual(@as(usize, 2), calls.items.len);

    // A click outside collapses the list.
    tw.click(20, 20);
    tw.frame(true);
    try testing.expect(!island.read(app).expanded);
}

const Ident2 = struct {
    ws: *const model.WorkspaceStore,
    pub fn name(n: Ident2, id: []const u8) []const u8 {
        return n.ws.deviceName(id) orelse id;
    }
};

test "a single notice shows its own copy and action in the capsule" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = [_]hu.UpdateRow{.{ .device_id = "d", .device_name = "MacBook Pro (2)", .connected = true, .status = .{ .harness = .@"claude-code", .latestVersion = "2.0.5", .phase = .available, .canApply = true } }};
    try testing.expectEqualStrings("Claude Code 2.0.5 available · MacBook Pro (2)", (try hu.title(a, &rows)).?);
    try testing.expect(hu.activity(&rows) == null);
    const g = hu.geometry(&rows, 200, 40, 1000, 900);
    try testing.expectEqual(@as(f32, 5), g.trailing);
    // 12 + 22 + 8 + 200 + (40 + 20 + 8) + 5 + 2
    try testing.expectEqual(@as(f32, 317), g.compact_width);
}
