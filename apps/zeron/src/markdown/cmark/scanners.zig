//! Scanners for fragments of CommonMark syntax — a line-for-line port of
//! pulldown-cmark 0.12.2 `src/scanners.rs` (the parser zeron links), limited
//! to what zeron's option set (tables, strikethrough, task lists) reaches.

const std = @import("std");
const Allocator = std.mem.Allocator;
const punct = @import("puncttable.zig");
const entities = @import("entities.zig");
const unicode = @import("unicode.zig");

pub const isAsciiPunctuation = punct.isAsciiPunctuation;
pub const isPunctuation = punct.isPunctuation;

pub const Alignment = enum { none, left, center, right };

// sorted for binary search
const html_tags = [_][]const u8{
    "address",  "article",  "aside",    "base",       "basefont", "blockquote", "body",   "caption",
    "center",   "col",      "colgroup", "dd",         "details",  "dialog",     "dir",    "div",
    "dl",       "dt",       "fieldset", "figcaption", "figure",   "footer",     "form",   "frame",
    "frameset", "h1",       "h2",       "h3",         "h4",       "h5",         "h6",     "head",
    "header",   "hr",       "html",     "iframe",     "legend",   "li",         "link",   "main",
    "menu",     "menuitem", "nav",      "noframes",   "ol",       "optgroup",   "option", "p",
    "param",    "search",   "section",  "summary",    "table",    "tbody",      "td",     "tfoot",
    "th",       "thead",    "title",    "tr",         "track",    "ul",
};

pub const LineStart = struct {
    bytes: []const u8,
    ix: usize = 0,
    tab_start: usize = 0,
    spaces_remaining: usize = 0,
    min_hrule_offset: usize = 0,

    pub fn init(bytes: []const u8) LineStart {
        return .{ .bytes = bytes };
    }

    pub fn scanSpace(self: *LineStart, n_space: usize) bool {
        return self.scanSpaceInner(n_space) == 0;
    }

    pub fn scanSpaceUpto(self: *LineStart, n_space: usize) usize {
        return n_space - self.scanSpaceInner(n_space);
    }

    fn scanSpaceInner(self: *LineStart, n_space_in: usize) usize {
        var n_space = n_space_in;
        const n_from_remaining = @min(self.spaces_remaining, n_space);
        self.spaces_remaining -= n_from_remaining;
        n_space -= n_from_remaining;
        while (n_space > 0 and self.ix < self.bytes.len) {
            switch (self.bytes[self.ix]) {
                ' ' => {
                    self.ix += 1;
                    n_space -= 1;
                },
                '\t' => {
                    const spaces = 4 - (self.ix - self.tab_start) % 4;
                    self.ix += 1;
                    self.tab_start = self.ix;
                    const n = @min(spaces, n_space);
                    n_space -= n;
                    self.spaces_remaining = spaces - n;
                },
                else => break,
            }
        }
        return n_space;
    }

    pub fn scanAllSpace(self: *LineStart) void {
        self.spaces_remaining = 0;
        while (self.ix < self.bytes.len and (self.bytes[self.ix] == ' ' or self.bytes[self.ix] == '\t')) self.ix += 1;
    }

    pub fn isAtEol(self: *const LineStart) bool {
        if (self.ix >= self.bytes.len) return true;
        const c = self.bytes[self.ix];
        return c == '\r' or c == '\n';
    }

    fn scanCh(self: *LineStart, c: u8) bool {
        if (self.ix < self.bytes.len and self.bytes[self.ix] == c) {
            self.ix += 1;
            return true;
        }
        return false;
    }

    pub fn scanBlockquoteMarker(self: *LineStart) bool {
        if (self.scanCh('>')) {
            _ = self.scanSpace(1);
            return true;
        }
        return false;
    }

    pub const ListMarker = struct { ch: u8, start: u64, indent: usize };

    pub fn scanListMarkerWithIndent(self: *LineStart, indent: usize) ?ListMarker {
        const save = self.*;
        if (self.ix < self.bytes.len) {
            const c = self.bytes[self.ix];
            if (c == '-' or c == '+' or c == '*') {
                if (self.ix >= self.min_hrule_offset) {
                    const hr = scanHrule(self.bytes[self.ix..]);
                    if (!hr.ok) {
                        self.min_hrule_offset = hr.n;
                    } else {
                        self.* = save;
                        return null;
                    }
                }
                self.ix += 1;
                if (self.scanSpace(1) or self.isAtEol()) {
                    return self.finishListMarker(c, 0, indent + 2);
                }
            } else if (std.ascii.isDigit(c)) {
                const start_ix = self.ix;
                var ix = self.ix + 1;
                var val: u64 = c - '0';
                while (ix < self.bytes.len and ix - start_ix < 10) {
                    const d = self.bytes[ix];
                    ix += 1;
                    if (std.ascii.isDigit(d)) {
                        val = val * 10 + (d - '0');
                    } else if (d == ')' or d == '.') {
                        self.ix = ix;
                        if (self.scanSpace(1) or self.isAtEol()) {
                            return self.finishListMarker(d, val, indent + 1 + ix - start_ix);
                        } else break;
                    } else break;
                }
            }
        }
        self.* = save;
        return null;
    }

    fn finishListMarker(self: *LineStart, c: u8, start: u64, indent_in: usize) ?ListMarker {
        var indent = indent_in;
        const save = self.*;
        if (scanBlankLine(self.bytes[self.ix..]) != null) {
            return .{ .ch = c, .start = start, .indent = indent };
        }
        const post_indent = self.scanSpaceUpto(4);
        if (post_indent < 4) {
            indent += post_indent;
        } else {
            self.* = save;
        }
        return .{ .ch = c, .start = start, .indent = indent };
    }

    pub fn scanTaskListMarker(self: *LineStart) ?bool {
        const save = self.*;
        _ = self.scanSpaceUpto(3);
        if (!self.scanCh('[')) {
            self.* = save;
            return null;
        }
        var is_checked: bool = undefined;
        if (self.ix < self.bytes.len and isAsciiWhitespaceNoNl(self.bytes[self.ix])) {
            self.ix += 1;
            is_checked = false;
        } else if (self.ix < self.bytes.len and (self.bytes[self.ix] == 'x' or self.bytes[self.ix] == 'X')) {
            self.ix += 1;
            is_checked = true;
        } else {
            self.* = save;
            return null;
        }
        if (!self.scanCh(']')) {
            self.* = save;
            return null;
        }
        if (!(self.ix < self.bytes.len and isAsciiWhitespaceNoNl(self.bytes[self.ix]))) {
            self.* = save;
            return null;
        }
        return is_checked;
    }

    pub fn bytesScanned(self: *const LineStart) usize {
        return self.ix;
    }

    pub fn remainingSpace(self: *const LineStart) usize {
        return self.spaces_remaining;
    }
};

pub fn isAsciiWhitespace(c: u8) bool {
    return (c >= 0x09 and c <= 0x0d) or c == ' ';
}

pub fn isAsciiWhitespaceNoNl(c: u8) bool {
    return c == '\t' or c == 0x0b or c == 0x0c or c == ' ';
}

fn isAsciiAlpha(c: u8) bool {
    return std.ascii.isAlphabetic(c);
}

pub fn isAsciiAlphanumeric(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

fn isAsciiLetterDigitDash(c: u8) bool {
    return c == '-' or isAsciiAlphanumeric(c);
}

fn isValidUnquotedAttrValueChar(c: u8) bool {
    return switch (c) {
        '\'', '"', ' ', '=', '>', '<', '`', '\n', '\r' => false,
        else => true,
    };
}

pub fn scanCh(data: []const u8, c: u8) usize {
    return if (data.len > 0 and data[0] == c) 1 else 0;
}

pub fn scanWhile(data: []const u8, comptime f: fn (u8) bool) usize {
    var i: usize = 0;
    while (i < data.len and f(data[i])) i += 1;
    return i;
}

pub fn scanRevWhile(data: []const u8, comptime f: fn (u8) bool) usize {
    var i: usize = 0;
    while (i < data.len and f(data[data.len - 1 - i])) i += 1;
    return i;
}

pub fn scanChRepeat(data: []const u8, c: u8) usize {
    var i: usize = 0;
    while (i < data.len and data[i] == c) i += 1;
    return i;
}

pub fn scanRevCh(data: []const u8, c: u8) usize {
    var i: usize = 0;
    while (i < data.len and data[data.len - 1 - i] == c) i += 1;
    return i;
}

pub fn scanWhitespaceNoNl(data: []const u8) usize {
    return scanWhile(data, isAsciiWhitespaceNoNl);
}

fn scanAttrValueChars(data: []const u8) usize {
    return scanWhile(data, isValidUnquotedAttrValueChar);
}

pub fn scanEol(bytes: []const u8) ?usize {
    if (bytes.len == 0) return 0;
    return switch (bytes[0]) {
        '\n' => 1,
        '\r' => if (bytes.len > 1 and bytes[1] == '\n') 2 else 1,
        else => null,
    };
}

pub fn scanBlankLine(bytes: []const u8) ?usize {
    const i = scanWhitespaceNoNl(bytes);
    const n = scanEol(bytes[i..]) orelse return null;
    return i + n;
}

pub fn scanNextline(bytes: []const u8) usize {
    return if (std.mem.indexOfScalar(u8, bytes, '\n')) |x| x + 1 else bytes.len;
}

pub fn scanClosingCodeFence(bytes: []const u8, fence_char: u8, n_fence_char: usize) ?usize {
    if (bytes.len == 0) return 0;
    var i: usize = 0;
    const found = scanChRepeat(bytes[i..], fence_char);
    if (found < n_fence_char) return null;
    i += found;
    i += scanChRepeat(bytes[i..], ' ');
    _ = scanEol(bytes[i..]) orelse return null;
    return i;
}

/// (number of bytes, number of spaces)
pub fn calcIndent(text: []const u8, max: usize) struct { usize, usize } {
    var spaces: usize = 0;
    var offset: usize = 0;
    for (text, 0..) |b, i| {
        offset = i;
        switch (b) {
            ' ' => {
                spaces += 1;
                if (spaces == max) break;
            },
            '\t' => {
                const new_spaces = spaces + 4 - (spaces & 3);
                if (new_spaces > max) break;
                spaces = new_spaces;
            },
            else => break,
        }
    }
    return .{ offset, spaces };
}

pub const HruleResult = struct { ok: bool, n: usize };

pub fn scanHrule(bytes: []const u8) HruleResult {
    if (bytes.len < 3) return .{ .ok = false, .n = 0 };
    const c = bytes[0];
    if (!(c == '*' or c == '-' or c == '_')) return .{ .ok = false, .n = 0 };
    var n: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == '\n' or b == '\r') {
            i += scanEol(bytes[i..]) orelse 0;
            break;
        } else if (b == c) {
            n += 1;
        } else if (b == ' ' or b == '\t') {} else {
            return .{ .ok = false, .n = i };
        }
        i += 1;
    }
    return .{ .ok = n >= 3, .n = i };
}

pub fn scanAtxHeading(data: []const u8) ?u8 {
    const level = scanChRepeat(data, '#');
    const ok = level >= data.len or isAsciiWhitespace(data[level]);
    if (ok and level >= 1 and level <= 6) return @intCast(level);
    return null;
}

pub fn scanSetextHeading(data: []const u8) ?struct { usize, u8 } {
    if (data.len == 0) return null;
    const c = data[0];
    const level: u8 = if (c == '=') 1 else if (c == '-') 2 else return null;
    var i = 1 + scanChRepeat(data[1..], c);
    i += scanBlankLine(data[i..]) orelse return null;
    return .{ i, level };
}

/// (bytes in line incl. newline, column alignments); 0 bytes = not a head.
pub fn scanTableHead(alloc: Allocator, data: []const u8) Allocator.Error!struct { usize, []Alignment } {
    var cols: std.ArrayList(Alignment) = .empty;
    const n = try scanTableHeadInner(data, alloc, &cols);
    if (n == 0) {
        cols.deinit(alloc);
        return .{ 0, &.{} };
    }
    return .{ n, try cols.toOwnedSlice(alloc) };
}

/// Allocation-free `scan_table_head`: (bytes, number of columns).
pub fn scanTableHeadCount(data: []const u8) struct { usize, usize } {
    var count: usize = 0;
    const n = scanTableHeadInner(data, null, &count) catch unreachable;
    return .{ n, if (n == 0) 0 else count };
}

fn scanTableHeadInner(data: []const u8, alloc: ?Allocator, sink: anytype) Allocator.Error!usize {
    const Sink = struct {
        fn push(a: ?Allocator, s: anytype, col: Alignment) Allocator.Error!void {
            if (@TypeOf(s) == *usize) {
                s.* += 1;
            } else {
                try s.append(a.?, col);
            }
        }
    };
    const ci = calcIndent(data, 4);
    var i = ci[0];
    if (ci[1] > 3 or i == data.len) return 0;
    var active_col: Alignment = .none;
    var start_col = true;
    var found_pipe = false;
    var found_hyphen = false;
    var found_hyphen_in_col = false;
    if (data[i] == '|') {
        i += 1;
        found_pipe = true;
    }
    // Rust iterates `for c in &data[i..]` with `i` advancing in lockstep.
    const begin = i;
    for (data[begin..]) |c| {
        if (scanEol(data[i..])) |n| {
            i += n;
            break;
        }
        switch (c) {
            ' ' => {},
            ':' => {
                if (start_col and active_col == .none) {
                    active_col = .left;
                } else if (!start_col and active_col == .left) {
                    active_col = .center;
                } else if (!start_col and active_col == .none) {
                    active_col = .right;
                }
                start_col = false;
            },
            '-' => {
                start_col = false;
                found_hyphen = true;
                found_hyphen_in_col = true;
            },
            '|' => {
                start_col = true;
                found_pipe = true;
                try Sink.push(alloc, sink, active_col);
                active_col = .none;
                if (!found_hyphen_in_col) return 0;
                found_hyphen_in_col = false;
            },
            else => return 0,
        }
        i += 1;
    }
    if (!start_col) try Sink.push(alloc, sink, active_col);
    if (!found_pipe or !found_hyphen) return 0;
    return i;
}

pub fn scanCodeFence(data: []const u8) ?struct { usize, u8 } {
    if (data.len == 0) return null;
    const c = data[0];
    if (!(c == '`' or c == '~')) return null;
    const i = 1 + scanChRepeat(data[1..], c);
    if (i >= 3) {
        if (c == '`') {
            const suffix = data[i..];
            const next_line = i + scanNextline(suffix);
            if (std.mem.indexOfScalar(u8, suffix[0 .. next_line - i], '`') != null) return null;
        }
        return .{ i, c };
    }
    return null;
}

pub fn scanBlockquoteStart(data: []const u8) ?usize {
    if (data.len > 0 and data[0] == '>') {
        const space: usize = if (data.len > 1 and data[1] == ' ') 1 else 0;
        return 1 + space;
    }
    return null;
}

/// (bytes, delim char, start index, indent)
pub fn scanListitem(bytes: []const u8) ?struct { usize, u8, usize, usize } {
    if (bytes.len == 0) return null;
    var c = bytes[0];
    var w: usize = undefined;
    var start: usize = undefined;
    switch (c) {
        '-', '+', '*' => {
            w = 1;
            start = 0;
        },
        '0'...'9' => {
            const pd = parseDecimal(bytes, 9);
            if (pd[0] >= bytes.len) return null;
            c = bytes[pd[0]];
            if (!(c == '.' or c == ')')) return null;
            w = pd[0] + 1;
            start = pd[1];
        },
        else => return null,
    }
    const ci = calcIndent(bytes[w..], 5);
    var postn = ci[0];
    var postindent = ci[1];
    if (postindent == 0) {
        _ = scanEol(bytes[w..]) orelse return null;
        postindent += 1;
    } else if (postindent > 4) {
        postn = 1;
        postindent = 1;
    }
    if (scanBlankLine(bytes[w..]) != null) {
        postn = 0;
        postindent = 1;
    }
    return .{ w + postn, c, start, w + postindent };
}

/// (number of bytes, parsed decimal), stopping early on overflow.
fn parseDecimal(bytes: []const u8, limit: usize) struct { usize, usize } {
    var count: usize = 0;
    var acc: usize = 0;
    for (bytes[0..@min(limit, bytes.len)]) |c| {
        if (!std.ascii.isDigit(c)) break;
        const m = std.math.mul(usize, acc, 10) catch break;
        const a = std.math.add(usize, m, c - '0') catch break;
        acc = a;
        count += 1;
    }
    return .{ count, acc };
}

fn parseHex(bytes: []const u8, limit: usize) struct { usize, usize } {
    var count: usize = 0;
    var acc: usize = 0;
    for (bytes[0..@min(limit, bytes.len)]) |c0| {
        var c = c0;
        var digit: usize = undefined;
        if (std.ascii.isDigit(c)) {
            digit = c - '0';
        } else {
            c |= 0x20;
            if (c >= 'a' and c <= 'f') digit = c - 'a' + 10 else break;
        }
        const m = std.math.mul(usize, acc, 16) catch break;
        acc = std.math.add(usize, m, digit) catch break;
        count += 1;
    }
    return .{ count, acc };
}

pub const Entity = struct { len: usize, value: ?[]const u8 };

/// Scratch for numeric entity values: the caller copies before reuse.
pub threadlocal var entity_buf: [4]u8 = undefined;

/// doesn't bother to check data[0] == '&'. A numeric value lives in
/// `entity_buf` until the next call.
pub fn scanEntity(bytes: []const u8) Entity {
    var end: usize = 1;
    if (scanCh(bytes[end..], '#') == 1) {
        end += 1;
        var r: struct { usize, usize } = undefined;
        if (end < bytes.len and (bytes[end] | 0x20) == 'x') {
            end += 1;
            r = parseHex(bytes[end..], 6);
        } else {
            r = parseDecimal(bytes[end..], 7);
        }
        end += r[0];
        if (r[0] == 0 or scanCh(bytes[end..], ';') == 0) return .{ .len = 0, .value = null };
        var cp: u21 = 0xFFFD;
        if (r[1] != 0 and r[1] <= 0x10FFFF and !(r[1] >= 0xD800 and r[1] <= 0xDFFF)) cp = @intCast(r[1]);
        const n = std.unicode.utf8Encode(cp, &entity_buf) catch unreachable;
        return .{ .len = end + 1, .value = entity_buf[0..n] };
    }
    end += scanWhile(bytes[end..], isAsciiAlphanumeric);
    if (scanCh(bytes[end..], ';') == 1) {
        if (entities.get(bytes[1..end])) |v| return .{ .len = end + 1, .value = v };
    }
    return .{ .len = 0, .value = null };
}

/// note: dest returned is raw, still needs to be unescaped
pub fn scanLinkDest(data: []const u8, start_ix: usize, max_next: usize) ?struct { usize, []const u8 } {
    const bytes = data[start_ix..];
    var i = scanCh(bytes, '<');
    if (i != 0) {
        while (i < bytes.len) {
            switch (bytes[i]) {
                '\n', '\r', '<' => return null,
                '>' => return .{ i + 1, data[start_ix + 1 .. start_ix + i] },
                '\\' => if (i + 1 < bytes.len and isAsciiPunctuation(bytes[i + 1])) {
                    i += 1;
                },
                else => {},
            }
            i += 1;
        }
        return null;
    } else {
        var nest: usize = 0;
        while (i < bytes.len) {
            switch (bytes[i]) {
                0x0...0x20 => break,
                '(' => {
                    if (nest > max_next) return null;
                    nest += 1;
                },
                ')' => {
                    if (nest == 0) break;
                    nest -= 1;
                },
                '\\' => if (i + 1 < bytes.len and isAsciiPunctuation(bytes[i + 1])) {
                    i += 1;
                },
                else => {},
            }
            i += 1;
        }
        if (nest != 0) return null;
        return .{ i, data[start_ix .. start_ix + i] };
    }
}

fn scanAttributeName(data: []const u8) ?usize {
    if (data.len == 0) return null;
    const c = data[0];
    if (isAsciiAlpha(c) or c == '_' or c == ':') {
        var n: usize = 1;
        while (n < data.len) : (n += 1) {
            const d = data[n];
            if (!(isAsciiAlphanumeric(d) or d == '_' or d == '.' or d == ':' or d == '-')) break;
        }
        return n;
    }
    return null;
}

/// Newline handler: given the bytes after a line break, how many container
/// prefix bytes to skip. `null` handler = newlines not allowed.
pub const NewlineHandler = struct {
    ctx: *const anyopaque,
    func: *const fn (ctx: *const anyopaque, bytes: []const u8) usize,
    fn call(self: NewlineHandler, bytes: []const u8) usize {
        return self.func(self.ctx, bytes);
    }
};

const HtmlBuf = struct {
    alloc: Allocator,
    buffer: std.ArrayList(u8) = .empty,
};

fn scanAttribute(data: []const u8, ix_in: usize, nh: ?NewlineHandler, buf: *HtmlBuf, buffer_ix: *usize) Allocator.Error!?usize {
    var ix = ix_in;
    ix += scanAttributeName(data[ix..]) orelse return null;
    const ix_after_attribute = ix;
    ix = scanWhitespaceWithNewlineHandlerWithoutBuffer(data, ix, nh) orelse return null;
    if (scanCh(data[ix..], '=') == 1) {
        ix = (try scanWhitespaceWithNewlineHandler(data, ix_after_attribute, nh, buf, buffer_ix)) orelse return null;
        ix += 1;
        ix = (try scanWhitespaceWithNewlineHandler(data, ix, nh, buf, buffer_ix)) orelse return null;
        ix = (try scanAttributeValue(data, ix, nh, buf, buffer_ix)) orelse return null;
        return ix;
    }
    return ix_after_attribute;
}

fn scanWhitespaceWithNewlineHandler(data: []const u8, i_in: usize, nh: ?NewlineHandler, buf: *HtmlBuf, buffer_ix: *usize) Allocator.Error!?usize {
    var i = i_in;
    while (i < data.len) {
        if (!isAsciiWhitespace(data[i])) return i;
        if (scanEol(data[i..])) |eol_bytes| {
            const handler = nh orelse return null;
            i += eol_bytes;
            const skipped = handler.call(data[i..]);
            if (skipped > 0) {
                try buf.buffer.appendSlice(buf.alloc, data[buffer_ix.*..i]);
                buffer_ix.* = i + skipped;
            }
            i += skipped;
        } else {
            i += 1;
        }
    }
    return i;
}

fn scanWhitespaceWithNewlineHandlerWithoutBuffer(data: []const u8, i_in: usize, nh: ?NewlineHandler) ?usize {
    var i = i_in;
    while (i < data.len) {
        if (!isAsciiWhitespace(data[i])) return i;
        if (scanEol(data[i..])) |eol_bytes| {
            const handler = nh orelse return null;
            i += eol_bytes;
            i += handler.call(data[i..]);
        } else {
            i += 1;
        }
    }
    return i;
}

fn scanAttributeValue(data: []const u8, i_in: usize, nh: ?NewlineHandler, buf: *HtmlBuf, buffer_ix: *usize) Allocator.Error!?usize {
    var i = i_in;
    if (i >= data.len) return null;
    const b = data[i];
    switch (b) {
        '"', '\'' => {
            i += 1;
            while (i < data.len) {
                if (data[i] == b) return i + 1;
                if (scanEol(data[i..])) |eol_bytes| {
                    const handler = nh orelse return null;
                    i += eol_bytes;
                    const skipped = handler.call(data[i..]);
                    if (skipped > 0) {
                        try buf.buffer.appendSlice(buf.alloc, data[buffer_ix.*..i]);
                        buffer_ix.* = i + skipped;
                    }
                    i += skipped;
                } else {
                    i += 1;
                }
            }
            return null;
        },
        ' ', '=', '>', '<', '`', '\n', '\r' => return null,
        else => i += scanAttrValueChars(data[i..]),
    }
    return i;
}

/// Remove backslash escapes and resolve entities. Returns `input` itself
/// when nothing changed.
pub fn unescape(alloc: Allocator, input: []const u8, is_in_table: bool) Allocator.Error![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var mark: usize = 0;
    var i: usize = 0;
    const bytes = input;
    while (i < bytes.len) {
        switch (bytes[i]) {
            '\\' => {
                if (is_in_table and i + 2 < bytes.len and bytes[i + 1] == '\\' and bytes[i + 2] == '|') {
                    try result.appendSlice(alloc, input[mark..i]);
                    mark = i + 2;
                    i += 3;
                } else if (i + 1 < bytes.len and isAsciiPunctuation(bytes[i + 1])) {
                    try result.appendSlice(alloc, input[mark..i]);
                    mark = i + 1;
                    i += 2;
                } else i += 1;
            },
            '&' => {
                const e = scanEntity(bytes[i..]);
                if (e.value) |v| {
                    try result.appendSlice(alloc, input[mark..i]);
                    try result.appendSlice(alloc, v);
                    i += e.len;
                    mark = i;
                } else i += 1;
            },
            '\r' => {
                try result.appendSlice(alloc, input[mark..i]);
                i += 1;
                mark = i;
            },
            else => i += 1,
        }
    }
    if (mark == 0) {
        result.deinit(alloc);
        return input;
    }
    try result.appendSlice(alloc, input[mark..]);
    return result.toOwnedSlice(alloc);
}

pub fn startsHtmlBlockType6(data: []const u8) bool {
    const i = scanCh(data, '/');
    var tail = data[i..];
    const n = scanWhile(tail, isAsciiAlphanumeric);
    if (!isHtmlTag(tail[0..n])) return false;
    tail = tail[n..];
    return tail.len == 0 or tail[0] == ' ' or tail[0] == '\t' or tail[0] == '\r' or tail[0] == '\n' or
        tail[0] == '>' or (tail.len >= 2 and tail[0] == '/' and tail[1] == '>');
}

fn isHtmlTag(tag: []const u8) bool {
    var lo: usize = 0;
    var hi: usize = html_tags.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const probe = html_tags[mid];
        var ord: std.math.Order = .eq;
        const m = @min(probe.len, tag.len);
        for (0..m) |k| {
            const o = std.math.order(probe[k], tag[k] | 0x20);
            if (o != .eq) {
                ord = o;
                break;
            }
        }
        if (ord == .eq) ord = std.math.order(probe.len, tag.len);
        switch (ord) {
            .eq => return true,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return false;
}

pub fn scanHtmlType7(alloc: Allocator, data: []const u8) Allocator.Error!?usize {
    const r = (try scanHtmlBlockInner(alloc, data, null)) orelse return null;
    _ = scanBlankLine(data[r[1]..]) orelse return null;
    return r[1];
}

/// Returns (span with container prefixes removed — empty when none were —,
/// bytes consumed).
pub fn scanHtmlBlockInner(alloc: Allocator, data: []const u8, nh: ?NewlineHandler) Allocator.Error!?struct { []u8, usize } {
    var buf: HtmlBuf = .{ .alloc = alloc };
    var last_buf_index: usize = 0;

    const close_tag_bytes = scanCh(data[1..], '/');
    const l = scanWhile(data[1 + close_tag_bytes ..], isAsciiAlpha);
    if (l == 0) return null;
    var i = 1 + close_tag_bytes + l;
    i += scanWhile(data[i..], isAsciiLetterDigitDash);

    if (close_tag_bytes == 0) {
        while (true) {
            const old_i = i;
            while (true) {
                i += scanWhitespaceNoNl(data[i..]);
                if (scanEol(data[i..])) |eol_bytes| {
                    if (eol_bytes == 0) return null;
                    const handler = nh orelse return null;
                    i += eol_bytes;
                    const skipped = handler.call(data[i..]);
                    if (skipped > 0) {
                        try buf.buffer.appendSlice(alloc, data[last_buf_index..i]);
                        i += skipped;
                        last_buf_index = i;
                    }
                } else break;
            }
            if (i < data.len and (data[i] == '/' or data[i] == '>')) break;
            if (old_i == i) return null;
            i = (try scanAttribute(data, i, nh, &buf, &last_buf_index)) orelse return null;
        }
    }

    i += scanWhitespaceNoNl(data[i..]);
    if (close_tag_bytes == 0) i += scanCh(data[i..], '/');

    if (scanCh(data[i..], '>') == 0) return null;
    i += 1;
    if (buf.buffer.items.len != 0) try buf.buffer.appendSlice(alloc, data[last_buf_index..i]);
    return .{ buf.buffer.items, i };
}

pub const LinkKind = enum { autolink, email };

pub fn scanAutolink(text: []const u8, start_ix: usize) ?struct { usize, []const u8, LinkKind } {
    if (scanUri(text, start_ix)) |r| return .{ r[0], r[1], .autolink };
    if (scanEmail(text, start_ix)) |r| return .{ r[0], r[1], .email };
    return null;
}

fn scanUri(text: []const u8, start_ix: usize) ?struct { usize, []const u8 } {
    const bytes = text[start_ix..];
    if (bytes.len == 0 or !isAsciiAlpha(bytes[0])) return null;
    var i: usize = 1;
    while (i < bytes.len) {
        const c = bytes[i];
        i += 1;
        if (isAsciiAlphanumeric(c) or c == '.' or c == '-' or c == '+') continue;
        if (c == ':') break;
        return null;
    }
    if (!(i >= 3 and i <= 33)) return null;
    while (i < bytes.len) {
        switch (bytes[i]) {
            '>' => return .{ start_ix + i + 1, text[start_ix .. start_ix + i] },
            0...' ', '<' => return null,
            else => {},
        }
        i += 1;
    }
    return null;
}

fn scanEmail(text: []const u8, start_ix: usize) ?struct { usize, []const u8 } {
    const bytes = text[start_ix..];
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        i += 1;
        if (isAsciiAlphanumeric(c)) continue;
        switch (c) {
            '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '-' => continue,
            '@' => if (i > 1) break else return null,
            else => return null,
        }
    }
    while (true) {
        const label_start_ix = i;
        var fresh_label = true;
        while (i < bytes.len) {
            const c = bytes[i];
            if (isAsciiAlphanumeric(c)) {} else if (c == '-') {
                if (fresh_label) return null;
            } else break;
            fresh_label = false;
            i += 1;
        }
        if (i == label_start_ix or i - label_start_ix > 63 or bytes[i - 1] == '-') return null;
        if (scanCh(bytes[i..], '.') == 0) break;
        i += 1;
    }
    if (scanCh(bytes[i..], '>') == 0) return null;
    return .{ start_ix + i + 1, text[start_ix .. start_ix + i] };
}

pub const HtmlScanGuard = struct {
    cdata: usize = 0,
    processing: usize = 0,
    declaration: usize = 0,
    comment: usize = 0,
};

pub fn scanInlineHtmlComment(bytes: []const u8, ix_in: usize, guard: *HtmlScanGuard) ?usize {
    var ix = ix_in;
    if (ix >= bytes.len) return null;
    const c = bytes[ix];
    ix += 1;
    if (c == '-' and ix > guard.comment) {
        if (ix >= bytes.len) return null;
        if (bytes[ix] != '-') return null;
        ix -= 1;
        while (std.mem.indexOfScalar(u8, bytes[ix..], '-')) |x| {
            ix += x + 1;
            guard.comment = ix;
            if (scanCh(bytes[ix..], '-') == 1 and scanCh(bytes[ix + 1 ..], '>') == 1) return ix + 2;
        }
        return null;
    } else if (c == '[' and std.mem.startsWith(u8, bytes[ix..], "CDATA[") and ix > guard.cdata) {
        ix += "CDATA[".len;
        ix = if (std.mem.indexOfScalar(u8, bytes[ix..], ']')) |x| ix + x else bytes.len;
        const close_brackets = scanChRepeat(bytes[ix..], ']');
        ix += close_brackets;
        if (close_brackets == 0 or scanCh(bytes[ix..], '>') == 0) {
            guard.cdata = ix;
            return null;
        }
        return ix + 1;
    } else if (std.ascii.isAlphabetic(c) and ix > guard.declaration) {
        ix = if (std.mem.indexOfScalar(u8, bytes[ix..], '>')) |x| ix + x else bytes.len;
        if (scanCh(bytes[ix..], '>') == 0) {
            guard.declaration = ix;
            return null;
        }
        return ix + 1;
    }
    return null;
}

pub fn scanInlineHtmlProcessing(bytes: []const u8, ix_in: usize, guard: *HtmlScanGuard) ?usize {
    var ix = ix_in;
    if (ix <= guard.processing) return null;
    while (std.mem.indexOfScalar(u8, bytes[ix..], '?')) |offset| {
        ix += offset + 1;
        if (scanCh(bytes[ix..], '>') == 1) return ix + 1;
    }
    guard.processing = ix;
    return null;
}

/// `get_html_end_tag` (firstpass.rs): HTML block types 1–5.
pub fn getHtmlEndTag(text_bytes: []const u8) ?[]const u8 {
    const begin = [_][]const u8{ "pre", "style", "script", "textarea" };
    const ends = [_][]const u8{ "</pre>", "</style>", "</script>", "</textarea>" };
    for (begin, ends) |beg_tag, end_tag| {
        const tag_len = beg_tag.len;
        if (text_bytes.len < tag_len) break;
        if (!std.ascii.eqlIgnoreCase(text_bytes[0..tag_len], beg_tag)) continue;
        if (text_bytes.len == tag_len) return end_tag;
        const s = text_bytes[tag_len];
        if (isAsciiWhitespace(s) or s == '>') return end_tag;
    }
    const st_begin = [_][]const u8{ "!--", "?", "![CDATA[" };
    const st_end = [_][]const u8{ "-->", "?>", "]]>" };
    for (st_begin, st_end) |b, e| {
        if (std.mem.startsWith(u8, text_bytes, b)) return e;
    }
    if (text_bytes.len > 1 and text_bytes[0] == '!' and std.ascii.isAlphabetic(text_bytes[1])) return ">";
    return null;
}

test "scanners basics" {
    try std.testing.expect(scanListitem("4444444444444444444444444444444444444444444444444444444444!") == null);
    try std.testing.expect(scanListitem("1844674407370955161615!") == null);
    for ([_][]const u8{ "<a@b.c>", "<a@b>", "<a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-@example.com>", "<a@sixty-three-letters-in-this-identifier-----------------------63>" }) |e| {
        try std.testing.expect(scanEmail(e, 1) != null);
    }
    for ([_][]const u8{ "<@b.c>", "<foo@-example.com>", "<foo@example-.com>", "<a@notrailingperiod.>", "<a(noparens)@example.com>", "<\"noquotes\"@example.com>", "<a@sixty-four-letters-in-this-identifier-------------------------64>" }) |e| {
        try std.testing.expect(scanEmail(e, 1) == null);
    }
}
