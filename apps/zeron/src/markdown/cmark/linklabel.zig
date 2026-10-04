//! Link label parsing and matching — port of pulldown-cmark 0.12.2
//! `linklabel.rs`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sc = @import("scanners.zig");
const unicode = @import("unicode.zig");
const casefold = @import("casefold.zig");

/// Called after a line break inside a label: bytes of container prefix to
/// skip, or null when the label cannot continue.
pub const LinebreakHandler = struct {
    ctx: ?*const anyopaque = null,
    func: *const fn (ctx: ?*const anyopaque, bytes: []const u8) ?usize,

    pub fn call(self: LinebreakHandler, bytes: []const u8) ?usize {
        return self.func(self.ctx, bytes);
    }

    fn noneFn(_: ?*const anyopaque, _: []const u8) ?usize {
        return null;
    }
    pub const none: LinebreakHandler = .{ .func = noneFn };
};

pub fn scanLinkLabelRest(alloc: Allocator, text: []const u8, handler: LinebreakHandler, is_in_table: bool) Allocator.Error!?struct { usize, []const u8 } {
    const bytes = text;
    var ix: usize = 0;
    var only_white_space = true;
    var codepoints: usize = 0;
    var label: std.ArrayList(u8) = .empty;
    var mark: usize = 0;

    while (true) {
        if (codepoints >= 1000) return null;
        if (ix >= bytes.len) return null;
        const b = bytes[ix];
        if (b == '[') return null;
        if (b == ']') break;
        if (b == '|' and is_in_table and ix != 0 and bytes[ix - 1] == '\\') {
            try label.appendSlice(alloc, text[mark .. ix - 1]);
            try label.append(alloc, '|');
            ix += 1;
            only_white_space = false;
            mark = ix;
        } else if (b == '\\' and is_in_table and ix + 1 < bytes.len and bytes[ix + 1] == '|') {
            try label.appendSlice(alloc, text[mark..ix]);
            try label.append(alloc, '|');
            ix += 2;
            codepoints += 1;
            only_white_space = false;
            mark = ix;
        } else if (b == '\\' and blk: {
            if (ix + 1 >= bytes.len) return null;
            break :blk sc.isAsciiPunctuation(bytes[ix + 1]);
        }) {
            ix += 2;
            codepoints += 2;
            only_white_space = false;
        } else if (sc.isAsciiWhitespace(b)) {
            var whitespaces: usize = 0;
            var linebreaks: usize = 0;
            const whitespace_start = ix;
            while (ix < bytes.len and sc.isAsciiWhitespace(bytes[ix])) {
                if (sc.scanEol(bytes[ix..])) |eol_bytes| {
                    linebreaks += 1;
                    if (linebreaks > 1) return null;
                    ix += eol_bytes;
                    ix += handler.call(bytes[ix..]) orelse return null;
                    whitespaces += 2;
                } else {
                    whitespaces += if (bytes[ix] == ' ') 1 else 2;
                    ix += 1;
                }
            }
            if (whitespaces > 1) {
                try label.appendSlice(alloc, text[mark..whitespace_start]);
                try label.append(alloc, ' ');
                mark = ix;
                codepoints += ix - whitespace_start;
            } else {
                codepoints += 1;
            }
        } else {
            only_white_space = false;
            ix += 1;
            if (b & 0b1000_0000 != 0) codepoints += 1;
        }
    }

    if (only_white_space) return null;
    const ws = " \r\n\t";
    if (mark == 0) {
        return .{ ix + 1, std.mem.trim(u8, text[0..ix], ws) };
    }
    try label.appendSlice(alloc, text[mark..ix]);
    const trimmed = std.mem.trim(u8, label.items, ws);
    return .{ ix + 1, trimmed };
}

/// UniCase key normalisation for reference lookup: full Unicode case
/// folding (unicase compares labels by `C+F` folding; ASCII folds to lower).
pub fn foldKey(alloc: Allocator, label: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < label.len) {
        const d = unicode.decodeFirst(label[i..]).?;
        if (d.cp < 0x80) {
            try out.append(alloc, std.ascii.toLower(label[i]));
        } else if (casefold.fold(d.cp)) |f| {
            try out.appendSlice(alloc, f);
        } else {
            try out.appendSlice(alloc, label[i .. i + d.len]);
        }
        i += d.len;
    }
    return out.toOwnedSlice(alloc);
}

test "label whitespace normalization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = (try scanLinkLabelRest(arena.allocator(), "«\t\tBlurry Eyes\t\t»][blurry_eyes]", .none, false)).?;
    try std.testing.expectEqualStrings("« Blurry Eyes »", r[1]);
}
