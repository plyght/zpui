//! Minimal backtracking regex for tree-sitter `#match?` predicates.
//!
//! Supports the subset the vendored queries use (and a little more): literals,
//! `.`, `^`, `$`, classes (`[a-z]`, `[^...]`, `\d \w \s` and their negations),
//! groups (`(...)`, `(?:...)`), alternation, and the quantifiers `* + ? {n,m}`
//! (greedy and lazy). Semantics follow Rust's `regex::bytes::Regex::is_match`
//! with default flags: unanchored search, `^`/`$` anchor the whole text, and
//! `.` matches any UTF-8 codepoint except `\n`. `\w`/`\d`/`\s` are Unicode-
//! aware in Rust; here non-ASCII letters approximate `\w` (any codepoint
//! >= 0x80 that is not Unicode whitespace) and `\d` is ASCII-only.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidRegex, OutOfMemory };

const Range = struct { lo: u21, hi: u21 };

const Class = struct {
    negated: bool,
    ranges: []const Range,
    /// Perl classes inside the brackets: bit 0 \d, 1 \D, 2 \w, 3 \W, 4 \s, 5 \S.
    perl: u8,

    fn matches(self: Class, cp: u21) bool {
        var hit = false;
        for (self.ranges) |r| {
            if (cp >= r.lo and cp <= r.hi) {
                hit = true;
                break;
            }
        }
        if (!hit and self.perl != 0) {
            if (self.perl & 1 != 0 and isDigit(cp)) hit = true;
            if (self.perl & 2 != 0 and !isDigit(cp)) hit = true;
            if (self.perl & 4 != 0 and isWord(cp)) hit = true;
            if (self.perl & 8 != 0 and !isWord(cp)) hit = true;
            if (self.perl & 16 != 0 and isSpace(cp)) hit = true;
            if (self.perl & 32 != 0 and !isSpace(cp)) hit = true;
        }
        return hit != self.negated;
    }
};

const Node = union(enum) {
    char: u21,
    any,
    class: Class,
    start,
    end,
    group: []const []const Node,
    repeat: Repeat,
};

const Repeat = struct {
    node: *const Node,
    min: u32,
    max: ?u32,
    greedy: bool,
};

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    alts: []const []const Node,
    anchored: bool,

    pub fn compile(gpa: Allocator, pattern: []const u8) Error!Regex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        var p: Parser = .{ .a = arena.allocator(), .src = pattern };
        const alts = try p.parseAlts();
        if (p.pos != pattern.len) return error.InvalidRegex;
        var anchored = alts.len > 0;
        for (alts) |seq| {
            if (seq.len == 0 or seq[0] != .start) anchored = false;
        }
        return .{ .arena = arena, .alts = alts, .anchored = anchored };
    }

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
    }

    pub fn isMatch(self: *const Regex, text: []const u8) bool {
        var m: Matcher = .{ .text = text };
        const top: Node = .{ .group = self.alts };
        const seq: []const Node = (&top)[0..1];
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (start < text.len and start > 0 and text[start] & 0xC0 == 0x80) continue;
            if (m.matchSeq(seq, 0, start, null)) return true;
            if (self.anchored) break;
        }
        return false;
    }
};

fn isDigit(cp: u21) bool {
    return cp >= '0' and cp <= '9';
}

fn isSpace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn isWord(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_';
    return !isSpace(cp);
}

const Parser = struct {
    a: Allocator,
    src: []const u8,
    pos: usize = 0,

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn parseAlts(self: *Parser) Error![]const []const Node {
        var alts: std.ArrayList([]const Node) = .empty;
        while (true) {
            try alts.append(self.a, try self.parseSeq());
            if (self.peek() == '|') {
                self.pos += 1;
                continue;
            }
            break;
        }
        return alts.items;
    }

    fn parseSeq(self: *Parser) Error![]const Node {
        var seq: std.ArrayList(Node) = .empty;
        while (self.peek()) |ch| {
            if (ch == '|' or ch == ')') break;
            var atom: Node = switch (ch) {
                '(' => blk: {
                    self.pos += 1;
                    if (std.mem.startsWith(u8, self.src[self.pos..], "?:")) self.pos += 2;
                    const alts = try self.parseAlts();
                    if (self.peek() != ')') return error.InvalidRegex;
                    self.pos += 1;
                    break :blk .{ .group = alts };
                },
                '[' => .{ .class = try self.parseClass() },
                '.' => blk: {
                    self.pos += 1;
                    break :blk .any;
                },
                '^' => blk: {
                    self.pos += 1;
                    break :blk .start;
                },
                '$' => blk: {
                    self.pos += 1;
                    break :blk .end;
                },
                '\\' => try self.parseEscapeAtom(),
                '*', '+', '?' => return error.InvalidRegex,
                else => .{ .char = try self.nextCodepoint() },
            };
            // Quantifiers.
            while (self.peek()) |q| {
                var min: u32 = 0;
                var max: ?u32 = null;
                switch (q) {
                    '*' => self.pos += 1,
                    '+' => {
                        self.pos += 1;
                        min = 1;
                    },
                    '?' => {
                        self.pos += 1;
                        max = 1;
                    },
                    '{' => {
                        const save = self.pos;
                        if (self.parseCounted()) |mm| {
                            min, max = mm;
                        } else {
                            self.pos = save;
                            break;
                        }
                    },
                    else => break,
                }
                if (atom == .start or atom == .end) return error.InvalidRegex;
                var greedy = true;
                if (self.peek() == '?') {
                    self.pos += 1;
                    greedy = false;
                }
                const inner = try self.a.create(Node);
                inner.* = atom;
                atom = .{ .repeat = .{ .node = inner, .min = min, .max = max, .greedy = greedy } };
            }
            try seq.append(self.a, atom);
        }
        return seq.items;
    }

    fn parseCounted(self: *Parser) ?struct { u32, ?u32 } {
        self.pos += 1; // '{'
        const min = self.parseInt() orelse return null;
        var max: ?u32 = min;
        if (self.peek() == ',') {
            self.pos += 1;
            max = self.parseInt();
        }
        if (self.peek() != '}') return null;
        self.pos += 1;
        return .{ min, max };
    }

    fn parseInt(self: *Parser) ?u32 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            self.pos += 1;
        }
        if (self.pos == start) return null;
        return std.fmt.parseInt(u32, self.src[start..self.pos], 10) catch null;
    }

    fn nextCodepoint(self: *Parser) Error!u21 {
        const len = std.unicode.utf8ByteSequenceLength(self.src[self.pos]) catch return error.InvalidRegex;
        if (self.pos + len > self.src.len) return error.InvalidRegex;
        const cp = std.unicode.utf8Decode(self.src[self.pos..][0..len]) catch return error.InvalidRegex;
        self.pos += len;
        return cp;
    }

    /// `\x` outside a class.
    fn parseEscapeAtom(self: *Parser) Error!Node {
        self.pos += 1;
        if (self.pos >= self.src.len) return error.InvalidRegex;
        const ch = self.src[self.pos];
        const perl: u8 = switch (ch) {
            'd' => 1,
            'D' => 2,
            'w' => 4,
            'W' => 8,
            's' => 16,
            'S' => 32,
            else => 0,
        };
        if (perl != 0) {
            self.pos += 1;
            return .{ .class = .{ .negated = false, .ranges = &.{}, .perl = perl } };
        }
        return .{ .char = try self.escapedChar() };
    }

    fn escapedChar(self: *Parser) Error!u21 {
        const ch = self.src[self.pos];
        switch (ch) {
            'n' => {
                self.pos += 1;
                return '\n';
            },
            't' => {
                self.pos += 1;
                return '\t';
            },
            'r' => {
                self.pos += 1;
                return '\r';
            },
            else => {
                if (std.ascii.isAlphanumeric(ch)) return error.InvalidRegex;
                return self.nextCodepoint();
            },
        }
    }

    fn parseClass(self: *Parser) Error!Class {
        self.pos += 1; // '['
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.pos += 1;
        }
        var ranges: std.ArrayList(Range) = .empty;
        var perl: u8 = 0;
        var first = true;
        while (true) {
            const ch = self.peek() orelse return error.InvalidRegex;
            if (ch == ']' and !first) {
                self.pos += 1;
                break;
            }
            first = false;
            var lo: u21 = undefined;
            if (ch == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) return error.InvalidRegex;
                const bit: u8 = switch (self.src[self.pos]) {
                    'd' => 1,
                    'D' => 2,
                    'w' => 4,
                    'W' => 8,
                    's' => 16,
                    'S' => 32,
                    else => 0,
                };
                if (bit != 0) {
                    self.pos += 1;
                    perl |= bit;
                    continue;
                }
                lo = try self.escapedChar();
            } else {
                lo = try self.nextCodepoint();
            }
            var hi = lo;
            if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                self.pos += 1;
                if (self.peek() == '\\') {
                    self.pos += 1;
                    if (self.pos >= self.src.len) return error.InvalidRegex;
                    hi = try self.escapedChar();
                } else {
                    hi = try self.nextCodepoint();
                }
                if (hi < lo) return error.InvalidRegex;
            }
            try ranges.append(self.a, .{ .lo = lo, .hi = hi });
        }
        return .{ .negated = negated, .ranges = ranges.items, .perl = perl };
    }
};

const Cont = struct {
    kind: union(enum) {
        seq: struct { seq: []const Node, i: usize },
        repeat: struct { rep: *const Repeat, count: u32, start: usize, seq: []const Node, i: usize },
    },
    next: ?*const Cont,
};

const Matcher = struct {
    text: []const u8,

    fn decode(self: *const Matcher, pos: usize) ?struct { u21, usize } {
        if (pos >= self.text.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.text[pos]) catch return null;
        if (pos + len > self.text.len) return null;
        const cp = std.unicode.utf8Decode(self.text[pos..][0..len]) catch return null;
        return .{ cp, len };
    }

    /// Match a single-codepoint atom at `pos`; returns the byte length consumed.
    fn single(self: *const Matcher, node: *const Node, pos: usize) ?usize {
        const cp, const len = self.decode(pos) orelse return null;
        const ok = switch (node.*) {
            .char => |c| c == cp,
            .any => cp != '\n',
            .class => |cls| cls.matches(cp),
            else => unreachable,
        };
        return if (ok) len else null;
    }

    fn resume_(self: *Matcher, k: ?*const Cont, pos: usize) bool {
        const c = k orelse return true;
        return switch (c.kind) {
            .seq => |s| self.matchSeq(s.seq, s.i, pos, c.next),
            .repeat => |r| blk: {
                // Guard against empty iterations looping forever.
                if (pos == r.start) break :blk false;
                break :blk self.repeatGroup(r.rep, r.count, pos, r.seq, r.i, c.next);
            },
        };
    }

    fn matchSeq(self: *Matcher, seq: []const Node, i: usize, pos: usize, k: ?*const Cont) bool {
        if (i == seq.len) return self.resume_(k, pos);
        const node = &seq[i];
        switch (node.*) {
            .char, .any, .class => {
                const len = self.single(node, pos) orelse return false;
                return self.matchSeq(seq, i + 1, pos + len, k);
            },
            .start => return pos == 0 and self.matchSeq(seq, i + 1, pos, k),
            .end => return pos == self.text.len and self.matchSeq(seq, i + 1, pos, k),
            .group => |alts| {
                const cont: Cont = .{ .kind = .{ .seq = .{ .seq = seq, .i = i + 1 } }, .next = k };
                for (alts) |alt| {
                    if (self.matchSeq(alt, 0, pos, &cont)) return true;
                }
                return false;
            },
            .repeat => |*rep| switch (rep.node.*) {
                .char, .any, .class => return self.repeatSingle(rep, pos, seq, i, k),
                else => return self.repeatGroup(rep, 0, pos, seq, i, k),
            },
        }
    }

    fn repeatSingle(self: *Matcher, rep: *const Repeat, pos: usize, seq: []const Node, i: usize, k: ?*const Cont) bool {
        if (rep.greedy) {
            var count: u32 = 0;
            var p = pos;
            while (rep.max == null or count < rep.max.?) {
                const len = self.single(rep.node, p) orelse break;
                p += len;
                count += 1;
            }
            if (count < rep.min) return false;
            while (true) {
                if (self.matchSeq(seq, i + 1, p, k)) return true;
                if (count == rep.min) return false;
                // Step back one codepoint (all consumed bytes are valid UTF-8).
                p -= 1;
                while (p > pos and self.text[p] & 0xC0 == 0x80) p -= 1;
                count -= 1;
            }
        } else {
            var count: u32 = 0;
            var p = pos;
            while (count < rep.min) : (count += 1) {
                p += self.single(rep.node, p) orelse return false;
            }
            while (true) {
                if (self.matchSeq(seq, i + 1, p, k)) return true;
                if (rep.max != null and count >= rep.max.?) return false;
                p += self.single(rep.node, p) orelse return false;
                count += 1;
            }
        }
    }

    fn repeatGroup(self: *Matcher, rep: *const Repeat, count: u32, pos: usize, seq: []const Node, i: usize, k: ?*const Cont) bool {
        const can_more = rep.max == null or count < rep.max.?;
        const cont: Cont = .{
            .kind = .{ .repeat = .{ .rep = rep, .count = count + 1, .start = pos, .seq = seq, .i = i } },
            .next = k,
        };
        const body: []const Node = rep.node[0..1];
        if (rep.greedy) {
            if (can_more and self.matchSeq(body, 0, pos, &cont)) return true;
            return count >= rep.min and self.matchSeq(seq, i + 1, pos, k);
        } else {
            if (count >= rep.min and self.matchSeq(seq, i + 1, pos, k)) return true;
            return can_more and self.matchSeq(body, 0, pos, &cont);
        }
    }
};

fn expectMatch(pattern: []const u8, text: []const u8, expected: bool) !void {
    var re = try Regex.compile(std.testing.allocator, pattern);
    defer re.deinit();
    std.testing.expectEqual(expected, re.isMatch(text)) catch |e| {
        std.debug.print("pattern {s} on {s}\n", .{ pattern, text });
        return e;
    };
}

test "regex subset used by highlight queries" {
    try expectMatch("^[A-Z][A-Z\\d_]*$", "MAX_2", true);
    try expectMatch("^[A-Z][A-Z\\d_]*$", "Max", false);
    try expectMatch("^[A-Z]", "Widget", true);
    try expectMatch("^test", "a_test", false);
    try expectMatch("test", "a_test", true);
    try expectMatch("^(private|protected|public)$", "protected", true);
    try expectMatch("^(private|protected|public)$", "publicx", false);
    try expectMatch("^/[*][*][^*].*[*]/$", "/** doc */", true);
    try expectMatch("^/[*][*][^*].*[*]/$", "/*** x */", false);
    try expectMatch("^[a-z][^.]*$", "abc", true);
    try expectMatch("^[a-z][^.]*$", "ab.c", false);
    try expectMatch("[%*?]", "a%b", true);
    try expectMatch("\\.[jJ][sS][oO][nN]$", "/etc/config.json", true);
    try expectMatch("\\.[yY][aA]?[mM][lL]$", "x.yml", true);
    try expectMatch("(^|\\.)runCommand(((No)?(CC))?(Local)?)?$", "pkgs.runCommandNoCCLocal", true);
    try expectMatch("(^|\\.)runCommand(((No)?(CC))?(Local)?)?$", "runCommandX", false);
    try expectMatch("(^\\w*Phase|(pre|post)\\w*|(.*\\.)?\\w*([sS]cript|[hH]ook)|(.*\\.)?startup)$", "buildPhase", true);
    try expectMatch("(^\\w*Phase|(pre|post)\\w*|(.*\\.)?\\w*([sS]cript|[hH]ook)|(.*\\.)?startup)$", "a.b.shellHook", true);
    try expectMatch("(^\\w*Phase|(pre|post)\\w*|(.*\\.)?\\w*([sS]cript|[hH]ook)|(.*\\.)?startup)$", "meta", false);
    try expectMatch("^[-+]?%d+$", "%d", true);
    try expectMatch("^[A-Z][A-Z\\d_]+$'", "MAX", false);
    try expectMatch("^_*[A-Z][A-Z\\d_]+$", "__FOO", true);
    try expectMatch("a{2,3}", "caab", true);
    try expectMatch("^a{2,3}$", "aaaa", false);
    try expectMatch("^.$", "é", true);
    try expectMatch("^\\w+$", "café", true);
    try std.testing.expectError(error.InvalidRegex, Regex.compile(std.testing.allocator, "(ab"));
}
