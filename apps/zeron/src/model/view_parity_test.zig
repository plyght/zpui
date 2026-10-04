//! Parity of `view.zig` (and `time.zig`) with zeron `crates/proto/src/view.rs`.
//! The fixture is dumped by apps/zeron/scripts/view_parity.rs from the Rust
//! implementation itself; every case carries its inputs as engine JSON.

const std = @import("std");
const json = std.json;
const testing = std.testing;
const protocol = @import("zeron_engine").protocol;
const view = @import("view.zig");
const time = @import("time.zig");

const fixture = @embedFile("testdata/view_parity.json");

const opts: json.ParseOptions = .{ .ignore_unknown_fields = true };

fn decode(comptime T: type, a: std.mem.Allocator, v: json.Value) !T {
    return json.parseFromValueLeaky(T, a, v, opts);
}

fn field(v: json.Value, name: []const u8) json.Value {
    return v.object.get(name) orelse .null;
}

fn str(v: json.Value) []const u8 {
    return v.string;
}

fn optStr(v: json.Value) ?[]const u8 {
    return if (v == .null) null else v.string;
}

fn ts(v: json.Value) time.Timestamp {
    return time.parse(v.string).?;
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    root: json.Value,

    fn load() !Fixture {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const root = try json.parseFromSliceLeaky(json.Value, arena.allocator(), fixture, .{});
        return .{ .arena = arena, .root = root };
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }

    fn cases(f: *const Fixture, name: []const u8) []json.Value {
        return f.root.object.get(name).?.array.items;
    }
};

test "parity: RFC 3339 timestamps" {
    var f = try Fixture.load();
    defer f.deinit();
    for (f.cases("timestamps")) |c| {
        const got = time.parse(str(field(c, "input")));
        const secs = field(c, "unixSeconds");
        if (secs == .null) {
            if (got != null) std.debug.print("accepted {s}\n", .{str(field(c, "input"))});
            try testing.expect(got == null);
        } else {
            const t = got orelse {
                std.debug.print("rejected {s}\n", .{str(field(c, "input"))});
                return error.TestUnexpectedResult;
            };
            try testing.expectEqual(secs.integer, t.secs);
            try testing.expectEqual(field(c, "nanos").integer, t.nanos);
        }
    }
}

test "parity: effective indicator, display status, unseen" {
    var f = try Fixture.load();
    defer f.deinit();
    const a = f.arena.allocator();
    for (f.cases("status")) |c| {
        const now = ts(field(c, "now"));
        const chat = try decode(protocol.Chat, a, field(c, "chat"));
        const session: ?protocol.Session = if (field(c, "session") == .null) null else try decode(protocol.Session, a, field(c, "session"));
        const sp: ?*const protocol.Session = if (session) |*s| s else null;
        const indicator = view.effectiveIndicator(sp, now);
        const want_ind = str(field(c, "indicator"));
        const got_ind: []const u8 = switch (indicator) {
            .none => "none",
            .working => "working",
            .awaiting_input => "awaitingInput",
            .errored => "errored",
        };
        try testing.expectEqualStrings(want_ind, got_ind);
        try testing.expectEqualStrings(str(field(c, "displayStatus")), @tagName(view.displayStatus(&chat, sp, now)));
        try testing.expectEqual(field(c, "unseen").bool, view.chatUnseen(&chat));
    }
    for (f.cases("attentionRank")) |c| {
        const status = std.meta.stringToEnum(view.ChatIndicator, str(field(c, "status"))).?;
        try testing.expectEqual(field(c, "rank").integer, view.attentionRank(status));
    }
}

fn expectIndices(want: json.Value, got: []const usize) !void {
    try testing.expectEqual(want.array.items.len, got.len);
    for (want.array.items, got) |w, g| try testing.expectEqual(@as(usize, @intCast(w.integer)), g);
}

test "parity: sort orders and grouping" {
    var f = try Fixture.load();
    defer f.deinit();
    const a = f.arena.allocator();
    for (f.cases("sorts")) |c| {
        const items = field(c, "chats").array.items;
        const chats = try a.alloc(protocol.Chat, items.len);
        for (items, chats) |v, *ch| ch.* = try decode(protocol.Chat, a, v);

        // sortChats sorts values; track original indices through a stable sort
        // of index-tagged pairs with the same comparator.
        const Tagged = struct { chat: protocol.Chat, index: usize };
        const tagged = try a.alloc(Tagged, chats.len);
        for (tagged, chats, 0..) |*t, ch, i| t.* = .{ .chat = ch, .index = i };
        std.sort.block(Tagged, tagged, {}, struct {
            fn lt(_: void, x: Tagged, y: Tagged) bool {
                return view.chatsLessThan(&x.chat, &y.chat);
            }
        }.lt);
        const sorted_idx = try a.alloc(usize, chats.len);
        for (tagged, sorted_idx) |t, *o| o.* = t.index;
        try expectIndices(field(c, "sortChats"), sorted_idx);
        // And sortChats itself agrees on the resulting order.
        const by_value = try a.dupe(protocol.Chat, chats);
        view.sortChats(by_value);
        for (by_value, sorted_idx) |ch, i| try testing.expectEqualStrings(chats[i].createdAt, ch.createdAt);

        const tabs = try a.alloc(*const protocol.Chat, chats.len);
        for (tabs, chats) |*t, *ch| t.* = ch;
        view.sortTabs(tabs);
        const tab_idx = try a.alloc(usize, chats.len);
        for (tabs, tab_idx) |t, *o| o.* = (@intFromPtr(t) - @intFromPtr(chats.ptr)) / @sizeOf(protocol.Chat);
        try expectIndices(field(c, "sortTabs"), tab_idx);

        const statuses = [_]view.ChatIndicator{ .working, .idle, .completed };
        const rows = try a.alloc(view.ActiveRow, chats.len);
        for (rows, chats, 0..) |*r, *ch, i| r.* = .{ .status = statuses[i % 3], .chat = ch };
        view.sortActive(rows);
        const active_idx = try a.alloc(usize, chats.len);
        for (rows, active_idx) |r, *o| o.* = (@intFromPtr(r.chat) - @intFromPtr(chats.ptr)) / @sizeOf(protocol.Chat);
        try expectIndices(field(c, "sortActive"), active_idx);

        // group_chats over the sort_chats order.
        const ordered = try a.alloc(*const protocol.Chat, chats.len);
        for (ordered, sorted_idx) |*o, i| o.* = &chats[i];
        const groups = try view.groupChats(testing.allocator, ordered);
        defer groups.deinit(testing.allocator);
        const want_groups = field(c, "groups").array.items;
        try testing.expectEqual(want_groups.len, groups.items.len);
        for (want_groups, groups.items) |wg, g| {
            try testing.expectEqualStrings(str(field(wg, "label")), g.label);
            const ids = field(wg, "ids").array.items;
            try testing.expectEqual(ids.len, g.chats.items.len);
            for (ids, g.chats.items) |id, ch| try testing.expectEqualStrings(str(id), ch.id);
        }
    }
    for (f.cases("spaceSorts")) |c| {
        const items = field(c, "spaces").array.items;
        const spaces = try a.alloc(protocol.Space, items.len);
        for (items, spaces) |v, *s| s.* = try decode(protocol.Space, a, v);
        const sorted = try a.dupe(protocol.Space, spaces);
        view.sortSpaces(sorted);
        for (field(c, "sorted").array.items, sorted) |w, s| {
            const want = spaces[@intCast(w.integer)];
            try testing.expectEqualStrings(want.id, s.id);
            try testing.expectEqualStrings(want.createdAt, s.createdAt);
        }
    }
}

test "parity: gate phase" {
    var f = try Fixture.load();
    defer f.deinit();
    const a = f.arena.allocator();
    for (f.cases("gates")) |c| {
        const conn_name = str(field(c, "connection"));
        const conn: view.ConnectionStatus = if (std.mem.eql(u8, conn_name, "connecting"))
            .connecting
        else if (std.mem.eql(u8, conn_name, "ready"))
            .ready
        else
            .{ .failed = "boom: no engine" };
        const scope: ?protocol.WorkspaceScope = if (optStr(field(c, "scope"))) |s| std.meta.stringToEnum(protocol.WorkspaceScope, s).? else null;
        const auth: ?protocol.AuthState = if (field(c, "auth") == .null) null else try decode(protocol.AuthState, a, field(c, "auth"));
        const gate = view.gatePhase(conn, scope, if (auth) |*x| x else null);
        const want = field(c, "gate");
        switch (gate) {
            .failed => |msg| try testing.expectEqualStrings(str(field(want, "failed")), msg),
            .loading => try testing.expectEqualStrings("loading", str(want)),
            .sign_in => try testing.expectEqualStrings("signIn", str(want)),
            .org_gate => try testing.expectEqualStrings("orgGate", str(want)),
            .ready => try testing.expectEqualStrings("ready", str(want)),
        }
    }
}

fn expectUser(want: json.Value, got: protocol.UserProfile) !void {
    try testing.expectEqualStrings(str(field(want, "id")), got.id);
    try testing.expectEqualStrings(str(field(want, "email")), got.email);
    const name = optStr(field(want, "name"));
    if (name) |n| try testing.expectEqualStrings(n, got.name.?) else try testing.expect(got.name == null);
}

test "parity: parse_auth_state" {
    var f = try Fixture.load();
    defer f.deinit();
    const a = f.arena.allocator();
    for (f.cases("parseAuth")) |c| {
        const got = view.parseAuthState(a, field(c, "input"));
        const want = field(c, "output");
        if (want == .null) {
            try testing.expect(got == null);
            continue;
        }
        const g = got.?;
        const state = str(field(want, "state"));
        try testing.expectEqualStrings(state, @tagName(g));
        switch (g) {
            .signedOut => {},
            .needsOrganization => |n| try expectUser(field(want, "user"), n.user),
            .signedIn => |s| {
                try expectUser(field(want, "user"), s.user);
                const org = optStr(field(want, "orgId"));
                if (org) |o| try testing.expectEqualStrings(o, s.orgId.?) else try testing.expect(s.orgId == null);
            },
        }
    }
}

test "parity: project label, chat location, time ago, single line" {
    var f = try Fixture.load();
    defer f.deinit();
    const a = f.arena.allocator();
    for (f.cases("projectLabel")) |c| {
        try testing.expectEqualStrings(str(field(c, "label")), view.projectLabel(optStr(field(c, "cwd"))));
    }
    for (f.cases("chatLocation")) |c| {
        const chat = try decode(protocol.Chat, a, field(c, "chat"));
        const got = try view.chatLocation(testing.allocator, &chat);
        defer if (got) |g| testing.allocator.free(g);
        if (optStr(field(c, "location"))) |w| try testing.expectEqualStrings(w, got.?) else try testing.expect(got == null);
    }
    for (f.cases("timeAgo")) |c| {
        var buf: [16]u8 = undefined;
        try testing.expectEqualStrings(str(field(c, "ago")), view.formatTimeAgo(&buf, ts(field(c, "then")), ts(field(c, "now"))));
    }
    for (f.cases("singleLine")) |c| {
        const got = try view.singleLine(testing.allocator, str(field(c, "input")));
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(str(field(c, "output")), got);
    }
}

test "parity: tool chips and group summaries" {
    var f = try Fixture.load();
    defer f.deinit();
    const a = f.arena.allocator();
    for (f.cases("toolChip")) |c| {
        const call = try decode(protocol.ToolCall, a, field(c, "call"));
        const chip = try view.toolChipContent(testing.allocator, call);
        defer testing.allocator.free(chip.detail);
        try testing.expectEqualStrings(str(field(c, "label")), chip.label);
        try testing.expectEqualStrings(str(field(c, "detail")), chip.detail);
    }
    for (f.cases("toolGroup")) |c| {
        const items = field(c, "tools").array.items;
        const tools = try a.alloc(view.ToolEntry, items.len);
        for (items, tools) |v, *t| t.* = .{
            .call = try decode(protocol.ToolCall, a, field(v, "call")),
            .is_error = field(v, "isError").bool,
        };
        const got = try view.toolGroupSummary(testing.allocator, tools);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(str(field(c, "summary")), got);
    }
}

test "parity: checkout plan/label, version triple, constants" {
    var f = try Fixture.load();
    defer f.deinit();
    const a = f.arena.allocator();
    for (f.cases("checkout")) |c| {
        const kind: view.CheckoutKind = if (std.mem.eql(u8, str(field(c, "kind")), "local")) .local else .new_worktree;
        const r: ?view.RepoRef = if (field(c, "ref") == .null) null else try decode(view.RepoRef, a, field(c, "ref"));
        const rp: ?*const view.RepoRef = if (r) |*x| x else null;
        try testing.expectEqualStrings(str(field(c, "label")), view.checkoutLabel(kind, rp));
        const want = field(c, "plan");
        switch (view.checkoutPlan(kind, rp)) {
            .current_checkout => |p| {
                const w = field(want, "currentCheckout");
                try testing.expect(w != .null);
                if (optStr(field(w, "branch"))) |b| try testing.expectEqualStrings(b, p.branch.?) else try testing.expect(p.branch == null);
            },
            .reuse_worktree => |p| {
                const w = field(want, "reuseWorktree");
                try testing.expectEqualStrings(str(field(w, "path")), p.path);
                try testing.expectEqualStrings(str(field(w, "branch")), p.branch);
            },
            .new_worktree => |p| {
                const w = field(want, "newWorktree");
                try testing.expect(w != .null);
                if (optStr(field(w, "base"))) |b| try testing.expectEqualStrings(b, p.base.?) else try testing.expect(p.base == null);
            },
        }
    }
    for (f.cases("versionTriple")) |c| {
        const got = view.versionTriple(str(field(c, "input")));
        const want = field(c, "output");
        if (want == .null) {
            try testing.expect(got == null);
        } else {
            const g = got orelse return error.TestUnexpectedResult;
            for (want.array.items, g) |w, x| {
                const wv: u64 = switch (w) {
                    .integer => |i| @intCast(i),
                    .number_string => |s| try std.fmt.parseInt(u64, s, 10),
                    .float => |fl| @intFromFloat(fl),
                    else => return error.TestUnexpectedResult,
                };
                try testing.expectEqual(wv, x);
            }
        }
    }
    try testing.expectEqual(f.root.object.get("sessionStaleMs").?.integer, view.session_stale_ms);
    const dots = f.root.object.get("dots").?;
    inline for (.{ "working", "awaiting", "errored", "completed" }) |name| {
        const want = field(dots, name).array.items;
        const got = @field(view.dot, name);
        for (want, got) |w, g| try testing.expectApproxEqAbs(@as(f32, @floatCast(w.float)), g, 1e-6);
    }
}
