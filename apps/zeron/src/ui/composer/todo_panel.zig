//! The agent's checklist docked above the composer — the pure half of zeron
//! `todo_panel.rs`: which list is current (`latest_todo`), what the header
//! says (`TodoSummary`), which rows a long list folds to (`focus_window`,
//! `rows`), and the per-chat presentation state (`TodoPanelState`). The
//! tray itself is drawn by `extras.zig`.

const std = @import("std");
const engine = @import("zeron_engine");

const protocol = engine.protocol;
const TodoItem = protocol.TodoItem;
const TodoStatus = protocol.TodoStatus;

/// Lists longer than this fold to a `focus_window` around the current item.
pub const fold_above: usize = 6;
pub const focus_window_len: usize = 3;

/// `latest_todo`: the checklist the agent most recently wrote (the last
/// `Todo` tool part of an assistant entry), or null when there is none or
/// the latest write cleared it. `src` has `len()` / `entry(i)`.
pub fn latestTodo(src: anytype) ?[]const TodoItem {
    var i = src.len();
    while (i > 0) {
        i -= 1;
        const e = src.entry(i);
        if (e.role != .assistant) continue;
        var p = e.parts.len;
        while (p > 0) {
            p -= 1;
            switch (e.parts[p]) {
                .tool => |t| switch (t.call) {
                    .todo => |todo| return if (todo.items.len > 0) todo.items else null,
                    else => {},
                },
                else => {},
            }
        }
    }
    return null;
}

pub const Summary = struct {
    total: usize = 0,
    done: usize = 0,
    /// First in-progress item.
    active: ?usize = null,
    /// First item not yet completed.
    next: ?usize = null,

    pub fn of(items: []const TodoItem) Summary {
        var s: Summary = .{ .total = items.len };
        for (items, 0..) |it, ix| switch (it.effectiveStatus()) {
            .completed => s.done += 1,
            .inProgress => {
                if (s.active == null) s.active = ix;
                if (s.next == null) s.next = ix;
            },
            .pending => if (s.next == null) {
                s.next = ix;
            },
        };
        return s;
    }

    pub fn finished(self: Summary) bool {
        return self.total > 0 and self.done == self.total;
    }

    /// The item the header names: what is being worked on, else what is next.
    pub fn headline(self: Summary) ?usize {
        return self.active orelse self.next;
    }
};

pub const Range = struct { start: usize, end: usize };

/// `focus_window`: three items around the current one (finished lists show
/// their last three); lists up to `fold_above` never fold.
pub fn focusWindow(items: []const TodoItem) Range {
    const total = items.len;
    if (total <= fold_above) return .{ .start = 0, .end = total };
    const focus = Summary.of(items).headline() orelse total - 1;
    const start = @min(focus -| 1, total - focus_window_len);
    return .{ .start = start, .end = start + focus_window_len };
}

pub const FoldSide = enum { earlier, later };

pub const Row = union(enum) {
    item: usize,
    fold: struct { side: FoldSide, count: usize, open: bool },
};

/// `rows`: items keep the agent's order; folds sit at the list's edges.
pub fn rows(out: *std.ArrayList(Row), gpa: std.mem.Allocator, items: []const TodoItem, show_earlier: bool, show_later: bool) !void {
    const w = focusWindow(items);
    const earlier = w.start;
    const later = items.len - w.end;
    if (earlier > 0) {
        try out.append(gpa, .{ .fold = .{ .side = .earlier, .count = earlier, .open = show_earlier } });
        if (show_earlier) for (0..earlier) |i| try out.append(gpa, .{ .item = i });
    }
    for (w.start..w.end) |i| try out.append(gpa, .{ .item = i });
    if (later > 0) {
        if (show_later) for (w.end..items.len) |i| try out.append(gpa, .{ .item = i });
        try out.append(gpa, .{ .fold = .{ .side = .later, .count = later, .open = show_later } });
    }
}

/// Identity of a list (a dismissal holds until the agent writes another).
pub fn signature(items: []const TodoItem) u64 {
    var h = std.hash.Wyhash.init(0x70d0);
    for (items) |it| {
        h.update(it.text);
        h.update(&.{@backingInt(it.effectiveStatus())});
    }
    return h.final();
}

/// `TodoPanelState`: per chat, for the app run.
pub const State = struct {
    /// The user's explicit choice; null follows the automatic rule (open
    /// while work remains, compact once everything is done).
    expanded: ?bool = null,
    show_earlier: bool = false,
    show_later: bool = false,
    dismissed: ?u64 = null,
    was_settled: bool = false,
    epoch: u32 = 0,

    /// Reaching "everything done and idle" drops an explicit choice once.
    pub fn observe(self: *State, settled: bool) void {
        if (settled and !self.was_settled) self.expanded = null;
        self.was_settled = settled;
    }

    pub fn isExpanded(self: *const State, finished: bool) bool {
        return self.expanded orelse !finished;
    }

    pub fn toggle(self: *State, finished: bool) void {
        self.expanded = !self.isExpanded(finished);
        self.epoch +%= 1;
    }

    pub fn toggleFold(self: *State, side: FoldSide) void {
        switch (side) {
            .earlier => self.show_earlier = !self.show_earlier,
            .later => self.show_later = !self.show_later,
        }
    }

    pub fn dismiss(self: *State, items: []const TodoItem) void {
        self.dismissed = signature(items);
    }

    pub fn isDismissed(self: *const State, items: []const TodoItem) bool {
        return self.dismissed == signature(items);
    }
};

/// Per-chat states (keys owned).
pub const Panels = struct {
    map: std.StringHashMapUnmanaged(State) = .empty,

    pub fn get(self: *Panels, gpa: std.mem.Allocator, chat: []const u8) *State {
        const gop = self.map.getOrPut(gpa, chat) catch @panic("OOM");
        if (!gop.found_existing) {
            gop.key_ptr.* = gpa.dupe(u8, chat) catch @panic("OOM");
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    pub fn deinit(self: *Panels, gpa: std.mem.Allocator) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.map.deinit(gpa);
    }
};

const testing = std.testing;

fn mk(spec: []const u8) [16]TodoItem {
    var out: [16]TodoItem = undefined;
    for (spec, 0..) |c, i| out[i] = .{ .text = "t", .done = c == 'x', .status = switch (c) {
        '>' => .inProgress,
        'x' => .completed,
        else => .pending,
    } };
    return out;
}

test "summary and focus window" {
    const a = mk("xx>..");
    const s = Summary.of(a[0..5]);
    try testing.expectEqual(@as(usize, 2), s.done);
    try testing.expectEqual(@as(?usize, 2), s.headline());
    try testing.expectEqual(Range{ .start = 0, .end = 5 }, focusWindow(a[0..5]));
    const long = mk("xxxx>....");
    try testing.expectEqual(Range{ .start = 3, .end = 6 }, focusWindow(long[0..9]));
    const done = mk("xxxxxxxx");
    try testing.expect(Summary.of(done[0..8]).finished());
    try testing.expectEqual(Range{ .start = 5, .end = 8 }, focusWindow(done[0..8]));
    var out: std.ArrayList(Row) = .empty;
    defer out.deinit(testing.allocator);
    try rows(&out, testing.allocator, long[0..9], false, false);
    try testing.expectEqual(@as(usize, 5), out.items.len);
    try testing.expect(out.items[0] == .fold and out.items[0].fold.count == 3);
    try testing.expect(out.items[4] == .fold and out.items[4].fold.count == 3);
}

test "panel state tidies once and dismissals follow the list" {
    var st: State = .{};
    const a = mk("xx");
    try testing.expect(!st.isExpanded(true));
    st.toggle(true);
    try testing.expect(st.isExpanded(true));
    st.observe(true);
    try testing.expect(!st.isExpanded(true));
    st.toggle(true);
    st.observe(true);
    try testing.expect(st.isExpanded(true));
    st.dismiss(a[0..2]);
    try testing.expect(st.isDismissed(a[0..2]));
    const b = mk("x.");
    try testing.expect(!st.isDismissed(b[0..2]));
}
