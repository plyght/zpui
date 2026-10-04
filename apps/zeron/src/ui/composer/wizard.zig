//! The question wizard's pure half (zeron `composer.rs` `Wizard`,
//! `WizardStep`, `pending_input_request`, `input_request_resolved`,
//! `wizard_escape_goes_back`): paged questions ("1/3"), single-select
//! auto-advances after `auto_advance_ms`, multi-select and typed answers
//! advance explicitly, number keys 1-9 select, Back pages back; free text
//! overrides picked labels. The glue + panel live in `extras.zig`.

const std = @import("std");
const engine = @import("zeron_engine");

const protocol = engine.protocol;
const Allocator = std.mem.Allocator;

pub const auto_advance_ms: u64 = 220;

pub const Step = union(enum) {
    stay,
    /// Single-select landed — advance after `auto_advance_ms`.
    auto_advance,
    /// All pages answered: submit (answers owned by the wizard's arena).
    done: []const protocol.UserInputAnswer,
};

pub const Wizard = struct {
    arena: *std.heap.ArenaAllocator,
    request_id: []const u8,
    questions: []const protocol.UserInputQuestion,
    page: usize = 0,
    picked: []std.ArrayList(usize),
    typed: []std.ArrayList(u8),

    /// Deep-copies `questions` (the transcript rows may be replaced).
    pub fn init(gpa: Allocator, request_id: []const u8, questions: []const protocol.UserInputQuestion) !Wizard {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }
        const a = arena.allocator();
        const qs = try a.alloc(protocol.UserInputQuestion, questions.len);
        for (questions, qs) |q, *o| {
            const opts = try a.alloc([]const u8, q.options.len);
            for (q.options, opts) |s, *d| d.* = try a.dupe(u8, s);
            o.* = .{
                .id = try a.dupe(u8, q.id),
                .header = try a.dupe(u8, q.header),
                .question = try a.dupe(u8, q.question),
                .options = opts,
                .multiSelect = q.multiSelect,
                .prefill = if (q.prefill) |p| try a.dupe(u8, p) else null,
                .multiline = q.multiline,
            };
        }
        const picked = try a.alloc(std.ArrayList(usize), qs.len);
        for (picked) |*p| p.* = .empty;
        const typed = try a.alloc(std.ArrayList(u8), qs.len);
        for (typed, qs) |*t, q| {
            t.* = .empty;
            if (q.prefill) |p| try t.appendSlice(a, p);
        }
        return .{ .arena = arena, .request_id = try a.dupe(u8, request_id), .questions = qs, .picked = picked, .typed = typed };
    }

    pub fn deinit(self: *Wizard, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self.arena);
    }

    /// "2/3".
    pub fn counter(self: *const Wizard, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}/{d}", .{ self.page + 1, @max(self.questions.len, 1) }) catch "";
    }

    pub fn current(self: *const Wizard) ?*const protocol.UserInputQuestion {
        return if (self.page < self.questions.len) &self.questions[self.page] else null;
    }

    pub fn isPicked(self: *const Wizard, option_ix: usize) bool {
        if (self.page >= self.picked.len) return false;
        return std.mem.indexOfScalar(usize, self.picked[self.page].items, option_ix) != null;
    }

    pub fn pageHasPick(self: *const Wizard) bool {
        return self.page < self.picked.len and self.picked[self.page].items.len > 0;
    }

    pub fn typedText(self: *const Wizard) []const u8 {
        return if (self.page < self.typed.len) self.typed[self.page].items else "";
    }

    /// Click / tap an option.
    pub fn select(self: *Wizard, option_ix: usize) Step {
        const q = self.current() orelse return .stay;
        if (option_ix >= q.options.len) return .stay;
        const a = self.arena.allocator();
        const picked = &self.picked[self.page];
        if (q.multiSelect) {
            if (std.mem.indexOfScalar(usize, picked.items, option_ix)) |at| {
                _ = picked.orderedRemove(at);
            } else picked.append(a, option_ix) catch {};
            return .stay;
        }
        picked.clearRetainingCapacity();
        picked.append(a, option_ix) catch {};
        return .auto_advance;
    }

    /// Number key 1-9.
    pub fn pressNumber(self: *Wizard, number: usize) Step {
        if (number == 0) return .stay;
        return self.select(number - 1);
    }

    pub fn setTyped(self: *Wizard, text: []const u8) void {
        if (self.page >= self.typed.len) return;
        const t = &self.typed[self.page];
        t.clearRetainingCapacity();
        t.appendSlice(self.arena.allocator(), text) catch {};
    }

    /// Explicit submit / auto-advance landing.
    pub fn advance(self: *Wizard) Step {
        if (self.page + 1 < self.questions.len) {
            self.page += 1;
            return .stay;
        }
        return .{ .done = self.answers() catch &.{} };
    }

    /// Page back; false on the first page.
    pub fn back(self: *Wizard) bool {
        if (self.page == 0) return false;
        self.page -= 1;
        return true;
    }

    /// Answers per question: free text overrides picked labels.
    pub fn answers(self: *const Wizard) ![]const protocol.UserInputAnswer {
        const a = self.arena.allocator();
        const out = try a.alloc(protocol.UserInputAnswer, self.questions.len);
        for (self.questions, 0..) |q, ix| {
            const raw = self.typed[ix].items;
            const typed = if (q.multiline) raw else std.mem.trim(u8, raw, " \t\r\n");
            const labels: []const []const u8 = if (typed.len > 0 or q.multiline) blk: {
                const one = try a.alloc([]const u8, 1);
                one[0] = typed;
                break :blk one;
            } else blk: {
                var l: std.ArrayList([]const u8) = .empty;
                for (self.picked[ix].items) |p| if (p < q.options.len) try l.append(a, q.options[p]);
                break :blk l.items;
            };
            out[ix] = .{ .questionId = q.id, .labels = labels };
        }
        return out;
    }
};

/// `wizard_escape_goes_back`.
pub fn escapeGoesBack(input_focused: bool, input_empty: bool) bool {
    return !input_focused or input_empty;
}

pub const Pending = struct { request_id: []const u8, questions: []const protocol.UserInputQuestion };

/// `pending_input_request`: an unresolved input part on the LAST assistant
/// entry (whatever its run status). `src` has `len()` / `entry(i)`.
pub fn pendingInputRequest(src: anytype) ?Pending {
    var i = src.len();
    while (i > 0) {
        i -= 1;
        const e = src.entry(i);
        if (e.role != .assistant) continue;
        for (e.parts) |p| switch (p) {
            .input => |in| if (!in.resolved) return .{ .request_id = in.requestId, .questions = in.questions },
            else => {},
        };
        return null;
    }
    return null;
}

/// `input_request_resolved`: the transcript shows `request_id` resolved.
pub fn inputRequestResolved(src: anytype, request_id: []const u8) bool {
    for (0..src.len()) |i| for (src.entry(i).parts) |p| switch (p) {
        .input => |in| if (in.resolved and std.mem.eql(u8, in.requestId, request_id)) return true,
        else => {},
    };
    return false;
}

const testing = std.testing;
const Entries = struct {
    items: []const protocol.SessionMessageEntry,
    pub fn len(self: Entries) usize {
        return self.items.len;
    }
    pub fn entry(self: Entries, i: usize) *const protocol.SessionMessageEntry {
        return &self.items[i];
    }
};

fn mkq(id: []const u8, opts: []const []const u8, multi: bool) protocol.UserInputQuestion {
    return .{ .id = id, .header = "Pick", .question = "Which?", .options = opts, .multiSelect = multi };
}

test "wizard pages, auto-advance, multi-select, typed overrides" {
    const qs = [_]protocol.UserInputQuestion{
        mkq("a", &.{ "One", "Two" }, false),
        mkq("b", &.{ "X", "Y", "Z" }, true),
        .{ .id = "c", .header = "H", .question = "Why?", .options = &.{"Because"}, .prefill = "pre" },
    };
    var w = try Wizard.init(testing.allocator, "req-1", &qs);
    defer w.deinit(testing.allocator);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("1/3", w.counter(&buf));
    try testing.expect(w.select(1) == .auto_advance);
    try testing.expect(w.isPicked(1));
    try testing.expect(w.advance() == .stay);
    try testing.expect(w.pressNumber(1) == .stay);
    try testing.expect(w.pressNumber(3) == .stay);
    try testing.expect(w.pressNumber(1) == .stay); // toggles X off
    try testing.expect(!w.isPicked(0));
    try testing.expect(w.back());
    try testing.expect(!w.back());
    _ = w.advance();
    _ = w.advance();
    try testing.expectEqualStrings("pre", w.typedText());
    w.setTyped("  my own  ");
    const step = w.advance();
    const ans = step.done;
    try testing.expectEqual(@as(usize, 3), ans.len);
    try testing.expectEqualStrings("Two", ans[0].labels[0]);
    try testing.expectEqualStrings("Z", ans[1].labels[0]);
    try testing.expectEqualStrings("my own", ans[2].labels[0]);
}

test "pending input is read off the last assistant entry" {
    var p1 = [_]protocol.MessagePart{.{ .input = .{ .id = "i", .requestId = "r1", .questions = &.{} } }};
    var p2 = [_]protocol.MessagePart{.{ .text = .{ .id = "t", .text = "steer" } }};
    var p3 = [_]protocol.MessagePart{.{ .input = .{ .id = "i", .requestId = "r1", .questions = &.{}, .resolved = true } }};
    const e = [_]protocol.SessionMessageEntry{
        .{ .id = "a", .role = .assistant, .parts = &p1, .createdAt = 1, .deviceId = "d" },
        .{ .id = "u", .role = .user, .parts = &p2, .createdAt = 2, .deviceId = "d" },
    };
    try testing.expectEqualStrings("r1", pendingInputRequest(Entries{ .items = &e }).?.request_id);
    try testing.expect(!inputRequestResolved(Entries{ .items = &e }, "r1"));
    const e2 = [_]protocol.SessionMessageEntry{.{ .id = "a", .role = .assistant, .parts = &p3, .createdAt = 1, .deviceId = "d" }};
    try testing.expect(pendingInputRequest(Entries{ .items = &e2 }) == null);
    try testing.expect(inputRequestResolved(Entries{ .items = &e2 }, "r1"));
    try testing.expect(escapeGoesBack(false, false));
    try testing.expect(!escapeGoesBack(true, false));
}
