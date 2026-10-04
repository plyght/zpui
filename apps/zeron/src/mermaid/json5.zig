//! A JSON5 well-formedness check (the crate only tests `%%{init: ...}%%`
//! configs for parseability and then ignores them when rendering).

const std = @import("std");

const P = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(p: *P) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn skip(p: *P) bool {
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c) {
                p.i += 1;
            } else if (c == 0xc2 and p.i + 1 < p.s.len and p.s[p.i + 1] == 0xa0) {
                p.i += 2;
            } else if (c == '/' and p.i + 1 < p.s.len and p.s[p.i + 1] == '/') {
                while (p.i < p.s.len and p.s[p.i] != '\n') p.i += 1;
            } else if (c == '/' and p.i + 1 < p.s.len and p.s[p.i + 1] == '*') {
                const end = std.mem.indexOfPos(u8, p.s, p.i + 2, "*/") orelse return false;
                p.i = end + 2;
            } else break;
        }
        return true;
    }

    fn value(p: *P, depth: usize) bool {
        if (depth > 128 or !p.skip()) return false;
        const c = p.peek() orelse return false;
        return switch (c) {
            '{' => p.object(depth),
            '[' => p.array(depth),
            '"', '\'' => p.string(),
            else => p.literal(),
        };
    }

    fn object(p: *P, depth: usize) bool {
        p.i += 1;
        while (true) {
            if (!p.skip()) return false;
            const c = p.peek() orelse return false;
            if (c == '}') {
                p.i += 1;
                return true;
            }
            if (c == '"' or c == '\'') {
                if (!p.string()) return false;
            } else if (!p.ident()) return false;
            if (!p.skip() or p.peek() != ':') return false;
            p.i += 1;
            if (!p.value(depth + 1) or !p.skip()) return false;
            const n = p.peek() orelse return false;
            if (n == ',') {
                p.i += 1;
            } else if (n == '}') {
                p.i += 1;
                return true;
            } else return false;
        }
    }

    fn array(p: *P, depth: usize) bool {
        p.i += 1;
        while (true) {
            if (!p.skip()) return false;
            const c = p.peek() orelse return false;
            if (c == ']') {
                p.i += 1;
                return true;
            }
            if (!p.value(depth + 1) or !p.skip()) return false;
            const n = p.peek() orelse return false;
            if (n == ',') {
                p.i += 1;
            } else if (n == ']') {
                p.i += 1;
                return true;
            } else return false;
        }
    }

    fn string(p: *P) bool {
        const q = p.s[p.i];
        p.i += 1;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '\\') {
                p.i += 2;
                continue;
            }
            if (c == '\n' or c == '\r') return false;
            p.i += 1;
            if (c == q) return true;
        }
        return false;
    }

    fn ident(p: *P) bool {
        const start = p.i;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80) {
                p.i += 1;
            } else break;
        }
        return p.i > start and !std.ascii.isDigit(p.s[start]);
    }

    fn literal(p: *P) bool {
        const start = p.i;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (std.ascii.isAlphanumeric(c) or c == '.' or c == '+' or c == '-' or c == '_') {
                p.i += 1;
            } else break;
        }
        const tok = p.s[start..p.i];
        if (tok.len == 0) return false;
        for ([_][]const u8{ "true", "false", "null", "Infinity", "+Infinity", "-Infinity", "NaN", "+NaN", "-NaN" }) |k| {
            if (std.mem.eql(u8, tok, k)) return true;
        }
        var t = tok;
        if (t[0] == '+' or t[0] == '-') t = t[1..];
        if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
            _ = std.fmt.parseInt(u64, t[2..], 16) catch return false;
            return true;
        }
        if (t.len == 0 or t[0] == '+' or t[0] == '-') return false;
        _ = std.fmt.parseFloat(f64, t) catch return false;
        return true;
    }
};

pub fn isValid(_: std.mem.Allocator, src: []const u8) bool {
    var p: P = .{ .s = src };
    if (!p.value(0)) return false;
    if (!p.skip()) return false;
    return p.i == p.s.len;
}

test "json5" {
    const a = std.testing.allocator;
    try std.testing.expect(isValid(a, "{ theme: 'dark', 'x': [1, 2,], }"));
    try std.testing.expect(isValid(a, "{\"theme\": \"forest\"}"));
    try std.testing.expect(!isValid(a, "{ theme: }"));
}
