//! Parity with the Rust helpers behind custom sidebar sections, the sync
//! wizard, project actions and the plan-usage ring.
//!
//! testdata/sidebar_sync_parity.json is dumped by
//! apps/zeron/scripts/sidebar_sync_parity.rs from zeron_proto's
//! `SidebarSectionChange::project` / `SidebarPinChange::project_sections` and
//! the shell's lifted `sync_flow_after_auth`, `account_menu_action`,
//! `sidebar_account_identity`, `local_work_phrase`, `import_summary_outcome`,
//! `preferred_action`, `show_action_label`, `unknown_method`, `used_fraction`,
//! `active_account`.

const std = @import("std");
const engine = @import("zeron_engine");
const sections = @import("../sidebar/sections.zig");
const sync_flow = @import("sync_flow.zig");
const project_actions = @import("project_actions.zig");
const account_usage = @import("zeron_composer").account_usage;

const testing = std.testing;
const json = std.json;
const protocol = engine.protocol;

const fixture = @embedFile("testdata/sidebar_sync_parity.json");

test {
    _ = sections;
    _ = sync_flow;
    _ = project_actions;
}

const opts: json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

fn field(v: json.Value, name: []const u8) json.Value {
    return v.object.get(name) orelse .null;
}

fn decode(comptime T: type, a: std.mem.Allocator, v: json.Value) !T {
    return json.parseFromValueLeaky(T, a, v, opts);
}

fn flowOf(v: json.Value) sync_flow.SyncFlow {
    const kind = field(v, "kind").string;
    const b = if (field(v, "b") == .bool) field(v, "b").bool else false;
    const n1: usize = if (field(v, "a") == .integer) @intCast(field(v, "a").integer) else 0;
    const n2: usize = if (field(v, "c") == .integer) @intCast(field(v, "c").integer) else 0;
    const K = std.meta.Tag(sync_flow.SyncFlow);
    return switch (std.meta.stringToEnum(K, kind).?) {
        .idle => .idle,
        .enabling => .enabling,
        .canceling => .canceling,
        .switch_offer => .{ .switch_offer = b },
        .switching => .{ .switching = b },
        .importing => .{ .importing = .{ .done = n1, .total = n2 } },
        .import_done => .{ .import_done = .{ .imported = n1, .skipped = n2 } },
        .import_failed => .{ .import_failed = b },
        .restart_pending => .{ .restart_pending = b },
        .sign_out_confirm => .sign_out_confirm,
        .signing_out => .signing_out,
        .signed_out_restart_required => .signed_out_restart_required,
    };
}

fn scopeOf(v: json.Value) ?protocol.WorkspaceScope {
    if (v == .null) return null;
    return std.meta.stringToEnum(protocol.WorkspaceScope, v.string).?;
}

fn expectJsonEql(a: std.mem.Allocator, want: json.Value, got: anytype) !void {
    var aw: std.Io.Writer.Allocating = .init(a);
    try json.Stringify.value(got, .{}, &aw.writer);
    var bw: std.Io.Writer.Allocating = .init(a);
    try json.Stringify.value(want, .{}, &bw.writer);
    // Re-parse both sides so key order / number formatting don't matter.
    const x = try json.parseFromSliceLeaky(json.Value, a, aw.written(), .{});
    const y = try json.parseFromSliceLeaky(json.Value, a, bw.written(), .{});
    var cw: std.Io.Writer.Allocating = .init(a);
    try json.Stringify.value(x, .{}, &cw.writer);
    var dw: std.Io.Writer.Allocating = .init(a);
    try json.Stringify.value(y, .{}, &dw.writer);
    try testing.expectEqualStrings(dw.written(), cw.written());
}

test "sidebar sections project like zeron_proto" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try json.parseFromSliceLeaky(json.Value, a, fixture, .{});
    for (field(root, "sections").array.items) |case| {
        const start = try decode([]sections.Section, a, field(case, "start"));
        var cur = try sections.cloneSections(a, start);
        for (field(case, "steps").array.items) |step| {
            const change = try decode(protocol.SidebarPinChange, a, field(step, "change"));
            try sections.projectPinChange(a, &cur, change);
            try expectJsonEql(a, field(step, "after"), cur.items);
        }
    }
}

test "sync flow after auth, account menu and identity match the shell" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try json.parseFromSliceLeaky(json.Value, a, fixture, .{});
    for (field(root, "after_auth").array.items) |c| {
        const auth: ?protocol.AuthState = if (field(c, "auth") == .null) null else try decode(protocol.AuthState, a, field(c, "auth"));
        const got = sync_flow.afterAuth(flowOf(field(c, "flow")), scopeOf(field(c, "scope")), auth);
        try testing.expect(got.eql(flowOf(field(c, "next"))));
    }
    for (field(root, "menus").array.items) |c| {
        const got = sync_flow.accountMenuAction(scopeOf(field(c, "scope")), flowOf(field(c, "flow")));
        const want: ?sync_flow.AccountMenuAction = if (field(c, "action") == .null) null else std.meta.stringToEnum(sync_flow.AccountMenuAction, field(c, "action").string).?;
        try testing.expectEqual(want, got);
    }
    for (field(root, "identities").array.items) |c| {
        const user: ?protocol.UserProfile = if (field(c, "user") == .null) null else try decode(protocol.UserProfile, a, field(c, "user"));
        const label, const identity = sync_flow.identity(scopeOf(field(c, "scope")), flowOf(field(c, "flow")), user);
        try testing.expectEqualStrings(field(c, "label").string, label);
        try testing.expectEqualStrings(field(c, "identity").string, identity);
    }
    var buf: [512]u8 = undefined;
    for (field(root, "phrases").array.items) |c| {
        const got = sync_flow.localWorkPhrase(&buf, @intCast(field(c, "chats").integer), @intCast(field(c, "spaces").integer));
        if (field(c, "phrase") == .null) try testing.expect(got == null) else try testing.expectEqualStrings(field(c, "phrase").string, got.?);
    }
    for (field(root, "summaries").array.items) |c| {
        const out = field(c, "outcome");
        switch (sync_flow.importSummaryOutcome(&buf, field(c, "item"))) {
            .ok => |o| {
                const want = field(out, "ok").array.items;
                try testing.expectEqual(@as(usize, @intCast(want[0].integer)), o.imported);
                try testing.expectEqual(@as(usize, @intCast(want[1].integer)), o.skipped);
            },
            .err => |m| try testing.expectEqualStrings(field(out, "err").string, m),
        }
    }
}

test "project actions: preferred action, label cutoff, unknown method" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try json.parseFromSliceLeaky(json.Value, a, fixture, .{});
    for (field(root, "preferred").array.items) |c| {
        const actions = try decode([]project_actions.Action, a, field(c, "actions"));
        const pref: ?[]const u8 = if (field(c, "preferred") == .null) null else field(c, "preferred").string;
        const got = project_actions.preferredAction(actions, pref);
        if (field(c, "chosen") == .null) try testing.expect(got == null) else try testing.expectEqualStrings(field(c, "chosen").string, got.?.id);
    }
    for (field(root, "labels").array.items) |c| {
        const w: f32 = switch (field(c, "width")) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => unreachable,
        };
        try testing.expectEqual(field(c, "show").bool, project_actions.showActionLabel(w));
    }
    for (field(root, "unknown").array.items) |c| {
        try testing.expectEqual(field(c, "unknown").bool, project_actions.unknownMethod(field(c, "message").string));
    }
}

test "plan usage ring reads the live account's most-used window" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try json.parseFromSliceLeaky(json.Value, a, fixture, .{});
    const usage = field(root, "usage");
    const snap = try decode(account_usage.Snapshot, a, field(usage, "snapshot"));
    for (field(usage, "cases").array.items) |c| {
        const h = std.meta.stringToEnum(protocol.HarnessId, field(c, "harness").string).?;
        const acc = account_usage.activeAccount(&snap, h);
        if (field(c, "active") == .null) {
            try testing.expect(acc == null);
            continue;
        }
        try testing.expectEqualStrings(field(c, "active").string, acc.?.id);
        const f = account_usage.usedFraction(acc.?);
        const want: f32 = @floatCast(field(c, "fraction").float);
        try testing.expectApproxEqAbs(want, f.?, 1e-6);
    }
}
