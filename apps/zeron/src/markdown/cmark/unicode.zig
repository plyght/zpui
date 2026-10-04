//! Small Unicode helpers matching the Rust `char` predicates the ported code
//! relies on (`char::is_whitespace`, `char::is_alphanumeric`).

const std = @import("std");
const punct = @import("puncttable.zig");

pub const Decoded = struct { cp: u21, len: u3 };

/// Decode the scalar at `s[0..]`. Invalid UTF-8 decodes as U+FFFD, one byte
/// (inputs are `&str` on the Rust side, so this only guards robustness).
pub fn decodeFirst(s: []const u8) ?Decoded {
    if (s.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (n > s.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(s[0..n]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// Decode the last scalar of `s`.
pub fn decodeLast(s: []const u8) ?Decoded {
    if (s.len == 0) return null;
    var i: usize = s.len - 1;
    var steps: usize = 0;
    while (i > 0 and steps < 3 and (s[i] & 0xC0) == 0x80) : (steps += 1) i -= 1;
    const d = decodeFirst(s[i..]) orelse return null;
    if (i + d.len != s.len) return .{ .cp = 0xFFFD, .len = 1 };
    return d;
}

/// Rust `char::is_whitespace` (Unicode White_Space).
pub fn isWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// Approximation of Rust `char::is_alphanumeric` (Alphabetic | Numeric):
/// exact for ASCII; beyond ASCII every scalar that is not whitespace, not a
/// control/format character, not CommonMark punctuation/symbol and not a
/// combining mark counts. Emoji are symbols (punct table covers `S*`).
pub fn isAlphanumeric(cp: u21) bool {
    if (cp < 0x80) {
        const c: u8 = @intCast(cp);
        return std.ascii.isAlphanumeric(c);
    }
    if (isWhitespace(cp)) return false;
    if (cp < 0xA0) return false; // C1 controls
    if (punct.isPunctuation(cp)) return false;
    return switch (cp) {
        0x0300...0x036F, 0x200B...0x200F, 0x2060...0x206F, 0xFE00...0xFE0F, 0xFEFF, 0xFFF0...0xFFFF, 0xE0000...0xE007F => false,
        // Emoji / pictographs outside the punct table's range.
        0x1F000...0x1FAFF => false,
        else => true,
    };
}

/// Rust `str::lines`: split on `\n`, strip one trailing `\r`, no trailing
/// empty line.
pub const LineIter = struct {
    s: []const u8,
    pos: usize = 0,

    pub fn next(self: *LineIter) ?[]const u8 {
        if (self.pos >= self.s.len) return null;
        const rest = self.s[self.pos..];
        var line: []const u8 = undefined;
        if (std.mem.indexOfScalar(u8, rest, '\n')) |i| {
            line = rest[0..i];
            self.pos += i + 1;
        } else {
            line = rest;
            self.pos = self.s.len;
        }
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }
};

/// `str::trim_start` (Unicode White_Space).
pub fn trimStart(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeFirst(s[i..]).?;
        if (!isWhitespace(d.cp)) break;
        i += d.len;
    }
    return s[i..];
}

/// `str::trim_end` (Unicode White_Space).
pub fn trimEnd(s: []const u8) []const u8 {
    var e = s.len;
    while (e > 0) {
        const d = decodeLast(s[0..e]).?;
        if (!isWhitespace(d.cp)) break;
        e -= d.len;
    }
    return s[0..e];
}

pub fn trim(s: []const u8) []const u8 {
    return trimEnd(trimStart(s));
}
