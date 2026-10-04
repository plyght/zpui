//! `KeyContext` and `KeyBindingContextPredicate` (gpui `keymap/context.rs`).
//!
//! A `KeyContext` is the set of identifiers / `key=value` pairs an element contributes to
//! the dispatch path (`"Editor mode=full"`). A `Predicate` is the small boolean language used
//! in keymaps: `Editor && !Terminal`, `os == macos`, `Workspace > Pane`, `a || (b != c)`.
//!
//! Strings are borrowed: `KeyContext` entries and predicate identifiers slice into the
//! source passed to `parse` (or the strings given to `add`/`set`), which must outlive them.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const KeyContext = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct {
        key: []const u8,
        value: ?[]const u8 = null,
    };

    pub const empty: KeyContext = .{};

    /// `os` = macos | linux | windows | unknown (gpui `new_with_defaults`).
    pub fn initWithDefaults(gpa: Allocator) Allocator.Error!KeyContext {
        var c: KeyContext = .{};
        try c.set(gpa, "os", switch (builtin.os.tag) {
            .macos => "macos",
            .linux, .freebsd => "linux",
            .windows => "windows",
            else => "unknown",
        });
        return c;
    }

    pub fn deinit(self: *KeyContext, gpa: Allocator) void {
        self.entries.deinit(gpa);
        self.* = .{};
    }

    pub fn clone(self: *const KeyContext, gpa: Allocator) Allocator.Error!KeyContext {
        return .{ .entries = try self.entries.clone(gpa) };
    }

    /// Parse `"Editor mode = full"`: identifiers and `key=value` pairs separated by whitespace.
    pub fn parse(gpa: Allocator, source: []const u8) Allocator.Error!KeyContext {
        var c: KeyContext = .{};
        errdefer c.deinit(gpa);
        var s = skipWhitespace(source);
        while (s.len > 0) {
            const key_len = identLen(s, false);
            const key = s[0..key_len];
            s = skipWhitespace(s[key_len..]);
            if (s.len > 0 and s[0] == '=') {
                s = skipWhitespace(s[1..]);
                const vlen = identLen(s, false);
                try c.set(gpa, key, s[0..vlen]);
                s = skipWhitespace(s[vlen..]);
            } else {
                try c.add(gpa, key);
                if (key_len == 0) s = skipWhitespace(s[1..]); // skip a stray character
            }
        }
        return c;
    }

    pub fn isEmpty(self: *const KeyContext) bool {
        return self.entries.items.len == 0;
    }

    pub fn clear(self: *KeyContext) void {
        self.entries.clearRetainingCapacity();
    }

    /// Add an identifier unless the key is already present.
    pub fn add(self: *KeyContext, gpa: Allocator, identifier: []const u8) Allocator.Error!void {
        if (identifier.len == 0 or self.contains(identifier)) return;
        try self.entries.append(gpa, .{ .key = identifier });
    }

    /// Set `key=value` unless the key is already present.
    pub fn set(self: *KeyContext, gpa: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
        if (self.contains(key)) return;
        try self.entries.append(gpa, .{ .key = key, .value = value });
    }

    pub fn extend(self: *KeyContext, gpa: Allocator, other: *const KeyContext) Allocator.Error!void {
        for (other.entries.items) |e| {
            if (!self.contains(e.key)) try self.entries.append(gpa, e);
        }
    }

    pub fn contains(self: *const KeyContext, key: []const u8) bool {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.key, key)) return true;
        return false;
    }

    pub fn get(self: *const KeyContext, key: []const u8) ?[]const u8 {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }

    /// The first bare identifier (usually the component name).
    pub fn primary(self: *const KeyContext) ?Entry {
        for (self.entries.items) |e| if (e.value == null) return e;
        return null;
    }

    pub fn eql(a: *const KeyContext, b: *const KeyContext) bool {
        if (a.entries.items.len != b.entries.items.len) return false;
        for (a.entries.items, b.entries.items) |x, y| {
            if (!std.mem.eql(u8, x.key, y.key)) return false;
            if ((x.value == null) != (y.value == null)) return false;
            if (x.value) |xv| if (!std.mem.eql(u8, xv, y.value.?)) return false;
        }
        return true;
    }

    pub fn format(self: KeyContext, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.entries.items, 0..) |e, i| {
            if (i > 0) try w.writeByte(' ');
            if (e.value) |v| try w.print("{s}={s}", .{ e.key, v }) else try w.writeAll(e.key);
        }
    }
};

fn isIdentifierChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c >= 0x80;
}

fn isVimOperatorChar(c: u8) bool {
    return c == '>' or c == '<' or c == '~' or c == '"' or c == '?';
}

fn identLen(s: []const u8, allow_vim: bool) usize {
    var i: usize = 0;
    while (i < s.len and (isIdentifierChar(s[i]) or (allow_vim and isVimOperatorChar(s[i])))) i += 1;
    return i;
}

fn skipWhitespace(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and std.ascii.isWhitespace(s[i])) i += 1;
    return s[i..];
}

pub const ParseError = Allocator.Error || error{
    UnexpectedEnd,
    UnexpectedCharacter,
    ExpectedCloseParen,
    /// `==` / `!=` with a non-identifier operand.
    OperandsMustBeIdentifiers,
};

/// gpui `KeyBindingContextPredicate`.
pub const Predicate = union(enum) {
    identifier: []const u8,
    equal: [2][]const u8,
    not_equal: [2][]const u8,
    /// `parent > child`: child matches somewhere below parent.
    descendant: [2]*const Predicate,
    not: *const Predicate,
    @"and": [2]*const Predicate,
    @"or": [2]*const Predicate,

    const prec_child = 1;
    const prec_or = 2;
    const prec_and = 3;
    const prec_eq = 4;
    const prec_not = 5;

    /// Parse `source`. Nodes are allocated with `arena` (free them all at once); identifier
    /// strings slice into `source`.
    pub fn parse(arena: Allocator, source: []const u8) ParseError!*const Predicate {
        var p: Parser = .{ .arena = arena, .rest = skipWhitespace(source) };
        const pred = try p.parseExpr(0);
        if (p.rest.len != 0) return error.UnexpectedCharacter;
        return pred;
    }

    const Parser = struct {
        arena: Allocator,
        rest: []const u8,

        const Op = struct { str: []const u8, prec: u32, kind: enum { child, @"and", @"or", eq, neq } };
        const ops = [_]Op{
            .{ .str = ">", .prec = prec_child, .kind = .child },
            .{ .str = "&&", .prec = prec_and, .kind = .@"and" },
            .{ .str = "||", .prec = prec_or, .kind = .@"or" },
            .{ .str = "==", .prec = prec_eq, .kind = .eq },
            .{ .str = "!=", .prec = prec_eq, .kind = .neq },
        };

        fn node(p: *Parser, v: Predicate) Allocator.Error!*const Predicate {
            const n = try p.arena.create(Predicate);
            n.* = v;
            return n;
        }

        fn parseExpr(p: *Parser, min_prec: u32) ParseError!*const Predicate {
            var pred = try p.parsePrimary();
            outer: while (true) {
                for (ops) |op| {
                    if (std.mem.startsWith(u8, p.rest, op.str) and op.prec >= min_prec) {
                        p.rest = skipWhitespace(p.rest[op.str.len..]);
                        const right = try p.parseExpr(op.prec + 1);
                        pred = switch (op.kind) {
                            .child => try p.node(.{ .descendant = .{ pred, right } }),
                            .@"and" => try p.node(.{ .@"and" = .{ pred, right } }),
                            .@"or" => try p.node(.{ .@"or" = .{ pred, right } }),
                            .eq, .neq => blk: {
                                if (pred.* != .identifier or right.* != .identifier) return error.OperandsMustBeIdentifiers;
                                const pair: [2][]const u8 = .{ pred.identifier, right.identifier };
                                break :blk try p.node(if (op.kind == .eq) .{ .equal = pair } else .{ .not_equal = pair });
                            },
                        };
                        continue :outer;
                    }
                }
                break;
            }
            return pred;
        }

        fn parsePrimary(p: *Parser) ParseError!*const Predicate {
            if (p.rest.len == 0) return error.UnexpectedEnd;
            const c = p.rest[0];
            if (c == '(') {
                p.rest = skipWhitespace(p.rest[1..]);
                const pred = try p.parseExpr(0);
                if (p.rest.len == 0 or p.rest[0] != ')') return error.ExpectedCloseParen;
                p.rest = skipWhitespace(p.rest[1..]);
                return pred;
            }
            if (c == '!') {
                p.rest = skipWhitespace(p.rest[1..]);
                const inner = try p.parseExpr(prec_not);
                return p.node(.{ .not = inner });
            }
            if (isIdentifierChar(c)) {
                const len = identLen(p.rest, true);
                const ident = p.rest[0..len];
                p.rest = skipWhitespace(p.rest[len..]);
                return p.node(.{ .identifier = ident });
            }
            if (isVimOperatorChar(c)) {
                const ident = p.rest[0..1];
                p.rest = skipWhitespace(p.rest[1..]);
                return p.node(.{ .identifier = ident });
            }
            return error.UnexpectedCharacter;
        }
    };

    /// The deepest depth (number of contexts from the root) at which the predicate matches.
    pub fn depthOf(self: *const Predicate, contexts: []const KeyContext) ?usize {
        var depth = contexts.len + 1;
        while (depth > 0) {
            depth -= 1;
            if (self.evalInner(contexts[0..depth], contexts)) return depth;
        }
        return null;
    }

    /// Evaluate against contexts ordered root → leaf.
    pub fn eval(self: *const Predicate, contexts: []const KeyContext) bool {
        return self.evalInner(contexts, contexts);
    }

    pub fn evalInner(self: *const Predicate, contexts: []const KeyContext, all: []const KeyContext) bool {
        if (contexts.len == 0) return false;
        const context = &contexts[contexts.len - 1];
        switch (self.*) {
            .identifier => |name| return context.contains(name),
            .equal => |kv| return if (context.get(kv[0])) |v| std.mem.eql(u8, v, kv[1]) else false,
            .not_equal => |kv| return if (context.get(kv[0])) |v| !std.mem.eql(u8, v, kv[1]) else true,
            .not => |pred| {
                for (0..all.len) |i| {
                    if (pred.evalInner(all[0 .. i + 1], all)) return false;
                }
                return true;
            },
            .descendant => |pc| {
                for (0..contexts.len - 1) |i| {
                    if (pc[0].evalInner(contexts[0 .. i + 1], all)) {
                        return pc[1].evalInner(contexts[i + 1 ..], contexts[i + 1 ..]);
                    }
                }
                return false;
            },
            .@"and" => |lr| return lr[0].evalInner(contexts, all) and lr[1].evalInner(contexts, all),
            .@"or" => |lr| return lr[0].evalInner(contexts, all) or lr[1].evalInner(contexts, all),
        }
    }

    /// Whether this predicate matches every context the other one matches.
    pub fn isSuperset(self: *const Predicate, other: *const Predicate) bool {
        if (self.eql(other)) return true;
        if (self.* == .@"or") return self.@"or"[0].isSuperset(other) or self.@"or"[1].isSuperset(other);
        return switch (other.*) {
            .descendant => |pc| self.isSuperset(pc[1]),
            .@"and" => |lr| self.isSuperset(lr[0]) or self.isSuperset(lr[1]),
            else => false,
        };
    }

    pub fn eql(a: *const Predicate, b: *const Predicate) bool {
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .identifier => |x| std.mem.eql(u8, x, b.identifier),
            .equal => |x| std.mem.eql(u8, x[0], b.equal[0]) and std.mem.eql(u8, x[1], b.equal[1]),
            .not_equal => |x| std.mem.eql(u8, x[0], b.not_equal[0]) and std.mem.eql(u8, x[1], b.not_equal[1]),
            .not => |x| x.eql(b.not),
            .descendant => |x| x[0].eql(b.descendant[0]) and x[1].eql(b.descendant[1]),
            .@"and" => |x| x[0].eql(b.@"and"[0]) and x[1].eql(b.@"and"[1]),
            .@"or" => |x| x[0].eql(b.@"or"[0]) and x[1].eql(b.@"or"[1]),
        };
    }

    /// Canonical text form; round-trips through `parse`.
    pub fn format(self: *const Predicate, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.*) {
            .identifier => |n| try w.writeAll(n),
            .equal => |kv| try w.print("{s} == {s}", .{ kv[0], kv[1] }),
            .not_equal => |kv| try w.print("{s} != {s}", .{ kv[0], kv[1] }),
            .descendant => |pc| try w.print("{f} > {f}", .{ pc[0], pc[1] }),
            .not => |p| if (p.* == .identifier) try w.print("!{s}", .{p.identifier}) else try w.print("!({f})", .{p}),
            .@"and" => {
                var first = true;
                try self.fmtJoined(w, " && ", .@"and", &first);
            },
            .@"or" => {
                var first = true;
                try self.fmtJoined(w, " || ", .@"or", &first);
            },
        }
    }

    fn fmtJoined(self: *const Predicate, w: *std.Io.Writer, sep: []const u8, comptime op: std.meta.Tag(Predicate), first: *bool) std.Io.Writer.Error!void {
        if (self.* == op) {
            const lr = @field(self.*, @tagName(op));
            try lr[0].fmtJoined(w, sep, op, first);
            try lr[1].fmtJoined(w, sep, op, first);
            return;
        }
        if (!first.*) try w.writeAll(sep);
        first.* = false;
        const other: std.meta.Tag(Predicate) = if (op == .@"and") .@"or" else .@"and";
        if (self.* == other) try w.print("({f})", .{self}) else try self.format(w);
    }
};

// ---------------------------------------------------------------------------------------

const testing = std.testing;

fn ctx(arena: Allocator, s: []const u8) KeyContext {
    return KeyContext.parse(arena, s) catch unreachable;
}

test "KeyContext.parse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var expected: KeyContext = .{};
    try expected.add(a, "baz");
    try expected.set(a, "foo", "bar");
    try testing.expect(ctx(a, "baz foo=bar").eql(&expected));
    try testing.expect(ctx(a, "baz foo = bar").eql(&expected));
    try testing.expect(ctx(a, "  baz foo   =   bar baz").eql(&expected));
    try testing.expect(ctx(a, " baz foo = bar").eql(&expected));
    const c = ctx(a, "Editor mode=full");
    try testing.expectEqualStrings("full", c.get("mode").?);
    try testing.expectEqualStrings("Editor", c.primary().?.key);
    try testing.expectFmt("Editor mode=full", "{f}", .{c});
}

test "Predicate parse: identifiers, negation, equality" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("abc12", (try Predicate.parse(a, "abc12")).identifier);
    try testing.expectEqualStrings("_1a", (try Predicate.parse(a, "_1a")).identifier);
    const n = try Predicate.parse(a, "!abc");
    try testing.expectEqualStrings("abc", n.not.identifier);
    const nn = try Predicate.parse(a, " ! ! abc");
    try testing.expectEqualStrings("abc", nn.not.not.identifier);
    const eq = try Predicate.parse(a, "a == b");
    try testing.expectEqualStrings("b", eq.equal[1]);
    const ne = try Predicate.parse(a, "c!=d");
    try testing.expectEqualStrings("c", ne.not_equal[0]);
    try testing.expectError(error.OperandsMustBeIdentifiers, Predicate.parse(a, "c == !d"));
    try testing.expectError(error.ExpectedCloseParen, Predicate.parse(a, "(a && b"));
    try testing.expectError(error.UnexpectedEnd, Predicate.parse(a, "a &&"));
    try testing.expectError(error.UnexpectedCharacter, Predicate.parse(a, "a b"));
}

test "Predicate parse: boolean precedence and parens" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // a || (!b && c)
    const p1 = try Predicate.parse(a, "a || !b && c");
    try testing.expectEqualStrings("a", p1.@"or"[0].identifier);
    try testing.expectEqualStrings("b", p1.@"or"[1].@"and"[0].not.identifier);
    // (a && b) || (c && d)
    const p2 = try Predicate.parse(a, "a && b || c&&d");
    try testing.expectEqualStrings("d", p2.@"or"[1].@"and"[1].identifier);
    // ((a && b) && c) && d  (left-assoc)
    const p3 = try Predicate.parse(a, "a && b && c && d");
    try testing.expectEqualStrings("d", p3.@"and"[1].identifier);
    try testing.expectEqualStrings("a", p3.@"and"[0].@"and"[0].@"and"[0].identifier);
    const p4 = try Predicate.parse(a, "a == b && c || d == e && f");
    try testing.expectEqualStrings("e", p4.@"or"[1].@"and"[0].equal[1]);
    const p5 = try Predicate.parse(a, "a && (b == c || d != e)");
    try testing.expectEqualStrings("e", p5.@"and"[1].@"or"[1].not_equal[1]);
    const p6 = try Predicate.parse(a, " ( a || b ) ");
    try testing.expect(p6.* == .@"or");
}

fn expectEval(a: Allocator, pred: []const u8, contexts: []const []const u8, expected: bool) !void {
    const p = try Predicate.parse(a, pred);
    var list: std.ArrayList(KeyContext) = .empty;
    for (contexts) |c| try list.append(a, ctx(a, c));
    testing.expectEqual(expected, p.eval(list.items)) catch |err| {
        std.debug.print("predicate `{s}` on {d} contexts\n", .{ pred, contexts.len });
        return err;
    };
}

test "Predicate eval: child operator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try expectEval(a, "parent > child", &.{ "parent", "child" }, true);
    try expectEval(a, "parent > child", &.{ "grandparent", "parent", "child" }, true);
    try expectEval(a, "parent > child", &.{ "other", "child" }, false);
    try expectEval(a, "parent > child", &.{ "parent", "other", "child" }, true);
    try expectEval(a, "parent > child", &.{}, false);
    try expectEval(a, "parent > child", &.{"child"}, false);
    try expectEval(a, "parent > child", &.{"parent"}, false);
    try expectEval(a, "child > child", &.{"child"}, false);
    try expectEval(a, "child > child", &.{ "child", "child" }, true);
}

test "Predicate eval: not operator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try expectEval(a, "!editor", &.{"workspace"}, true);
    try expectEval(a, "!editor", &.{"editor"}, false);
    try expectEval(a, "!editor", &.{ "editor", "workspace" }, false);
    try expectEval(a, "!editor", &.{ "workspace", "editor" }, false);
    try expectEval(a, "!editor && workspace", &.{"workspace"}, true);
    try expectEval(a, "!editor && workspace", &.{ "editor", "workspace" }, false);
    try expectEval(a, "!(mode == full)", &.{"mode=full"}, false);
    try expectEval(a, "!(mode == full)", &.{"mode=partial"}, true);
    try expectEval(a, "!(parent > child)", &.{"parent"}, true);
    try expectEval(a, "!(parent > child)", &.{"child"}, true);
    try expectEval(a, "!(parent > child)", &.{ "parent", "child" }, false);
    try expectEval(a, "parent > !child", &.{"parent"}, false);
    try expectEval(a, "parent > !child", &.{"child"}, false);
    try expectEval(a, "parent > !child", &.{ "parent", "child" }, false);
    try expectEval(a, "!!editor", &.{"editor"}, true);
    try expectEval(a, "!!editor", &.{"workspace"}, false);
    const wpe: []const []const u8 = &.{ "Workspace", "Pane", "Editor" };
    try expectEval(a, "Pane > (Pane > Editor)", wpe, false);
    try expectEval(a, "Workspace > Pane > Editor", wpe, true);
    try expectEval(a, "(Pane > Pane) > Editor", wpe, false);
    try expectEval(a, "Pane > !Workspace", &.{ "Pane", "Editor" }, true);
    try expectEval(a, "Pane > !Workspace", &.{ "Pane", "Workspace" }, false);
    try expectEval(a, "!Workspace", &.{"Workspace"}, false);
    try expectEval(a, "!Workspace", &.{"Pane"}, true);
    try expectEval(a, "!Workspace", wpe, false);
}

test "Predicate eval: equality, os default, depthOf" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try expectEval(a, "Editor && !Terminal", &.{ "Workspace", "Editor" }, true);
    try expectEval(a, "Editor && !Terminal", &.{ "Terminal", "Editor" }, false);
    try expectEval(a, "mode != full", &.{"Editor"}, true);
    try expectEval(a, "mode != full", &.{"Editor mode=full"}, false);

    const defaults = try KeyContext.initWithDefaults(a);
    const os_name = defaults.get("os").?;
    const src = try std.fmt.allocPrint(a, "os == {s}", .{os_name});
    const p = try Predicate.parse(a, src);
    try testing.expect(p.eval(&.{defaults}));

    const pane = try Predicate.parse(a, "pane");
    const stack = [_]KeyContext{ ctx(a, "workspace"), ctx(a, "pane"), ctx(a, "editor") };
    try testing.expectEqual(@as(?usize, 2), pane.depthOf(&stack));
    const editor = try Predicate.parse(a, "editor");
    try testing.expectEqual(@as(?usize, 3), editor.depthOf(&stack));
    const none = try Predicate.parse(a, "terminal");
    try testing.expectEqual(@as(?usize, null), none.depthOf(&stack));
}

test "Predicate isSuperset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "editor", "editor", true },
        .{ "editor", "workspace", false },
        .{ "editor", "editor && vim_mode", true },
        .{ "editor", "mode == full && editor", true },
        .{ "editor && mode == full", "editor", false },
        .{ "editor", "something > editor", true },
        .{ "editor", "editor > menu", false },
        .{ "foo || bar || baz", "bar", true },
        .{ "foo || bar || baz", "quux", false },
    };
    for (cases) |c| {
        const x = try Predicate.parse(a, c[0]);
        const y = try Predicate.parse(a, c[1]);
        try testing.expectEqual(c[2], x.isSuperset(y));
    }
}

test "Predicate display round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_][]const u8{
        "a",                                 "a == b",
        "a != b",                            "a > b",
        "!a",                                "!(a && b)",
        "!(a || b)",                         "a && b",
        "a && b && c",                       "a || b",
        "a || b || c",                       "a || (b && c)",
        "a && b == c && !(d > e) && f == g", "a && (b || c) && d",
        "a || (b && c) || d",
    };
    for (cases) |src| {
        const p = try Predicate.parse(a, src);
        const out = try std.fmt.allocPrint(a, "{f}", .{p});
        try testing.expectEqualStrings(src, out);
        try testing.expect(p.eql(try Predicate.parse(a, out)));
    }
}
