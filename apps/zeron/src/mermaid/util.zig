//! Rust `str` semantics the port relies on: Unicode `trim` / `split_whitespace`
//! / `char::is_whitespace`, `str::lines`, char iteration, and Rust-compatible
//! float formatting (`{}` shortest round-trip and `{:.N}` fixed).
//!
//! Everything allocates in the caller's arena; nothing is freed individually.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `char::is_whitespace` (Unicode White_Space).
pub fn isWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// Decodes the code point at `i` (invalid bytes decode as U+FFFD, length 1).
pub fn decodeAt(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (i + n > s.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i..][0..n]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// Length of the code point ending right before `end`.
pub fn prevLen(s: []const u8, end: usize) usize {
    var i = end - 1;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    return end - i;
}

pub fn trimStart(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i);
        if (!isWhitespace(d.cp)) break;
        i += d.len;
    }
    return s[i..];
}

pub fn trimEnd(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        const n = prevLen(s, end);
        const d = decodeAt(s, end - n);
        if (!isWhitespace(d.cp)) break;
        end -= n;
    }
    return s[0..end];
}

pub fn trim(s: []const u8) []const u8 {
    return trimEnd(trimStart(s));
}

/// `str::trim_matches(ch)` for an ASCII char.
pub fn trimMatches(s: []const u8, ch: u8) []const u8 {
    return std.mem.trim(u8, s, &.{ch});
}

/// `str::split_whitespace`.
pub const WhitespaceIter = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(it: *WhitespaceIter) ?[]const u8 {
        while (it.i < it.s.len) {
            const d = decodeAt(it.s, it.i);
            if (!isWhitespace(d.cp)) break;
            it.i += d.len;
        }
        if (it.i >= it.s.len) return null;
        const start = it.i;
        while (it.i < it.s.len) {
            const d = decodeAt(it.s, it.i);
            if (isWhitespace(d.cp)) break;
            it.i += d.len;
        }
        return it.s[start..it.i];
    }
};

pub fn splitWhitespace(s: []const u8) WhitespaceIter {
    return .{ .s = s };
}

pub fn collectWhitespace(a: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = splitWhitespace(s);
    while (it.next()) |w| try out.append(a, w);
    return out.items;
}

/// `str::lines`: split on `\n`, strip one trailing `\r`, no final empty line.
pub const LinesIter = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(it: *LinesIter) ?[]const u8 {
        if (it.i >= it.s.len) return null;
        const end = std.mem.indexOfScalarPos(u8, it.s, it.i, '\n') orelse it.s.len;
        var line = it.s[it.i..end];
        it.i = end + 1;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }
};

pub fn lines(s: []const u8) LinesIter {
    return .{ .s = s };
}

pub fn lowerAscii(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

pub fn upperAscii(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn startsWith(s: []const u8, p: []const u8) bool {
    return std.mem.startsWith(u8, s, p);
}

pub fn endsWith(s: []const u8, p: []const u8) bool {
    return std.mem.endsWith(u8, s, p);
}

pub fn contains(s: []const u8, p: []const u8) bool {
    return std.mem.indexOf(u8, s, p) != null;
}

pub fn containsChar(s: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, s, c) != null;
}

pub fn find(s: []const u8, p: []const u8) ?usize {
    return std.mem.indexOf(u8, s, p);
}

pub fn rfind(s: []const u8, p: []const u8) ?usize {
    return std.mem.lastIndexOf(u8, s, p);
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Decoded code points of `s`.
pub fn chars(a: Allocator, s: []const u8) Allocator.Error![]u21 {
    var out: std.ArrayList(u21) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i);
        try out.append(a, d.cp);
        i += d.len;
    }
    return out.items;
}

pub fn charCount(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        i += decodeAt(s, i).len;
        n += 1;
    }
    return n;
}

pub fn isAscii(s: []const u8) bool {
    for (s) |c| if (c >= 0x80) return false;
    return true;
}

/// Encodes code points back to UTF-8.
pub fn encode(a: Allocator, cps: []const u21) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (cps) |cp| try appendCp(a, &out, cp);
    return out.items;
}

pub fn appendCp(a: Allocator, out: *std.ArrayList(u8), cp: u21) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.appendSlice(a, "\u{FFFD}");
        return;
    };
    try out.appendSlice(a, buf[0..n]);
}

/// `str::replace` (all occurrences).
pub fn replace(a: Allocator, s: []const u8, from: []const u8, to: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, from)) |at| {
        try out.appendSlice(a, s[i..at]);
        try out.appendSlice(a, to);
        i = at + from.len;
    }
    try out.appendSlice(a, s[i..]);
    return out.items;
}

/// `str::replacen(from, to, 1)`.
pub fn replaceOnce(a: Allocator, s: []const u8, from: []const u8, to: []const u8) Allocator.Error![]const u8 {
    const at = std.mem.indexOf(u8, s, from) orelse return s;
    return std.mem.concat(a, u8, &.{ s[0..at], to, s[at + from.len ..] });
}

pub fn join(a: Allocator, parts: []const []const u8, sep: []const u8) Allocator.Error![]u8 {
    return std.mem.join(a, sep, parts);
}

pub fn dupe(a: Allocator, s: []const u8) Allocator.Error![]u8 {
    return a.dupe(u8, s);
}

pub fn concat(a: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    return std.mem.concat(a, u8, parts);
}

pub fn print(a: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error![]u8 {
    return std.fmt.allocPrint(a, fmt, args);
}

/// Rust `str::parse::<f32>()` (decimal, optional sign, exponent; no hex / inf words other
/// than "inf"/"infinity"/"nan" which Rust accepts).
pub fn parseF32(s: []const u8) ?f32 {
    if (s.len == 0) return null;
    // Zig accepts some forms Rust does not (underscores, hex); reject them.
    for (s) |c| switch (c) {
        '0'...'9', '.', '+', '-', 'e', 'E' => {},
        'i', 'n', 'f', 't', 'y', 'a', 'I', 'N', 'F', 'T', 'Y', 'A' => {},
        else => return null,
    };
    return std.fmt.parseFloat(f32, s) catch null;
}

pub fn parseUsize(s: []const u8) ?usize {
    if (s.len == 0) return null;
    var t = s;
    if (t[0] == '+') t = t[1..];
    if (t.len == 0) return null;
    for (t) |c| if (c < '0' or c > '9') return null;
    return std.fmt.parseInt(usize, t, 10) catch null;
}

// ---------------------------------------------------------------------------------------
// Rust float formatting
// ---------------------------------------------------------------------------------------

/// Rust `format!("{}", v)` for an f32: shortest round-trip digits, never an exponent.
pub fn fmtF32(a: Allocator, v: f32) Allocator.Error![]u8 {
    var buf: [128]u8 = undefined;
    return a.dupe(u8, writeF32(&buf, v));
}

pub fn writeF32(buf: []u8, v: f32) []const u8 {
    if (std.math.isNan(v)) return "NaN";
    if (std.math.isInf(v)) return if (v > 0) "inf" else "-inf";
    // Rust prints -0.0 as "-0".
    if (v == 0) return if (std.math.signbit(v)) "-0" else "0";
    const s = std.fmt.bufPrint(buf, "{d}", .{v}) catch return "0";
    return s;
}

/// Rust `format!("{:.N}", v)` for an f32: exact decimal expansion of the
/// binary value, rounded half-to-even at `prec` digits.
pub fn fmtFixed(a: Allocator, v: f32, prec: usize) Allocator.Error![]u8 {
    var buf: [512]u8 = undefined;
    return a.dupe(u8, writeFixed(&buf, v, prec));
}

pub fn writeFixed(buf: []u8, v: f32, prec: usize) []const u8 {
    if (std.math.isNan(v)) return "NaN";
    if (std.math.isInf(v)) return if (v > 0) "inf" else "-inf";
    // Exact decimal expansion of the f32 (mantissa * 2^exp) via big integer math
    // on a u256: |v| < 2^128 and at most 149 fractional binary digits.
    const bits: u32 = @bitCast(v);
    const neg = (bits >> 31) != 0;
    const exp_bits: i32 = @intCast((bits >> 23) & 0xff);
    var mant: u64 = bits & 0x7fffff;
    var e2: i32 = undefined;
    if (exp_bits == 0) {
        e2 = -149;
    } else {
        mant |= 0x800000;
        e2 = exp_bits - 150;
    }
    // value = mant * 2^e2. Represent as integer part + fraction scaled by 10^prec.
    // scaled = round_half_even(mant * 2^e2 * 10^prec)
    var w: std.Io.Writer = .fixed(buf);
    if (neg and mant != 0) w.writeByte('-') catch {};
    if (neg and mant == 0) w.writeByte('-') catch {};
    const Big = std.math.big.int.Managed;
    var arena_buf: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const fa = fba.allocator();
    var num = Big.initSet(fa, mant) catch return "0";
    var den = Big.initSet(fa, 1) catch return "0";
    if (e2 >= 0) {
        num.shiftLeft(&num, @intCast(e2)) catch return "0";
    } else {
        den.shiftLeft(&den, @intCast(-e2)) catch return "0";
    }
    var ten = Big.initSet(fa, 10) catch return "0";
    var scale = Big.initSet(fa, 1) catch return "0";
    var p: usize = 0;
    while (p < prec) : (p += 1) scale.mul(&scale, &ten) catch return "0";
    num.mul(&num, &scale) catch return "0";
    var q = Big.init(fa) catch return "0";
    var r = Big.init(fa) catch return "0";
    q.divTrunc(&r, &num, &den) catch return "0";
    // Round half to even: compare 2r with den.
    var r2 = Big.init(fa) catch return "0";
    r2.shiftLeft(&r, 1) catch return "0";
    const cmp = r2.order(den);
    if (cmp == .gt or (cmp == .eq and q.isOdd())) {
        var one = Big.initSet(fa, 1) catch return "0";
        q.add(&q, &one) catch return "0";
    }
    const digits = q.toString(fa, 10, .lower) catch return "0";
    if (prec == 0) {
        w.writeAll(digits) catch {};
    } else if (digits.len <= prec) {
        w.writeAll("0.") catch {};
        var z = prec - digits.len;
        while (z > 0) : (z -= 1) w.writeByte('0') catch {};
        w.writeAll(digits) catch {};
    } else {
        w.writeAll(digits[0 .. digits.len - prec]) catch {};
        w.writeByte('.') catch {};
        w.writeAll(digits[digits.len - prec ..]) catch {};
    }
    return w.buffered();
}

/// `{:.N}` for an f64 value (used where Rust formats f64).
pub fn writeFixed64(buf: []u8, v: f64, prec: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.[1]}", .{ v, prec }) catch "0";
}

test "rust float formatting" {
    var buf: [128]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("12.5", writeF32(&buf, 12.5));
    try t.expectEqualStrings("0.1", writeF32(&buf, 0.1));
    try t.expectEqualStrings("100", writeF32(&buf, 100));
    try t.expectEqualStrings("-3", writeF32(&buf, -3));
    try t.expectEqualStrings("1.00", writeFixed(&buf, 0.999999, 2));
    try t.expectEqualStrings("0.12", writeFixed(&buf, 0.125, 2)); // 0.125 exactly: half-even
    try t.expectEqualStrings("0.14", writeFixed(&buf, 0.135, 2)); // 0.135f32 = 0.13500000536...
    try t.expectEqualStrings("-1.50", writeFixed(&buf, -1.5, 2));
    try t.expectEqualStrings("240.0000000000", writeFixed(&buf, 240.0, 10));
    try t.expectEqualStrings("2", writeFixed(&buf, 2.5, 0));
    try t.expectEqualStrings("12", writeF32(&buf, 12));
}

test "unicode trim" {
    try std.testing.expectEqualStrings("a b", trim("\u{a0} a b\t\u{3000}"));
    var it = splitWhitespace("  a\u{2003}b  c ");
    try std.testing.expectEqualStrings("a", it.next().?);
    try std.testing.expectEqualStrings("b", it.next().?);
    try std.testing.expectEqualStrings("c", it.next().?);
    try std.testing.expect(it.next() == null);
}
