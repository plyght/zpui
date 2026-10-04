//! A small backtracking regex with capture groups, enough for the parser's
//! fixed patterns (Rust `regex` crate semantics for them: leftmost-first
//! alternation, greedy and lazy quantifiers, `^`/`$` anchoring the whole
//! text, `.` = any code point but `\n`, Unicode `\s`/`\w`, byte offsets).

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Error = error{ OutOfMemory, InvalidRegex };
const util = @import("util.zig");

const Class = struct {
    negated: bool,
    /// Inclusive ASCII ranges.
    ranges: []const [2]u21,
    perl: enum { none, space, word, digit } = .none,

    fn matches(c: Class, cp: u21) bool {
        var hit = false;
        for (c.ranges) |r| {
            if (cp >= r[0] and cp <= r[1]) {
                hit = true;
                break;
            }
        }
        if (!hit) hit = switch (c.perl) {
            .none => false,
            .space => util.isWhitespace(cp),
            .word => isWord(cp),
            .digit => cp >= '0' and cp <= '9',
        };
        return hit != c.negated;
    }
};

fn isWord(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';
    // Unicode \w: letters, marks, digits, connector punctuation. Approximate with
    // "not whitespace and not common punctuation/symbol blocks".
    if (util.isWhitespace(cp)) return false;
    return switch (cp) {
        0x80...0xBF, 0xD7, 0xF7, 0x2000...0x206F, 0x20A0...0x20CF, 0x2190...0x2BFF, 0x3000...0x303F, 0xFE10...0xFE1F, 0xFE30...0xFE4F, 0xFF00...0xFF0F, 0x1F000...0x1FAFF => false,
        else => true,
    };
}

const Node = union(enum) {
    char: u21,
    any,
    class: Class,
    start,
    end,
    /// Alternatives; `cap` is the capture index (0 = non-capturing).
    group: struct { alts: []const []const Node, cap: usize },
    repeat: struct { node: *const Node, min: u32, max: ?u32, greedy: bool },
};

pub const Regex = struct {
    root: []const []const Node,
    ncaps: usize,
    names: []const ?[]const u8,

    pub fn compile(a: Allocator, pattern: []const u8) Error!Regex {
        var p: Parser = .{ .a = a, .src = pattern };
        try p.names.append(a, null); // group 0
        const alts = try p.parseAlts();
        if (p.i != pattern.len) return error.InvalidRegex;
        return .{ .root = alts, .ncaps = p.names.items.len, .names = p.names.items };
    }

    pub const Captures = struct {
        spans: []?[2]usize,
        names: []const ?[]const u8,
        text: []const u8,

        pub fn get(self: Captures, ix: usize) ?[]const u8 {
            if (ix >= self.spans.len) return null;
            const s = self.spans[ix] orelse return null;
            return self.text[s[0]..s[1]];
        }

        pub fn span(self: Captures, ix: usize) ?[2]usize {
            if (ix >= self.spans.len) return null;
            return self.spans[ix];
        }

        pub fn nameIndex(self: Captures, name: []const u8) ?usize {
            for (self.names, 0..) |n, i| if (n) |nn| if (std.mem.eql(u8, nn, name)) return i;
            return null;
        }

        pub fn named(self: Captures, n: []const u8) ?[]const u8 {
            return self.get(self.nameIndex(n) orelse return null);
        }

        pub fn nameSpan(self: Captures, n: []const u8) ?[2]usize {
            return self.span(self.nameIndex(n) orelse return null);
        }
    };

    /// First (leftmost) match starting at or after `from`.
    pub fn captures(self: *const Regex, a: Allocator, text: []const u8) Allocator.Error!?Captures {
        return self.capturesFrom(a, text, 0);
    }

    pub fn capturesFrom(self: *const Regex, a: Allocator, text: []const u8, from: usize) Allocator.Error!?Captures {
        const spans = try a.alloc(?[2]usize, self.ncaps);
        var start = from;
        while (start <= text.len) {
            @memset(spans, null);
            var m: Matcher = .{ .text = text, .caps = spans };
            const top: Cont = .{ .kind = .done };
            if (m.alts(self.root, start, &top)) |end| {
                spans[0] = .{ start, end };
                return .{ .spans = spans, .names = self.names, .text = text };
            }
            if (start == text.len) break;
            start += util.decodeAt(text, start).len;
        }
        return null;
    }

    pub fn isMatch(self: *const Regex, a: Allocator, text: []const u8) Allocator.Error!bool {
        return (try self.captures(a, text)) != null;
    }

    /// Non-overlapping matches (`find_iter`).
    pub fn findAll(self: *const Regex, a: Allocator, text: []const u8) Allocator.Error![]const [2]usize {
        var out: std.ArrayList([2]usize) = .empty;
        var pos: usize = 0;
        while (pos <= text.len) {
            const c = (try self.capturesFrom(a, text, pos)) orelse break;
            const s = c.spans[0].?;
            try out.append(a, s);
            pos = if (s[1] > s[0]) s[1] else s[1] + 1;
        }
        return out.items;
    }
};

const Cont = struct {
    kind: enum { done, seq, repeat, close },
    seq: []const Node = &.{},
    i: usize = 0,
    rep: ?*const Node = null,
    count: u32 = 0,
    cap: usize = 0,
    cap_start: usize = 0,
    next: ?*const Cont = null,
};

const Matcher = struct {
    text: []const u8,
    caps: []?[2]usize,
    steps: usize = 0,

    fn alts(m: *Matcher, list: []const []const Node, pos: usize, k: *const Cont) ?usize {
        for (list) |seq| {
            if (m.seqm(seq, 0, pos, k)) |e| return e;
        }
        return null;
    }

    fn cont(m: *Matcher, k: *const Cont, pos: usize) ?usize {
        m.steps += 1;
        if (m.steps > 2_000_000) return null;
        switch (k.kind) {
            .done => return pos,
            .seq => return m.seqm(k.seq, k.i, pos, k.next.?),
            .close => {
                const saved = m.caps[k.cap];
                m.caps[k.cap] = .{ k.cap_start, pos };
                if (m.cont(k.next.?, pos)) |e| return e;
                m.caps[k.cap] = saved;
                return null;
            },
            .repeat => return m.repeatm(k.rep.?, k.count, pos, k.next.?),
        }
    }

    fn seqm(m: *Matcher, seq: []const Node, i: usize, pos: usize, k: *const Cont) ?usize {
        if (i == seq.len) return m.cont(k, pos);
        const node = &seq[i];
        const rest: Cont = .{ .kind = .seq, .seq = seq, .i = i + 1, .next = k };
        return m.one(node, pos, &rest);
    }

    /// Match `node` at `pos`, then continue with `k`.
    fn one(m: *Matcher, node: *const Node, pos: usize, k: *const Cont) ?usize {
        switch (node.*) {
            .char => |c| {
                if (pos >= m.text.len) return null;
                const d = util.decodeAt(m.text, pos);
                if (d.cp != c) return null;
                return m.cont(k, pos + d.len);
            },
            .any => {
                if (pos >= m.text.len) return null;
                const d = util.decodeAt(m.text, pos);
                if (d.cp == '\n') return null;
                return m.cont(k, pos + d.len);
            },
            .class => |c| {
                if (pos >= m.text.len) return null;
                const d = util.decodeAt(m.text, pos);
                if (!c.matches(d.cp)) return null;
                return m.cont(k, pos + d.len);
            },
            .start => return if (pos == 0) m.cont(k, pos) else null,
            .end => return if (pos == m.text.len) m.cont(k, pos) else null,
            .group => |g| {
                if (g.cap == 0) return m.alts(g.alts, pos, k);
                const close: Cont = .{ .kind = .close, .cap = g.cap, .cap_start = pos, .next = k };
                return m.alts(g.alts, pos, &close);
            },
            .repeat => return m.repeatm(node, 0, pos, k),
        }
    }

    fn repeatm(m: *Matcher, node: *const Node, count: u32, pos: usize, k: *const Cont) ?usize {
        const r = node.repeat;
        const can_more = r.max == null or count < r.max.?;
        const again: Cont = .{ .kind = .repeat, .rep = node, .count = count + 1, .next = k };
        if (count < r.min) return m.one(r.node, pos, &again);
        if (r.greedy) {
            if (can_more) if (m.one(r.node, pos, &again)) |e| return e;
            return m.cont(k, pos);
        }
        if (m.cont(k, pos)) |e| return e;
        if (can_more) return m.one(r.node, pos, &again);
        return null;
    }
};

const Parser = struct {
    a: Allocator,
    src: []const u8,
    i: usize = 0,
    names: std.ArrayList(?[]const u8) = .empty,

    fn peek(p: *Parser) ?u8 {
        return if (p.i < p.src.len) p.src[p.i] else null;
    }

    fn parseAlts(p: *Parser) Error![]const []const Node {
        var alts: std.ArrayList([]const Node) = .empty;
        while (true) {
            try alts.append(p.a, try p.parseSeq());
            if (p.peek() == '|') {
                p.i += 1;
                continue;
            }
            break;
        }
        return alts.items;
    }

    fn parseSeq(p: *Parser) Error![]const Node {
        var seq: std.ArrayList(Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            var atom = try p.parseAtom();
            // Quantifier.
            if (p.peek()) |q| if (q == '*' or q == '+' or q == '?') {
                p.i += 1;
                var greedy = true;
                if (p.peek() == '?') {
                    greedy = false;
                    p.i += 1;
                }
                const inner = try p.a.create(Node);
                inner.* = atom;
                atom = .{ .repeat = .{
                    .node = inner,
                    .min = if (q == '+') 1 else 0,
                    .max = if (q == '?') 1 else null,
                    .greedy = greedy,
                } };
            };
            try seq.append(p.a, atom);
        }
        return seq.items;
    }

    fn parseAtom(p: *Parser) Error!Node {
        const c = p.src[p.i];
        p.i += 1;
        switch (c) {
            '^' => return .start,
            '$' => return .end,
            '.' => return .any,
            '(' => {
                var cap: usize = 0;
                if (std.mem.startsWith(u8, p.src[p.i..], "?:")) {
                    p.i += 2;
                } else if (std.mem.startsWith(u8, p.src[p.i..], "?P<")) {
                    p.i += 3;
                    const end = std.mem.indexOfScalarPos(u8, p.src, p.i, '>') orelse return error.InvalidRegex;
                    cap = p.names.items.len;
                    try p.names.append(p.a, p.src[p.i..end]);
                    p.i = end + 1;
                } else {
                    cap = p.names.items.len;
                    try p.names.append(p.a, null);
                }
                const alts = try p.parseAlts();
                if (p.peek() != ')') return error.InvalidRegex;
                p.i += 1;
                return .{ .group = .{ .alts = alts, .cap = cap } };
            },
            '[' => return .{ .class = try p.parseClass() },
            '\\' => {
                const e = p.src[p.i];
                p.i += 1;
                return switch (e) {
                    's' => .{ .class = .{ .negated = false, .ranges = &.{}, .perl = .space } },
                    'S' => .{ .class = .{ .negated = true, .ranges = &.{}, .perl = .space } },
                    'w' => .{ .class = .{ .negated = false, .ranges = &.{}, .perl = .word } },
                    'W' => .{ .class = .{ .negated = true, .ranges = &.{}, .perl = .word } },
                    'd' => .{ .class = .{ .negated = false, .ranges = &.{}, .perl = .digit } },
                    'n' => .{ .char = '\n' },
                    't' => .{ .char = '\t' },
                    else => .{ .char = e },
                };
            },
            else => {
                p.i -= 1;
                const d = util.decodeAt(p.src, p.i);
                p.i += d.len;
                return .{ .char = d.cp };
            },
        }
    }

    fn parseClass(p: *Parser) Error!Class {
        var negated = false;
        if (p.peek() == '^') {
            negated = true;
            p.i += 1;
        }
        var ranges: std.ArrayList([2]u21) = .empty;
        var first = true;
        while (p.peek()) |c| {
            if (c == ']' and !first) break;
            first = false;
            var lo: u21 = c;
            p.i += 1;
            if (c == '\\') {
                lo = p.src[p.i];
                p.i += 1;
            }
            if (p.peek() == '-' and p.i + 1 < p.src.len and p.src[p.i + 1] != ']') {
                p.i += 1;
                var hi: u21 = p.src[p.i];
                p.i += 1;
                if (hi == '\\') {
                    hi = p.src[p.i];
                    p.i += 1;
                }
                try ranges.append(p.a, .{ lo, hi });
            } else try ranges.append(p.a, .{ lo, lo });
        }
        if (p.peek() != ']') return error.InvalidRegex;
        p.i += 1;
        return .{ .negated = negated, .ranges = ranges.items };
    }
};

test "regex captures with lazy groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const re = try Regex.compile(a, "^(?P<left>.+?)\\s*(?P<arrow><[-.=ox]*[-=]+[-.=ox]*>|<[-.=ox]*[-=]+[-.=ox]*|[-.=ox]*[-=]+[-.=ox]*>|[-.=ox]*[-=]+[-.=ox]*)\\s*(?P<right>.+)$");
    const c = (try re.captures(a, "A --> B")).?;
    try std.testing.expectEqualStrings("A", c.named("left").?);
    try std.testing.expectEqualStrings("-->", c.named("arrow").?);
    try std.testing.expectEqualStrings("B", c.named("right").?);
    const h = try Regex.compile(a, "^(flowchart|graph)\\s+(\\w+)");
    const hc = (try h.captures(a, "flowchart LR")).?;
    try std.testing.expectEqualStrings("LR", hc.get(2).?);
    const tok = try Regex.compile(a, "<[-.=ox]*[-=]+[-.=ox]*>|<[-.=ox]*[-=]+[-.=ox]*|[-.=ox]*[-=]+[-.=ox]*>|[-.=ox]*[-=]+[-.=ox]*");
    const all = try tok.findAll(a, "A --> B --> C");
    try std.testing.expectEqual(@as(usize, 2), all.len);
}
