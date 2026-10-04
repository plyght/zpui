//! Review comments pinned to lines in a diff or an editable workspace file,
//! staged on the composer and folded into the next prompt as plain text —
//! port of zeron `crates/ui/src/comments.rs`.
//!
//! `withComments` appends them; `extractBadge` reads the same block back out
//! for the transcript. There is no second data model. Pure (std only); the
//! staged set lives in `review_comments.zig`.
//!
//! ```zig
//! const c: ReviewComment = .{ .id = "…", .path = "src/a.rs", .line = 7, .body = "why?", .source = .{ .diff = .{ .side = .old } } };
//! const prompt = try withComments(a, "look", &.{c}); // "look\n\nComments on the diff (…):\n- src/a.rs:7 (L): why?"
//! const split = (try extractBadge(a, prompt)).?;      // .text = "look", .badge.details[0] = { "src/a.rs:7", "L", "why?" }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CommentSide = enum {
    old,
    new,

    pub fn tag(self: CommentSide) []const u8 {
        return switch (self) {
            .old => "L",
            .new => "R",
        };
    }

    fn marker(self: CommentSide) []const u8 {
        return switch (self) {
            .old => " (L): ",
            .new => " (R): ",
        };
    }
};

/// One side of a diff and a line number on it (`(CommentSide, u32)`).
pub const DiffAnchor = struct {
    side: CommentSide,
    line: u32,

    pub fn eql(a: DiffAnchor, b: DiffAnchor) bool {
        return a.side == b.side and a.line == b.line;
    }
};

pub const CommentSource = union(enum) {
    diff: struct {
        side: CommentSide,
        /// The file's pre-rename path (an `old`-side line lives there).
        old_path: ?[]const u8 = null,
    },
    file,
};

pub const ReviewComment = struct {
    id: []const u8,
    /// The current workspace path. For an old-side diff comment on a renamed
    /// file, `citePath` returns the pre-rename path instead.
    path: []const u8,
    line: u32,
    body: []const u8,
    source: CommentSource,

    pub fn diffAnchor(self: *const ReviewComment) ?DiffAnchor {
        return switch (self.source) {
            .diff => |d| .{ .side = d.side, .line = self.line },
            .file => null,
        };
    }

    pub fn isFile(self: *const ReviewComment) bool {
        return self.source == .file;
    }

    pub fn side(self: *const ReviewComment) ?CommentSide {
        return switch (self.source) {
            .diff => |d| d.side,
            .file => null,
        };
    }

    /// The path the line number is valid in.
    pub fn citePath(self: *const ReviewComment) []const u8 {
        return switch (self.source) {
            .diff => |d| if (d.side == .old) (d.old_path orelse self.path) else self.path,
            .file => self.path,
        };
    }

    /// `path:line`.
    pub fn location(self: *const ReviewComment, a: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(a, "{s}:{d}", .{ self.citePath(), self.line });
    }
};

pub const comment_only_text = "Address the review comments below.";
pub const comment_block_header = "Comments on the diff (each cites the file and line it belongs to; L = line number in the original file, R = in the changed file):";
pub const review_comment_block_header = "Review comments (each cites the workspace file and line it belongs to):";

/// `with_comments`: the prompt with the staged comments appended as located
/// bullets (the text itself when there are none). Caller owns the result.
pub fn withComments(a: Allocator, text: []const u8, comments: []const ReviewComment) Allocator.Error![]u8 {
    if (comments.len == 0) return a.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, if (text.len == 0) comment_only_text else text);
    var all_diff = true;
    for (comments) |*c| if (c.isFile()) {
        all_diff = false;
    };
    try out.appendSlice(a, "\n\n");
    try out.appendSlice(a, if (all_diff) comment_block_header else review_comment_block_header);
    try out.append(a, '\n');
    for (comments, 0..) |*c, i| {
        if (i > 0) try out.append(a, '\n');
        try out.appendSlice(a, "- ");
        try out.print(a, "{s}:{d}", .{ c.citePath(), c.line });
        try out.appendSlice(a, if (c.side()) |s| s.marker() else ": ");
        const body = trimUnicode(c.body);
        for (body) |ch| {
            if (ch == '\n') try out.appendSlice(a, "\n  ") else try out.append(a, ch);
        }
    }
    return out.toOwnedSlice(a);
}

/// One row of a badge's hover card (`badges::BadgeDetail`).
pub const BadgeDetail = struct {
    /// `src/main.rs:42`.
    location: []const u8,
    /// `L` / `R` for a diff side.
    tag: ?[]const u8 = null,
    body: []const u8,
};

/// `badges::MessageBadge` for the comment block (icon: chat-round-line).
pub const MessageBadge = struct {
    label: []const u8,
    details: []BadgeDetail,
};

pub const Extracted = struct {
    /// The message with the comment block removed.
    text: []const u8,
    badge: MessageBadge,
};

/// `extract_badge`: lift a trailing comment block back out of a sent prompt.
/// Matched only as a whole trailing block, so a prompt quoting the header
/// mid-body is left alone. Allocations come from `a` (use an arena).
pub fn extractBadge(a: Allocator, text: []const u8) Allocator.Error!?Extracted {
    const markers = [_][]const u8{
        "\n\n" ++ comment_block_header ++ "\n",
        "\n\n" ++ review_comment_block_header ++ "\n",
    };
    var best: ?struct { at: usize, len: usize } = null;
    for (markers) |m| if (std.mem.lastIndexOf(u8, text, m)) |at| {
        if (best == null or at > best.?.at) best = .{ .at = at, .len = m.len };
    };
    const hit = best orelse return null;
    const block = text[hit.at + hit.len ..];
    if (block.len == 0) return null;
    var check = lines(block);
    while (check.next()) |line| {
        if (!std.mem.startsWith(u8, line, "- ") and !std.mem.startsWith(u8, line, "  ")) return null;
    }
    const details = try parseBullets(a, block);
    if (details.len == 0) return null;
    return .{ .text = text[0..hit.at], .badge = .{ .label = try chipLabel(a, details.len), .details = details } };
}

fn parseBullets(a: Allocator, block: []const u8) Allocator.Error![]BadgeDetail {
    var details: std.ArrayList(BadgeDetail) = .empty;
    var it = lines(block);
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "- ")) {
            if (std.mem.startsWith(u8, line, "  ") and details.items.len > 0) {
                const last = &details.items[details.items.len - 1];
                last.body = try std.fmt.allocPrint(a, "{s}\n{s}", .{ last.body, line[2..] });
            }
            continue;
        }
        const bullet = line[2..];
        // Earliest marker wins: a body may contain "(L): " itself.
        var split: ?struct { at: usize, len: usize, side: CommentSide } = null;
        for ([_]CommentSide{ .old, .new }) |s| if (std.mem.indexOf(u8, bullet, s.marker())) |at| {
            if (split == null or at < split.?.at) split = .{ .at = at, .len = s.marker().len, .side = s };
        };
        const file_split = splitFileBullet(bullet);
        if (file_split) |fs| if (split == null or fs.at < split.?.at) {
            try details.append(a, .{ .location = fs.location, .body = fs.body });
            continue;
        };
        if (split) |s| {
            try details.append(a, .{ .location = bullet[0..s.at], .tag = s.side.tag(), .body = bullet[s.at + s.len ..] });
            continue;
        }
        if (file_split) |fs| try details.append(a, .{ .location = fs.location, .body = fs.body });
    }
    return details.toOwnedSlice(a);
}

const FileSplit = struct { at: usize, location: []const u8, body: []const u8 };

/// The first `": "` whose prefix ends in `:<u32>`.
fn splitFileBullet(bullet: []const u8) ?FileSplit {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, bullet, from, ": ")) |at| : (from = at + 2) {
        const location = bullet[0..at];
        const colon = std.mem.lastIndexOfScalar(u8, location, ':') orelse continue;
        if (!parsesAsU32(location[colon + 1 ..])) continue;
        return .{ .at = at, .location = location, .body = bullet[at + 2 ..] };
    }
    return null;
}

/// Rust `str::parse::<u32>` (an optional `+`, then ASCII digits, in range).
fn parsesAsU32(s: []const u8) bool {
    const digits = if (s.len > 0 and s[0] == '+') s[1..] else s;
    if (digits.len == 0) return false;
    var v: u64 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return false;
        v = v * 10 + (c - '0');
        if (v > std.math.maxInt(u32)) return false;
    }
    return true;
}

/// "1 comment" / "N comments".
pub fn chipLabel(a: Allocator, count: usize) Allocator.Error![]u8 {
    if (count == 1) return a.dupe(u8, "1 comment");
    return std.fmt.allocPrint(a, "{d} comments", .{count});
}

// ---------------------------------------------------------------------------
// Card metrics (analytic: the changes pane sizes bodies by arithmetic to drive
// the fold tween, and a measured card would desync it)
// ---------------------------------------------------------------------------

pub const card_pad_v: f32 = 20;
pub const card_header_height: f32 = 22;
pub const card_line_height: f32 = 18;
pub const draft_card_height: f32 = 116;
pub const comment_adder_size: f32 = 16;
const card_gap: f32 = 6;
const card_wrap_columns: usize = 64;
const card_max_lines: usize = 8;

pub fn cardBodyLines(body: []const u8) usize {
    var total: usize = 0;
    var it = lines(body);
    while (it.next()) |line| {
        const n = std.unicode.utf8CountCodepoints(line) catch line.len;
        total += @max(std.math.divCeil(usize, n, card_wrap_columns) catch 1, 1);
    }
    return std.math.clamp(total, 1, card_max_lines);
}

pub fn cardHeight(body: []const u8) f32 {
    return card_pad_v + card_header_height + @as(f32, @floatFromInt(cardBodyLines(body))) * card_line_height + card_gap;
}

// ---------------------------------------------------------------------------
// Rust `str` helpers
// ---------------------------------------------------------------------------

/// Rust `str::lines`: split on `\n`, strip one trailing `\r`, no empty line
/// after a final newline.
pub const Lines = struct {
    rest: ?[]const u8,

    pub fn next(self: *Lines) ?[]const u8 {
        const r = self.rest orelse return null;
        if (r.len == 0) {
            self.rest = null;
            return null;
        }
        var line: []const u8 = undefined;
        if (std.mem.indexOfScalar(u8, r, '\n')) |nl| {
            line = r[0..nl];
            self.rest = r[nl + 1 ..];
        } else {
            line = r;
            self.rest = null;
        }
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }
};

pub fn lines(s: []const u8) Lines {
    return .{ .rest = s };
}

fn isUnicodeWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// Rust `str::trim` (Unicode `White_Space`).
pub fn trimUnicode(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[start]) catch break;
        if (start + n > s.len) break;
        const cp = std.unicode.utf8Decode(s[start .. start + n]) catch break;
        if (!isUnicodeWhitespace(cp)) break;
        start += n;
    }
    var end: usize = s.len;
    while (end > start) {
        var b = end - 1;
        while (b > start and s[b] & 0xC0 == 0x80) b -= 1;
        const cp = std.unicode.utf8Decode(s[b..end]) catch break;
        if (!isUnicodeWhitespace(cp)) break;
        end = b;
    }
    return s[start..end];
}

// ---------------------------------------------------------------------------
// Editor anchors (`files/preview.rs` `comment_anchor_range` /
// `tracked_comment_line`): a comment on a file line tracks a byte range of the
// buffer through edits, so it follows its line as text is inserted above it.
// ---------------------------------------------------------------------------

pub const AnchorEdge = enum { start, end };

pub const LineAnchor = struct {
    start: usize,
    end: usize,
    edge: AnchorEdge,

    /// Follow one edit that replaced `[at, at + removed)` with `inserted`
    /// bytes — gpui-component `adjust_range_for_edit` (insertions at a range
    /// boundary never grow it). False when the range collapsed to empty: the
    /// decoration is dropped and the comment re-anchors from its last line.
    pub fn applyEdit(self: *LineAnchor, at: usize, removed: usize, inserted: usize) bool {
        const r = adjustRangeForEdit(.{ self.start, self.end }, .{ at, at + removed }, inserted);
        self.start = r[0];
        self.end = r[1];
        return r[0] < r[1];
    }
};

/// gpui-component `decorations.rs` `adjust_range_for_edit`.
pub fn adjustRangeForEdit(range: [2]usize, edited: [2]usize, inserted_len: usize) [2]usize {
    const removed_len = edited[1] -| edited[0];
    const Shift = struct {
        ins: usize,
        rem: usize,
        fn of(sh: @This(), offset: usize) usize {
            return if (sh.ins >= sh.rem) offset +| (sh.ins - sh.rem) else offset -| (sh.rem - sh.ins);
        }
    };
    const sh: Shift = .{ .ins = inserted_len, .rem = removed_len };
    if (edited[0] >= edited[1]) {
        const start = if (range[0] < edited[0]) range[0] else sh.of(range[0]);
        const end = if (range[1] <= edited[0]) range[1] else sh.of(range[1]);
        return .{ start, end };
    }
    const inserted_end = edited[0] + inserted_len;
    const start = if (range[0] <= edited[0]) range[0] else if (range[0] >= edited[1]) sh.of(range[0]) else edited[0];
    const end = if (range[1] <= edited[0]) range[1] else if (range[1] >= edited[1]) sh.of(range[1]) else inserted_end;
    return .{ start, end };
}

/// `comment_anchor_range`: the byte range tracked for 1-based `line` of a text
/// whose line starts are `line_starts` (`line_starts[0] == 0`) and total
/// length `len`.
pub fn anchorForLine(line_starts: []const usize, len: usize, line: u32) ?LineAnchor {
    const ix: usize = if (line == 0) 0 else line - 1;
    if (ix >= line_starts.len) return null;
    const start = line_starts[ix];
    const end = if (ix + 1 < line_starts.len) line_starts[ix + 1] else len;
    if (start < end) return .{ .start = start, .end = end, .edge = .start };
    // The trailing empty line has no byte of its own: track the newline
    // before it and resolve from the range's end.
    if (start > 0) return .{ .start = start - 1, .end = start, .edge = .end };
    return null;
}

/// `tracked_comment_line`: the 1-based line an anchor resolves to now.
pub fn trackedLine(line_starts: []const usize, len: usize, anchor: LineAnchor) u32 {
    const offset = @min(switch (anchor.edge) {
        .start => anchor.start,
        .end => anchor.end,
    }, len);
    // partition_point(start <= offset) - 1
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (line_starts[mid] <= offset) lo = mid + 1 else hi = mid;
    }
    return @intCast(@max(lo, 1));
}

// ---------------------------------------------------------------------------
// Tests (the Rust unit tests, plus `testdata/comments_parity.json`)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn diffComment(path: []const u8, s: CommentSide, line: u32, body: []const u8) ReviewComment {
    return .{ .id = "x", .path = path, .line = line, .body = body, .source = .{ .diff = .{ .side = s } } };
}

fn fileComment(path: []const u8, line: u32, body: []const u8) ReviewComment {
    return .{ .id = "x", .path = path, .line = line, .body = body, .source = .file };
}

test "comments: empty set leaves the prompt untouched" {
    const out = try withComments(testing.allocator, "ship it", &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ship it", out);
}

test "comments: located bullets, comment-only body, multiline indent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try withComments(a, "look at these", &.{
        diffComment("src/main.rs", .new, 42, "early-return here"),
        diffComment("src/lib.rs", .old, 7, "why was this dropped?"),
    });
    try testing.expect(std.mem.startsWith(u8, out, "look at these\n\n"));
    try testing.expect(std.mem.indexOf(u8, out, "- src/main.rs:42 (R): early-return here") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- src/lib.rs:7 (L): why was this dropped?") != null);
    try testing.expect(std.mem.startsWith(u8, try withComments(a, "", &.{diffComment("a.rs", .new, 1, "fix")}), comment_only_text));
    try testing.expect(std.mem.indexOf(u8, try withComments(a, "x", &.{diffComment("a.rs", .new, 3, "first\nsecond")}), "- a.rs:3 (R): first\n  second") != null);
}

test "comments: file comments, mixed blocks, quoted markers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try withComments(a, "review this", &.{fileComment("crates/ui/src/files/preview.rs", 1494, "Keep this branch explicit")});
    try testing.expect(std.mem.indexOf(u8, out, review_comment_block_header) != null);
    try testing.expect(std.mem.indexOf(u8, out, "- crates/ui/src/files/preview.rs:1494: Keep this branch explicit") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(R)") == null);
    const ex = (try extractBadge(a, out)).?;
    try testing.expectEqualStrings("review this", ex.text);
    try testing.expectEqualStrings("crates/ui/src/files/preview.rs:1494", ex.badge.details[0].location);
    try testing.expect(ex.badge.details[0].tag == null);

    const mixed = (try extractBadge(a, try withComments(a, "x", &.{ diffComment("a.rs", .old, 3, "why removed?"), fileComment("odd:path.rs", 8, "change this: please") }))).?;
    try testing.expectEqual(@as(usize, 2), mixed.badge.details.len);
    try testing.expectEqualStrings("L", mixed.badge.details[0].tag.?);
    try testing.expectEqualStrings("odd:path.rs:8", mixed.badge.details[1].location);
    try testing.expectEqualStrings("change this: please", mixed.badge.details[1].body);

    const quoted = (try extractBadge(a, try withComments(a, "x", &.{fileComment("a.rs", 2, "compare with (L): old code")}))).?;
    try testing.expectEqualStrings("a.rs:2", quoted.badge.details[0].location);
    try testing.expect(quoted.badge.details[0].tag == null);
    try testing.expectEqualStrings("compare with (L): old code", quoted.badge.details[0].body);

    const side_quote = (try extractBadge(a, try withComments(a, "x", &.{diffComment("a.rs", .new, 5, "see (L): the other one")}))).?;
    try testing.expectEqualStrings("a.rs:5", side_quote.badge.details[0].location);
    try testing.expectEqualStrings("R", side_quote.badge.details[0].tag.?);
    try testing.expectEqualStrings("see (L): the other one", side_quote.badge.details[0].body);
}

test "comments: renames cite the side the line lives in" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var old = diffComment("new_name.rs", .old, 7, "why dropped?");
    old.source.diff.old_path = "old_name.rs";
    var new = diffComment("new_name.rs", .new, 12, "nit");
    new.source.diff.old_path = "old_name.rs";
    const out = try withComments(arena.allocator(), "x", &.{ old, new });
    try testing.expect(std.mem.indexOf(u8, out, "- old_name.rs:7 (L): why dropped?") != null);
    try testing.expect(std.mem.indexOf(u8, out, "- new_name.rs:12 (R): nit") != null);
}

test "comments: chip label and card metrics" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("1 comment", try chipLabel(a, 1));
    try testing.expectEqualStrings("2 comments", try chipLabel(a, 2));
    try testing.expectEqualStrings("0 comments", try chipLabel(a, 0));
    try testing.expect(cardHeight("two\nlines") > cardHeight("one"));
    try testing.expectEqual(cardHeight(""), cardHeight("one"));
    const x65 = try a.alloc(u8, 65);
    @memset(x65, 'x');
    try testing.expectEqual(@as(usize, 1), cardBodyLines(x65[0..64]));
    try testing.expectEqual(@as(usize, 2), cardBodyLines(x65));
    var many: std.ArrayList(u8) = .empty;
    for (0..200) |_| try many.appendSlice(a, "line\n");
    try testing.expectEqual(@as(usize, card_max_lines), cardBodyLines(many.items));
}

test "comments: editor anchors follow their line through edits" {
    // "a\nbb\nccc\n" — lines start at 0, 2, 5, 9 (trailing empty line).
    const starts = [_]usize{ 0, 2, 5, 9 };
    var a2 = anchorForLine(&starts, 9, 2).?;
    try testing.expectEqual(LineAnchor{ .start = 2, .end = 5, .edge = .start }, a2);
    try testing.expectEqual(LineAnchor{ .start = 8, .end = 9, .edge = .end }, anchorForLine(&starts, 9, 4).?);
    try testing.expect(anchorForLine(&starts, 9, 5) == null);
    try testing.expect(anchorForLine(&[_]usize{0}, 0, 1) == null);
    // Insert "x\n" at the start of the file: the comment moves to line 3.
    try testing.expect(a2.applyEdit(0, 0, 2));
    const after = [_]usize{ 0, 2, 4, 7, 11 };
    try testing.expectEqual(@as(u32, 3), trackedLine(&after, 11, a2));
    // Typing inside the line keeps it there.
    try testing.expect(a2.applyEdit(5, 0, 3));
    try testing.expectEqual(@as(u32, 3), trackedLine(&[_]usize{ 0, 2, 4, 10, 14 }, 14, a2));
    // Deleting the whole line detaches the anchor.
    try testing.expect(!a2.applyEdit(4, 6, 0));
}

test "comments: Rust str helpers" {
    try testing.expectEqualStrings("a b", trimUnicode("\u{3000} a b\u{a0}\n"));
    var it = lines("a\r\nb\n");
    try testing.expectEqualStrings("a", it.next().?);
    try testing.expectEqualStrings("b", it.next().?);
    try testing.expect(it.next() == null);
    try testing.expect(parsesAsU32("+5"));
    try testing.expect(!parsesAsU32("1_0"));
    try testing.expect(!parsesAsU32("4294967296"));
}

test {
    _ = @import("comments_parity_test.zig");
}
