//! A tree-sitter query plus the predicate handling the Rust bindings layer on
//! top of the C API (`tree_sitter::Query`): text predicates (`#eq?`,
//! `#match?`, `#any-of?` and their negated / `any-` forms) that filter
//! matches, `#set!` property settings, and `#is?` / `#is-not?` property
//! predicates. Any other predicate is accepted and ignored, as in Rust.

const std = @import("std");
const c = @import("ts_c");
const Regex = @import("regex.zig").Regex;
const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidQuery, OutOfMemory };

pub const Property = struct {
    key: []const u8,
    value: ?[]const u8,
    capture_id: ?u32,
};

const TextPredicate = union(enum) {
    eq_capture: struct { a: u32, b: u32, positive: bool, match_all: bool },
    eq_string: struct { capture: u32, value: []const u8, positive: bool, match_all: bool },
    match_string: struct { capture: u32, regex: *Regex, positive: bool, match_all: bool },
    any_string: struct { capture: u32, values: []const []const u8, positive: bool },
};

const Pattern = struct {
    text_predicates: []const TextPredicate,
    property_settings: []const Property,
    property_predicates: []const PropertyPredicate,
};

pub const PropertyPredicate = struct { property: Property, positive: bool };

pub const Query = struct {
    ptr: *c.TSQuery,
    arena: std.heap.ArenaAllocator,
    regexes: std.ArrayList(*Regex),
    capture_names: []const []const u8,
    patterns: []const Pattern,

    pub fn init(gpa: Allocator, language: *const c.TSLanguage, source: []const u8) Error!Query {
        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = c.TSQueryErrorNone;
        const ptr = c.ts_query_new(language, source.ptr, @intCast(source.len), &error_offset, &error_type) orelse
            return error.InvalidQuery;
        var self: Query = .{
            .ptr = ptr,
            .arena = .init(gpa),
            .regexes = .empty,
            .capture_names = &.{},
            .patterns = &.{},
        };
        errdefer self.deinit();
        const a = self.arena.allocator();

        const capture_count = c.ts_query_capture_count(ptr);
        const names = try a.alloc([]const u8, capture_count);
        for (names, 0..) |*n, i| {
            var len: u32 = 0;
            const p = c.ts_query_capture_name_for_id(ptr, @intCast(i), &len);
            n.* = p[0..len];
        }
        self.capture_names = names;

        const string_count = c.ts_query_string_count(ptr);
        const strings = try a.alloc([]const u8, string_count);
        for (strings, 0..) |*s, i| {
            var len: u32 = 0;
            const p = c.ts_query_string_value_for_id(ptr, @intCast(i), &len);
            s.* = p[0..len];
        }

        const pattern_count = c.ts_query_pattern_count(ptr);
        const patterns = try a.alloc(Pattern, pattern_count);
        for (patterns, 0..) |*pattern, pi| {
            var step_count: u32 = 0;
            const raw = c.ts_query_predicates_for_pattern(ptr, @intCast(pi), &step_count);
            const steps: []const c.TSQueryPredicateStep = if (step_count > 0) raw[0..step_count] else &.{};
            var text: std.ArrayList(TextPredicate) = .empty;
            var settings: std.ArrayList(Property) = .empty;
            var props: std.ArrayList(PropertyPredicate) = .empty;
            var start: usize = 0;
            while (start < steps.len) {
                var end = start;
                while (end < steps.len and steps[end].type != c.TSQueryPredicateStepTypeDone) end += 1;
                const p = steps[start..end];
                start = end + 1;
                if (p.len == 0) continue;
                if (p[0].type != c.TSQueryPredicateStepTypeString) return error.InvalidQuery;
                const op = strings[p[0].value_id];
                const is_capture = struct {
                    fn f(s: c.TSQueryPredicateStep) bool {
                        return s.type == c.TSQueryPredicateStepTypeCapture;
                    }
                }.f;
                if (eqlAny(op, &.{ "eq?", "not-eq?", "any-eq?", "any-not-eq?" })) {
                    if (p.len != 3 or !is_capture(p[1])) return error.InvalidQuery;
                    const positive = eqlAny(op, &.{ "eq?", "any-eq?" });
                    const match_all = eqlAny(op, &.{ "eq?", "not-eq?" });
                    try text.append(a, if (is_capture(p[2]))
                        .{ .eq_capture = .{ .a = p[1].value_id, .b = p[2].value_id, .positive = positive, .match_all = match_all } }
                    else
                        .{ .eq_string = .{ .capture = p[1].value_id, .value = strings[p[2].value_id], .positive = positive, .match_all = match_all } });
                } else if (eqlAny(op, &.{ "match?", "not-match?", "any-match?", "any-not-match?" })) {
                    if (p.len != 3 or !is_capture(p[1]) or is_capture(p[2])) return error.InvalidQuery;
                    const re = try a.create(Regex);
                    re.* = Regex.compile(gpa, strings[p[2].value_id]) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.InvalidRegex => return error.InvalidQuery,
                    };
                    self.regexes.append(gpa, re) catch |e| {
                        re.deinit();
                        return e;
                    };
                    try text.append(a, .{ .match_string = .{
                        .capture = p[1].value_id,
                        .regex = re,
                        .positive = eqlAny(op, &.{ "match?", "any-match?" }),
                        .match_all = eqlAny(op, &.{ "match?", "not-match?" }),
                    } });
                } else if (std.mem.eql(u8, op, "set!")) {
                    try settings.append(a, try parseProperty(strings, p[1..]));
                } else if (eqlAny(op, &.{ "is?", "is-not?" })) {
                    try props.append(a, .{ .property = try parseProperty(strings, p[1..]), .positive = std.mem.eql(u8, op, "is?") });
                } else if (eqlAny(op, &.{ "any-of?", "not-any-of?" })) {
                    if (p.len < 2 or !is_capture(p[1])) return error.InvalidQuery;
                    const values = try a.alloc([]const u8, p.len - 2);
                    for (p[2..], values) |arg, *v| {
                        if (is_capture(arg)) return error.InvalidQuery;
                        v.* = strings[arg.value_id];
                    }
                    try text.append(a, .{ .any_string = .{
                        .capture = p[1].value_id,
                        .values = values,
                        .positive = std.mem.eql(u8, op, "any-of?"),
                    } });
                }
                // Anything else is a "general predicate": ignored here.
            }
            pattern.* = .{ .text_predicates = text.items, .property_settings = settings.items, .property_predicates = props.items };
        }
        self.patterns = patterns;
        return self;
    }

    pub fn deinit(self: *Query) void {
        const gpa = self.arena.child_allocator;
        for (self.regexes.items) |re| re.deinit();
        self.regexes.deinit(gpa);
        self.arena.deinit();
        c.ts_query_delete(self.ptr);
    }

    pub fn patternCount(self: *const Query) usize {
        return self.patterns.len;
    }

    pub fn startByteForPattern(self: *const Query, index: usize) usize {
        return c.ts_query_start_byte_for_pattern(self.ptr, @intCast(index));
    }

    pub fn disablePattern(self: *Query, index: usize) void {
        c.ts_query_disable_pattern(self.ptr, @intCast(index));
    }

    pub fn propertySettings(self: *const Query, index: usize) []const Property {
        return self.patterns[index].property_settings;
    }

    pub fn propertyPredicates(self: *const Query, index: usize) []const PropertyPredicate {
        return self.patterns[index].property_predicates;
    }

    /// `QueryMatch::satisfies_text_predicates` for a byte-slice text provider.
    pub fn satisfiesTextPredicates(self: *const Query, m: *const c.TSQueryMatch, source: []const u8) bool {
        const captures: []const c.TSQueryCapture = if (m.capture_count > 0) m.captures[0..m.capture_count] else &.{};
        for (self.patterns[m.pattern_index].text_predicates) |pred| {
            const ok = switch (pred) {
                .eq_capture => |e| blk: {
                    var it1 = NodeIter{ .captures = captures, .index = e.a };
                    var it2 = NodeIter{ .captures = captures, .index = e.b };
                    while (true) {
                        const n1 = it1.peek() orelse break;
                        const n2 = it2.peek() orelse break;
                        it1.advance();
                        it2.advance();
                        const is_match = std.mem.eql(u8, nodeText(n1, source), nodeText(n2, source));
                        if (is_match != e.positive and e.match_all) break :blk false;
                        if (is_match == e.positive and !e.match_all) break :blk true;
                    }
                    break :blk it1.peek() == null and it2.peek() == null;
                },
                .eq_string => |e| blk: {
                    var it = NodeIter{ .captures = captures, .index = e.capture };
                    while (it.next()) |n| {
                        const is_match = std.mem.eql(u8, nodeText(n, source), e.value);
                        if (is_match != e.positive and e.match_all) break :blk false;
                        if (is_match == e.positive and !e.match_all) break :blk true;
                    }
                    break :blk true;
                },
                .match_string => |e| blk: {
                    var it = NodeIter{ .captures = captures, .index = e.capture };
                    while (it.next()) |n| {
                        const is_match = e.regex.isMatch(nodeText(n, source));
                        if (is_match != e.positive and e.match_all) break :blk false;
                        if (is_match == e.positive and !e.match_all) break :blk true;
                    }
                    break :blk true;
                },
                .any_string => |e| blk: {
                    var it = NodeIter{ .captures = captures, .index = e.capture };
                    while (it.next()) |n| {
                        const text = nodeText(n, source);
                        var found = false;
                        for (e.values) |v| {
                            if (std.mem.eql(u8, text, v)) {
                                found = true;
                                break;
                            }
                        }
                        if (found != e.positive) break :blk false;
                    }
                    break :blk true;
                },
            };
            if (!ok) return false;
        }
        return true;
    }
};

const NodeIter = struct {
    captures: []const c.TSQueryCapture,
    index: u32,
    pos: usize = 0,

    fn peek(self: *NodeIter) ?c.TSNode {
        while (self.pos < self.captures.len) : (self.pos += 1) {
            if (self.captures[self.pos].index == self.index) return self.captures[self.pos].node;
        }
        return null;
    }

    fn advance(self: *NodeIter) void {
        self.pos += 1;
    }

    fn next(self: *NodeIter) ?c.TSNode {
        const n = self.peek() orelse return null;
        self.advance();
        return n;
    }
};

pub fn nodeText(node: c.TSNode, source: []const u8) []const u8 {
    const start = c.ts_node_start_byte(node);
    const end = c.ts_node_end_byte(node);
    return source[@min(start, source.len)..@min(end, source.len)];
}

fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

fn parseProperty(strings: []const []const u8, args: []const c.TSQueryPredicateStep) Error!Property {
    if (args.len == 0 or args.len > 3) return error.InvalidQuery;
    var capture_id: ?u32 = null;
    var key: ?[]const u8 = null;
    var value: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.type == c.TSQueryPredicateStepTypeCapture) {
            if (capture_id != null) return error.InvalidQuery;
            capture_id = arg.value_id;
        } else if (key == null) {
            key = strings[arg.value_id];
        } else if (value == null) {
            value = strings[arg.value_id];
        } else return error.InvalidQuery;
    }
    return .{ .key = key orelse return error.InvalidQuery, .value = value, .capture_id = capture_id };
}
