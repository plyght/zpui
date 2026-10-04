//! `Buffer`: the file editor's text storage — a chunked rope sized for files
//! of tens of MB (the composer's `EditorState` keeps one contiguous
//! `ArrayList(u8)`, fine for drafts but O(n) per keystroke on a 30 MB file).
//!
//! - Text lives in chunks of at most `max_chunk` bytes. A freshly loaded
//!   file is not copied: its chunks borrow the loaded bytes and are only
//!   copied (copy-on-write) when an edit touches them.
//! - Every chunk caches its byte length, newline count and UTF-16 length.
//!   Prefix sums over the chunk array are rebuilt lazily after an edit
//!   (O(chunks), ~15k entries for 30 MB), so offset ↔ line ↔ UTF-16
//!   conversions are a binary search plus a scan of one ≤4 KB chunk.
//! - Edits touch one chunk (or split / merge neighbours), so typing in a
//!   huge file costs microseconds.
//!
//! Lines are separated by `\n` only (the engine normalizes CRLF on read and
//! re-applies the file's line ending on write, as zeron's Rust editor does).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_chunk: usize = 4096;
pub const target_chunk: usize = 2048;
/// Neighbours smaller than this together are merged after deletes.
pub const merge_below: usize = 512;

pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(r: Range) usize {
        return r.end - r.start;
    }
    pub fn isEmpty(r: Range) bool {
        return r.start == r.end;
    }
};

const Chunk = struct {
    ptr: [*]u8,
    len: u32,
    /// 0 when the bytes are borrowed from `Buffer.backing`.
    cap: u32,
    newlines: u32,
    utf16: u32,

    fn bytes(c: Chunk) []u8 {
        return c.ptr[0..c.len];
    }

    fn recount(c: *Chunk) void {
        const b = c.bytes();
        c.newlines = @intCast(std.mem.count(u8, b, "\n"));
        c.utf16 = @intCast(utf16Len(b));
    }
};

/// UTF-16 code units of a UTF-8 slice (invalid bytes count as one unit each).
pub fn utf16Len(b: []const u8) usize {
    var n: usize = 0;
    for (b) |byte| {
        if (byte & 0xC0 != 0x80) n += 1; // a lead byte or ASCII
        if (byte >= 0xF0) n += 1; // 4-byte sequences are surrogate pairs
    }
    return n;
}

/// Byte offset into `b` of UTF-16 unit `u` (clamped to `b.len`, never inside a scalar).
pub fn byteForUtf16(b: []const u8, u: usize) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < b.len) {
        if (units >= u) return i;
        const byte = b[i];
        const n: usize = if (byte < 0x80) 1 else if (byte >= 0xF0) 4 else if (byte >= 0xE0) 3 else if (byte >= 0xC0) 2 else 1;
        units += if (n == 4) 2 else 1;
        i = @min(i + n, b.len);
    }
    return b.len;
}

pub const Buffer = struct {
    gpa: Allocator,
    chunks: std.ArrayList(Chunk) = .empty,
    /// Original file bytes borrowed by untouched chunks (owned).
    backing: ?[]u8 = null,
    // Lazily rebuilt prefix sums: value before chunk i (len = chunks + 1).
    pre_bytes: std.ArrayList(usize) = .empty,
    pre_lines: std.ArrayList(usize) = .empty,
    pre_utf16: std.ArrayList(usize) = .empty,
    prefix_valid: bool = false,
    total: usize = 0,
    total_newlines: usize = 0,
    /// Bumped by every mutation.
    revision: u64 = 0,

    pub fn init(gpa: Allocator) Buffer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Buffer) void {
        self.freeChunks();
        self.chunks.deinit(self.gpa);
        self.pre_bytes.deinit(self.gpa);
        self.pre_lines.deinit(self.gpa);
        self.pre_utf16.deinit(self.gpa);
        self.* = undefined;
    }

    fn freeChunks(self: *Buffer) void {
        for (self.chunks.items) |c| if (c.cap > 0) self.gpa.free(c.ptr[0..c.cap]);
        self.chunks.clearRetainingCapacity();
        if (self.backing) |b| self.gpa.free(b);
        self.backing = null;
    }

    /// Replace the whole contents with a copy of `text`.
    pub fn setText(self: *Buffer, text: []const u8) Allocator.Error!void {
        const owned = try self.gpa.dupe(u8, text);
        self.adopt(owned) catch |e| {
            self.gpa.free(owned);
            return e;
        };
    }

    /// Replace the contents with `owned` (allocated by `gpa`); the buffer
    /// takes ownership and borrows from it until edited.
    pub fn adopt(self: *Buffer, owned: []u8) Allocator.Error!void {
        self.freeChunks();
        try self.chunks.ensureTotalCapacity(self.gpa, owned.len / target_chunk + 1);
        self.backing = owned;
        var i: usize = 0;
        while (i < owned.len) {
            var end = @min(i + target_chunk, owned.len);
            // Never split a UTF-8 scalar between chunks.
            while (end < owned.len and owned[end] & 0xC0 == 0x80) end += 1;
            var c: Chunk = .{ .ptr = owned.ptr + i, .len = @intCast(end - i), .cap = 0, .newlines = 0, .utf16 = 0 };
            c.recount();
            self.chunks.appendAssumeCapacity(c);
            i = end;
        }
        if (self.chunks.items.len == 0) try self.chunks.append(self.gpa, .{ .ptr = owned.ptr, .len = 0, .cap = 0, .newlines = 0, .utf16 = 0 });
        self.total = owned.len;
        self.prefix_valid = false;
        self.revision +%= 1;
        self.recountTotals();
    }

    fn recountTotals(self: *Buffer) void {
        var nl: usize = 0;
        for (self.chunks.items) |c| nl += c.newlines;
        self.total_newlines = nl;
    }

    pub fn len(self: *const Buffer) usize {
        return self.total;
    }

    pub fn lineCount(self: *const Buffer) usize {
        return self.total_newlines + 1;
    }

    fn ensurePrefix(self: *Buffer) void {
        if (self.prefix_valid) return;
        const n = self.chunks.items.len;
        self.pre_bytes.resize(self.gpa, n + 1) catch @panic("OOM");
        self.pre_lines.resize(self.gpa, n + 1) catch @panic("OOM");
        self.pre_utf16.resize(self.gpa, n + 1) catch @panic("OOM");
        var b: usize = 0;
        var l: usize = 0;
        var u: usize = 0;
        for (self.chunks.items, 0..) |c, i| {
            self.pre_bytes.items[i] = b;
            self.pre_lines.items[i] = l;
            self.pre_utf16.items[i] = u;
            b += c.len;
            l += c.newlines;
            u += c.utf16;
        }
        self.pre_bytes.items[n] = b;
        self.pre_lines.items[n] = l;
        self.pre_utf16.items[n] = u;
        self.prefix_valid = true;
    }

    /// Last index `i` with `arr[i] <= v` among the first `n` entries.
    fn upperIndex(arr: []const usize, n: usize, v: usize) usize {
        var lo: usize = 0;
        var hi: usize = n; // arr[lo] <= v
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (arr[mid] <= v) lo = mid else hi = mid;
        }
        return lo;
    }

    const Loc = struct { ix: usize, inner: usize };

    /// The chunk holding byte `offset` (offset == len maps to the end of the last chunk).
    fn locate(self: *Buffer, offset: usize) Loc {
        self.ensurePrefix();
        const n = self.chunks.items.len;
        const off = @min(offset, self.total);
        var ix = upperIndex(self.pre_bytes.items, n, off);
        // Prefer the chunk where the offset is interior or at its end, skipping empties.
        while (ix + 1 < n and self.pre_bytes.items[ix + 1] == off and self.chunks.items[ix].len == 0) ix += 1;
        return .{ .ix = ix, .inner = off - self.pre_bytes.items[ix] };
    }

    pub fn byteAt(self: *Buffer, offset: usize) u8 {
        const loc = self.locate(offset);
        const c = self.chunks.items[loc.ix];
        if (loc.inner < c.len) return c.ptr[loc.inner];
        // offset at a chunk end: the next non-empty chunk's first byte
        var i = loc.ix + 1;
        while (i < self.chunks.items.len) : (i += 1) if (self.chunks.items[i].len > 0) return self.chunks.items[i].ptr[0];
        return 0;
    }

    /// Byte offset where line `line` (0-based) starts; lines past the end clamp to `len`.
    pub fn lineStart(self: *Buffer, line: usize) usize {
        if (line == 0) return 0;
        if (line > self.total_newlines) return self.total;
        self.ensurePrefix();
        // The chunk containing the `line`-th newline (1-based count).
        const n = self.chunks.items.len;
        var lo: usize = 0;
        var hi: usize = n;
        // first chunk i with pre_lines[i+1] >= line
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.pre_lines.items[mid + 1] >= line) hi = mid else lo = mid + 1;
        }
        const ix = lo;
        var k = line - self.pre_lines.items[ix];
        const b = self.chunks.items[ix].bytes();
        var i: usize = 0;
        while (i < b.len) : (i += 1) {
            if (b[i] == '\n') {
                k -= 1;
                if (k == 0) return self.pre_bytes.items[ix] + i + 1;
            }
        }
        return self.total;
    }

    /// End of line `line`, excluding its newline.
    pub fn lineEnd(self: *Buffer, line: usize) usize {
        if (line >= self.total_newlines) return self.total;
        return self.lineStart(line + 1) - 1;
    }

    pub fn lineRange(self: *Buffer, line: usize) Range {
        return .{ .start = self.lineStart(line), .end = self.lineEnd(line) };
    }

    pub fn lineLen(self: *Buffer, line: usize) usize {
        const r = self.lineRange(line);
        return r.end - r.start;
    }

    /// The line containing byte `offset`.
    pub fn lineOf(self: *Buffer, offset: usize) usize {
        const loc = self.locate(offset);
        const b = self.chunks.items[loc.ix].bytes();
        return self.pre_lines.items[loc.ix] + std.mem.count(u8, b[0..loc.inner], "\n");
    }

    pub const Point = struct { line: usize, col: usize };

    /// (line, byte column) of `offset`.
    pub fn pointOf(self: *Buffer, offset: usize) Point {
        const line = self.lineOf(offset);
        return .{ .line = line, .col = @min(offset, self.total) - self.lineStart(line) };
    }

    pub fn offsetOf(self: *Buffer, p: Point) usize {
        const r = self.lineRange(p.line);
        return @min(r.start + p.col, r.end);
    }

    /// Append bytes `[start, end)` to `out`.
    pub fn appendRange(self: *Buffer, start_in: usize, end_in: usize, out: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!void {
        const end = @min(end_in, self.total);
        const start = @min(start_in, end);
        if (start == end) return;
        try out.ensureUnusedCapacity(gpa, end - start);
        var loc = self.locate(start);
        var remaining = end - start;
        var inner = loc.inner;
        while (remaining > 0 and loc.ix < self.chunks.items.len) : (loc.ix += 1) {
            const b = self.chunks.items[loc.ix].bytes();
            const take = @min(b.len - inner, remaining);
            out.appendSliceAssumeCapacity(b[inner .. inner + take]);
            remaining -= take;
            inner = 0;
        }
    }

    /// Bytes `[start, end)`: a direct slice when they sit in one chunk,
    /// else a copy in `scratch` (cleared first).
    pub fn slice(self: *Buffer, start_in: usize, end_in: usize, scratch: *std.ArrayList(u8), gpa: Allocator) []const u8 {
        const end = @min(end_in, self.total);
        const start = @min(start_in, end);
        if (start == end) return "";
        const loc = self.locate(start);
        const c = self.chunks.items[loc.ix];
        if (loc.inner + (end - start) <= c.len) return c.bytes()[loc.inner .. loc.inner + (end - start)];
        scratch.clearRetainingCapacity();
        self.appendRange(start, end, scratch, gpa) catch @panic("OOM");
        return scratch.items;
    }

    /// The text of `line` (without its newline); see `slice`.
    pub fn lineText(self: *Buffer, line: usize, scratch: *std.ArrayList(u8), gpa: Allocator) []const u8 {
        const r = self.lineRange(line);
        return self.slice(r.start, r.end, scratch, gpa);
    }

    /// The whole contents as one new allocation.
    pub fn toOwned(self: *Buffer, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.ensureTotalCapacity(gpa, self.total);
        for (self.chunks.items) |c| out.appendSliceAssumeCapacity(c.bytes());
        return out.toOwnedSlice(gpa);
    }

    pub fn eqlSlice(self: *Buffer, text: []const u8) bool {
        if (text.len != self.total) return false;
        var at: usize = 0;
        for (self.chunks.items) |c| {
            if (!std.mem.eql(u8, c.bytes(), text[at .. at + c.len])) return false;
            at += c.len;
        }
        return true;
    }

    // ---- UTF-16 (IME) ----------------------------------------------------------------

    pub fn utf16Offset(self: *Buffer, offset: usize) usize {
        const loc = self.locate(offset);
        return self.pre_utf16.items[loc.ix] + utf16Len(self.chunks.items[loc.ix].bytes()[0..loc.inner]);
    }

    pub fn offsetForUtf16(self: *Buffer, u: usize) usize {
        self.ensurePrefix();
        const n = self.chunks.items.len;
        if (u >= self.pre_utf16.items[n]) return self.total;
        const ix = upperIndex(self.pre_utf16.items, n, u);
        return self.pre_bytes.items[ix] + byteForUtf16(self.chunks.items[ix].bytes(), u - self.pre_utf16.items[ix]);
    }

    // ---- iteration -------------------------------------------------------------------

    pub const ChunkIterator = struct {
        buf: *Buffer,
        ix: usize,
        inner: usize,
        remaining: usize,

        pub fn next(it: *ChunkIterator) ?[]const u8 {
            while (it.remaining > 0 and it.ix < it.buf.chunks.items.len) {
                const b = it.buf.chunks.items[it.ix].bytes();
                const take = @min(b.len - it.inner, it.remaining);
                const out = b[it.inner .. it.inner + take];
                it.ix += 1;
                it.inner = 0;
                it.remaining -= take;
                if (out.len > 0) return out;
            }
            return null;
        }
    };

    pub fn chunksIn(self: *Buffer, start: usize, end: usize) ChunkIterator {
        const s = @min(start, self.total);
        const e = @min(@max(end, s), self.total);
        const loc = self.locate(s);
        return .{ .buf = self, .ix = loc.ix, .inner = loc.inner, .remaining = e - s };
    }

    // ---- mutation --------------------------------------------------------------------

    /// Make chunk `ix` owned with room for at least `need` bytes.
    fn own(self: *Buffer, ix: usize, need: usize) Allocator.Error!void {
        const c = &self.chunks.items[ix];
        if (c.cap >= need) return;
        const cap = @max(need, @min(max_chunk, @max(need * 2, 256)));
        const mem = try self.gpa.alloc(u8, cap);
        @memcpy(mem[0..c.len], c.bytes());
        if (c.cap > 0) self.gpa.free(c.ptr[0..c.cap]);
        c.ptr = mem.ptr;
        c.cap = @intCast(cap);
    }

    fn newChunk(self: *Buffer, text: []const u8) Allocator.Error!Chunk {
        const cap = @max(text.len, 64);
        const mem = try self.gpa.alloc(u8, cap);
        @memcpy(mem[0..text.len], text);
        var c: Chunk = .{ .ptr = mem.ptr, .len = @intCast(text.len), .cap = @intCast(cap), .newlines = 0, .utf16 = 0 };
        c.recount();
        return c;
    }

    /// Split `text` into ≤`target_chunk` chunks at scalar boundaries.
    fn appendChunksFor(self: *Buffer, list: *std.ArrayList(Chunk), text: []const u8) Allocator.Error!void {
        var i: usize = 0;
        while (i < text.len) {
            var end = @min(i + target_chunk, text.len);
            while (end < text.len and text[end] & 0xC0 == 0x80) end += 1;
            try list.append(self.gpa, try self.newChunk(text[i..end]));
            i = end;
        }
    }

    fn freeChunk(self: *Buffer, c: Chunk) void {
        if (c.cap > 0) self.gpa.free(c.ptr[0..c.cap]);
    }

    pub fn insert(self: *Buffer, offset: usize, text: []const u8) Allocator.Error!void {
        if (text.len == 0) return;
        const loc = self.locate(offset);
        const ix = loc.ix;
        const c = self.chunks.items[ix];
        if (c.len + text.len <= max_chunk) {
            try self.own(ix, c.len + text.len);
            const cc = &self.chunks.items[ix];
            const b = cc.ptr[0 .. cc.len + text.len];
            std.mem.copyBackwards(u8, b[loc.inner + text.len ..], b[loc.inner..cc.len]);
            @memcpy(b[loc.inner .. loc.inner + text.len], text);
            cc.len += @intCast(text.len);
            cc.recount();
        } else {
            // Split the chunk at the insertion point and splice new chunks in.
            var mid: std.ArrayList(Chunk) = .empty;
            defer mid.deinit(self.gpa);
            const bytes_ = c.bytes();
            if (loc.inner > 0) try self.appendChunksFor(&mid, bytes_[0..loc.inner]);
            try self.appendChunksFor(&mid, text);
            if (loc.inner < bytes_.len) try self.appendChunksFor(&mid, bytes_[loc.inner..]);
            self.freeChunk(c);
            try self.chunks.replaceRange(self.gpa, ix, 1, mid.items);
        }
        self.total += text.len;
        self.total_newlines += std.mem.count(u8, text, "\n");
        self.prefix_valid = false;
        self.revision +%= 1;
    }

    pub fn delete(self: *Buffer, start_in: usize, end_in: usize) void {
        const end = @min(end_in, self.total);
        const start = @min(start_in, end);
        if (start == end) return;
        var removed_nl: usize = 0;
        {
            var it = self.chunksIn(start, end);
            while (it.next()) |s| removed_nl += std.mem.count(u8, s, "\n");
        }
        const a = self.locate(start);
        // Locate the end with a strict preference for the chunk holding byte end-1.
        const b = self.locate(end - 1);
        const b_inner = b.inner + 1;
        if (a.ix == b.ix) {
            self.own(a.ix, self.chunks.items[a.ix].len) catch @panic("OOM");
            const c = &self.chunks.items[a.ix];
            const bytes_ = c.ptr[0..c.len];
            std.mem.copyForwards(u8, bytes_[a.inner..], bytes_[b_inner..]);
            c.len -= @intCast(b_inner - a.inner);
            c.recount();
        } else {
            // Trim the head chunk's tail and the tail chunk's head; drop the middle.
            {
                const c = &self.chunks.items[a.ix];
                c.len = @intCast(a.inner);
                c.recount();
            }
            {
                self.own(b.ix, self.chunks.items[b.ix].len) catch @panic("OOM");
                const c = &self.chunks.items[b.ix];
                const bytes_ = c.ptr[0..c.len];
                std.mem.copyForwards(u8, bytes_[0..], bytes_[b_inner..]);
                c.len -= @intCast(b_inner);
                c.recount();
            }
            for (self.chunks.items[a.ix + 1 .. b.ix]) |c| self.freeChunk(c);
            self.chunks.replaceRange(self.gpa, a.ix + 1, b.ix - a.ix - 1, &.{}) catch unreachable;
        }
        self.total -= end - start;
        self.total_newlines -= removed_nl;
        self.compactAround(a.ix);
        self.prefix_valid = false;
        self.revision +%= 1;
    }

    /// Merge small neighbours around `ix` and drop empty chunks (keeping one).
    fn compactAround(self: *Buffer, ix_in: usize) void {
        const ix = @min(ix_in, self.chunks.items.len - 1);
        const lo = if (ix > 0) ix - 1 else 0;
        const hi = @min(ix + 2, self.chunks.items.len);
        var i: usize = hi;
        while (i > lo) {
            i -= 1;
            if (self.chunks.items.len <= 1) break;
            const c = self.chunks.items[i];
            if (c.len == 0) {
                self.freeChunk(c);
                _ = self.chunks.orderedRemove(i);
                continue;
            }
            if (i + 1 < self.chunks.items.len) {
                const next = self.chunks.items[i + 1];
                if (c.len + next.len <= max_chunk and (c.len < merge_below or next.len < merge_below)) {
                    self.own(i, c.len + next.len) catch return;
                    const cc = &self.chunks.items[i];
                    @memcpy(cc.ptr[cc.len .. cc.len + next.len], next.bytes());
                    cc.len += next.len;
                    cc.recount();
                    self.freeChunk(next);
                    _ = self.chunks.orderedRemove(i + 1);
                }
            }
        }
    }

    pub fn replace(self: *Buffer, start: usize, end: usize, text: []const u8) Allocator.Error!void {
        self.delete(start, end);
        try self.insert(start, text);
    }

    pub fn chunkCount(self: *const Buffer) usize {
        return self.chunks.items.len;
    }
};

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectContents(buf: *Buffer, expected: []const u8) !void {
    const got = try buf.toOwned(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
    try testing.expectEqual(expected.len, buf.len());
    try testing.expectEqual(std.mem.count(u8, expected, "\n") + 1, buf.lineCount());
}

test "line queries over a small buffer" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.setText("ab\ncde\n\nf");
    try testing.expectEqual(@as(usize, 4), buf.lineCount());
    try testing.expectEqual(@as(usize, 0), buf.lineStart(0));
    try testing.expectEqual(@as(usize, 3), buf.lineStart(1));
    try testing.expectEqual(@as(usize, 7), buf.lineStart(2));
    try testing.expectEqual(@as(usize, 8), buf.lineStart(3));
    try testing.expectEqual(@as(usize, 6), buf.lineEnd(1));
    try testing.expectEqual(@as(usize, 9), buf.lineEnd(3));
    try testing.expectEqual(@as(usize, 2), buf.lineOf(7));
    try testing.expectEqual(@as(usize, 1), buf.lineOf(3));
    try testing.expectEqual(@as(usize, 0), buf.lineOf(2));
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    try testing.expectEqualStrings("cde", buf.lineText(1, &scratch, testing.allocator));
    try testing.expectEqualStrings("", buf.lineText(2, &scratch, testing.allocator));
}

test "edits across many chunks match a reference string" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    var reference: std.ArrayList(u8) = .empty;
    defer reference.deinit(gpa);
    for (0..20000) |i| {
        try reference.append(gpa, if (i % 37 == 0) '\n' else @as(u8, 'a' + @as(u8, @intCast(i % 26))));
    }
    var buf = Buffer.init(gpa);
    defer buf.deinit();
    try buf.setText(reference.items);
    try testing.expect(buf.chunkCount() > 5);
    for (0..400) |_| {
        const at = r.uintAtMost(usize, reference.items.len);
        if (r.boolean()) {
            const n = r.uintAtMost(usize, 9000);
            var text: [9000]u8 = undefined;
            for (text[0..n], 0..) |*c, k| c.* = if (k % 11 == 3) '\n' else 'x';
            try buf.insert(at, text[0..n]);
            try reference.insertSlice(gpa, at, text[0..n]);
        } else {
            const end = @min(reference.items.len, at + r.uintAtMost(usize, 6000));
            buf.delete(at, end);
            reference.replaceRange(gpa, at, end - at, &.{}) catch unreachable;
        }
    }
    try expectContents(&buf, reference.items);
    // Line starts agree with a scan.
    var line: usize = 0;
    var start: usize = 0;
    for (reference.items, 0..) |c, i| {
        if (c == '\n') {
            try testing.expectEqual(start, buf.lineStart(line));
            line += 1;
            start = i + 1;
        }
    }
    try testing.expectEqual(start, buf.lineStart(line));
}

test "utf16 conversions" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.setText("a😀é\nb");
    try testing.expectEqual(@as(usize, 1), buf.utf16Offset(1));
    try testing.expectEqual(@as(usize, 3), buf.utf16Offset(5));
    try testing.expectEqual(@as(usize, 4), buf.utf16Offset(7));
    try testing.expectEqual(@as(usize, 5), buf.offsetForUtf16(3));
    try testing.expectEqual(@as(usize, 7), buf.offsetForUtf16(4));
}

test "empty buffer and full delete" {
    var buf = Buffer.init(testing.allocator);
    defer buf.deinit();
    try buf.setText("");
    try testing.expectEqual(@as(usize, 1), buf.lineCount());
    try buf.insert(0, "hello\nworld");
    try expectContents(&buf, "hello\nworld");
    buf.delete(0, buf.len());
    try expectContents(&buf, "");
    try buf.insert(0, "x");
    try expectContents(&buf, "x");
}
