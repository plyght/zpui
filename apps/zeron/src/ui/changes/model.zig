//! Pure Changes-pane logic — port of zeron `changes.rs` (scope/mode enums,
//! labels, diff resolution, the line-granular row model, folds, sticky file
//! header resolution). No zpui types beyond plain data, so it is unit-tested
//! headless.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diff = @import("zeron_diff");
const engine = @import("zeron_engine");
const zmodel = @import("zeron_model");
const comments = zmodel.comments;

const protocol = engine.protocol;
pub const FileDiff = diff.FileDiff;
pub const DiffLine = diff.DiffLine;
pub const ReviewComment = comments.ReviewComment;
pub const DiffAnchor = comments.DiffAnchor;

// ---------------------------------------------------------------------------
// Layout numbers (analytic — they drive the fold tween)
// ---------------------------------------------------------------------------

/// `surface_chrome::HEADER_HEIGHT` (= the titlebar height).
pub const file_header_height: f32 = 38;
pub const header_height: f32 = 38;
pub const hunk_header_height: f32 = 28;
pub const line_height: f32 = 21;
pub const notice_height: f32 = 24;
pub const body_bottom_pad: f32 = 8;
pub const gutter_min: f32 = 36;
pub const marker_width: f32 = 28;
pub const accent_bar_width: f32 = 3;
pub const split_marker_width: f32 = 18;
pub const split_divider_width: f32 = 1;
pub const text_size: f32 = 12;
pub const tab_size: usize = 4;
pub const unified_code_padding_left: f32 = 12;
pub const split_code_padding_left: f32 = 6;
pub const code_padding_right: f32 = 24;
/// Sticky header frost (`STICKY_FILE_HEADER_*`).
pub const sticky_blur: f32 = 16;
pub const sticky_tint_alpha_dark: f32 = 0.40;
pub const sticky_tint_alpha_light: f32 = 0.85;
/// Fold tween (`COLLAPSE` 180ms, armed for `FOLD_TWEEN_WINDOW`).
pub const fold_tween_ms: u64 = 180;
pub const fold_tween_window_ms: u64 = 400;
pub const fold_tween_max_px: f32 = 2400;

/// `surface_chrome` control metrics.
pub const control_size: f32 = 24;
pub const control_radius: f32 = 6;
pub const icon_size: f32 = 14;
pub const control_gap: f32 = 4;
pub const edge_inset: f32 = 8;

/// One line-number gutter column fitted to the file's largest line number
/// (11px mono ≈ 6.6px per digit, 8px right pad, 6px left gap), never
/// narrower than 36px.
pub fn gutterWidth(file: *const FileDiff) f32 {
    const digits: f32 = @floatFromInt(std.math.log10_int(@max(file.max_line, 1)) + 1);
    return @max(digits * 6.6 + 8 + 6, gutter_min);
}

// ---------------------------------------------------------------------------
// Scope / mode
// ---------------------------------------------------------------------------

/// How the diff is laid out (persisted as `diffSplit`).
pub const DiffMode = enum {
    unified,
    split,

    pub fn toggled(self: DiffMode) DiffMode {
        return if (self == .unified) .split else .unified;
    }
};

/// What the pane diffs against (t3code's scope dropdown).
pub const DiffScope = enum {
    working_tree,
    branch,
    latest_turn,
    history,
    commit,

    /// The scope menu rows (History lives in its own surface tab).
    pub const menu = [_]DiffScope{ .working_tree, .branch, .latest_turn };

    pub fn label(self: DiffScope) []const u8 {
        return switch (self) {
            .working_tree => "Working tree",
            .branch => "Branch changes",
            .latest_turn => "Latest turn",
            .history => "History",
            .commit => "Commit",
        };
    }

    /// Wire value for `GetCheckoutDiff` `mode`.
    pub fn mode(self: DiffScope) []const u8 {
        return switch (self) {
            .working_tree => "workingTree",
            .branch => "branch",
            .latest_turn => "turn",
            .history => "history",
            .commit => "commit",
        };
    }
};

/// "N Uncommitted change(s)".
pub fn uncommittedLabel(a: Allocator, count: usize) []const u8 {
    if (count == 1) return "1 Uncommitted change";
    return std.fmt.allocPrint(a, "{d} Uncommitted changes", .{count}) catch "Uncommitted changes";
}

/// Header-strip label per scope.
pub fn scopeLabel(a: Allocator, scope: DiffScope, count: usize, base: ?[]const u8) []const u8 {
    const files = if (count == 1) "file" else "files";
    return switch (scope) {
        .working_tree => uncommittedLabel(a, count),
        .branch => if (base) |b|
            std.fmt.allocPrint(a, "{d} Changed {s} vs {s}", .{ count, files, b }) catch ""
        else
            std.fmt.allocPrint(a, "{d} Changed {s}", .{ count, files }) catch "",
        .latest_turn => std.fmt.allocPrint(a, "{d} Changed {s} this turn", .{ count, files }) catch "",
        .history => "History",
        .commit => std.fmt.allocPrint(a, "{d} Changed {s} in this commit", .{ count, files }) catch "",
    };
}

/// Empty-state copy per scope.
pub fn cleanMessage(a: Allocator, scope: DiffScope, base: ?[]const u8) []const u8 {
    return switch (scope) {
        .working_tree => "No uncommitted changes",
        .branch => if (base) |b| std.fmt.allocPrint(a, "No changes vs {s}", .{b}) catch "No branch changes" else "No branch changes",
        .latest_turn => "No changes this turn",
        .history => "No commits found",
        .commit => "Empty commit",
    };
}

/// The comparison ref the branch scope preselects: the repo's default branch
/// (first entry), unless that is the checked-out branch — then main/master,
/// then any other branch.
pub fn defaultBaseRef(branches: []const []const u8, current: ?[]const u8) ?[]const u8 {
    if (branches.len == 0) return null;
    const first = branches[0];
    if (!eqlOpt(current, first)) return first;
    for ([_][]const u8{ "main", "master" }) |candidate| {
        for (branches) |b| if (std.mem.eql(u8, b, candidate)) return candidate;
    }
    for (branches) |b| if (!eqlOpt(current, b)) return b;
    return first;
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

// ---------------------------------------------------------------------------
// Resolution / phase
// ---------------------------------------------------------------------------

/// The diff shown for a chat: `checkoutId` match first, then device+cwd,
/// then cwd alone.
pub fn resolveDiff(diffs: []const *const protocol.CheckoutDiff, chat: *const protocol.Chat) ?*const protocol.CheckoutDiff {
    if (chat.checkoutId) |id| for (diffs) |d| if (std.mem.eql(u8, d.checkoutId, id)) return d;
    const cwd = chat.cwd orelse return null;
    for (diffs) |d| if (std.mem.eql(u8, d.deviceId, chat.deviceId) and std.mem.eql(u8, d.cwd, cwd)) return d;
    for (diffs) |d| if (std.mem.eql(u8, d.cwd, cwd)) return d;
    return null;
}

pub const DiffPhase = enum { preparing, clean, list };

pub fn diffPhase(resolved: ?*const protocol.CheckoutDiff) DiffPhase {
    const d = resolved orelse return .preparing;
    if (std.mem.trim(u8, d.patch, " \t\r\n").len == 0 and d.files.len == 0) return .clean;
    return .list;
}

// ---------------------------------------------------------------------------
// Row model — the diff flattened to line granularity
// ---------------------------------------------------------------------------

/// One virtualized list row.
pub const DiffRow = union(enum) {
    file_header: u32,
    notice: struct { file: u32, notice: u32 },
    hunk_header: struct { file: u32, hunk: u32 },
    line: struct { file: u32, hunk: u32, line: u32 },
    split_line: struct { file: u32, hunk: u32, left: ?u32, right: ?u32 },
    /// `card` indexes the file's own staged-comment slice, in staged order.
    comment_card: struct { file: u32, card: u32 },
    comment_draft: u32,
    /// Trailing pad closing an expanded body.
    body_pad: u32,
    /// A body mid-fold-tween: one height-animated clipped stand-in row.
    folding_body: u32,

    pub fn file(self: DiffRow) usize {
        return switch (self) {
            .file_header, .body_pad, .folding_body, .comment_draft => |f| f,
            inline .notice, .hunk_header, .line, .split_line, .comment_card => |r| r.file,
        };
    }

    /// `comments`: the file's own staged slice (sizes its cards).
    pub fn height(self: DiffRow, file_comments: []const ReviewComment) f32 {
        return switch (self) {
            .file_header => file_header_height,
            .notice => notice_height,
            .hunk_header => hunk_header_height,
            .line, .split_line => line_height,
            .comment_card => |c| if (c.card < file_comments.len) comments.cardHeight(file_comments[c.card].body) else 0,
            .comment_draft => comments.draft_card_height,
            .body_pad => body_bottom_pad,
            .folding_body => 0,
        };
    }

    pub fn eql(a: DiffRow, b: DiffRow) bool {
        return std.meta.eql(a, b);
    }
};

pub const RowRange = struct {
    start: usize,
    end: usize,

    pub fn contains(r: RowRange, ix: usize) bool {
        return ix >= r.start and ix < r.end;
    }
};

/// `file_notices(file).len()`.
pub fn noticeCount(file: *const FileDiff) usize {
    var n: usize = file.notices.len;
    if (file.status != .modified) n += 1;
    if (file.binary) n += 1;
    return n;
}

/// `line_anchor`: a deletion only exists in the pre-change file; everything
/// else is cited against the post-change file, which is what the agent edits.
pub fn lineAnchor(line: *const DiffLine) ?DiffAnchor {
    return switch (line.kind) {
        .meta => null,
        .del => if (line.old_no) |n| .{ .side = .old, .line = n } else null,
        else => if (line.new_no) |n| .{ .side = .new, .line = n } else null,
    };
}

/// `pair_anchors`: a split row's anchors (a context row names the same
/// anchor on both sides, so the duplicate is dropped).
pub fn pairAnchors(lines: []const DiffLine, left: ?u32, right: ?u32) [2]?DiffAnchor {
    const l: ?DiffAnchor = if (left) |ix| (if (ix < lines.len) lineAnchor(&lines[ix]) else null) else null;
    const r: ?DiffAnchor = if (right) |ix| (if (ix < lines.len) lineAnchor(&lines[ix]) else null) else null;
    const same = if (l != null and r != null) l.?.eql(r.?) else l == null and r == null;
    return if (same) .{ l, null } else .{ l, r };
}

fn pushCards(a: Allocator, out: *std.ArrayList(DiffRow), file_ix: u32, file_comments: []const ReviewComment, draft: ?DiffAnchor, anchors: []const ?DiffAnchor) Allocator.Error!void {
    for (anchors) |maybe| {
        const anchor = maybe orelse continue;
        for (file_comments, 0..) |*c, ix| {
            const ca = c.diffAnchor() orelse continue;
            if (ca.eql(anchor)) try out.append(a, .{ .comment_card = .{ .file = file_ix, .card = @intCast(ix) } });
        }
        if (draft) |d| if (d.eql(anchor)) try out.append(a, .{ .comment_draft = file_ix });
    }
}

/// The expanded body rows of one file (notices, hunks, lines/pairs with
/// their comment cards, pad). `file_comments` is this file's staged slice.
pub fn bodyRowsWith(a: Allocator, out: *std.ArrayList(DiffRow), file_ix: u32, file: *const FileDiff, file_comments: []const ReviewComment, draft: ?DiffAnchor, mode: DiffMode) Allocator.Error!void {
    for (0..noticeCount(file)) |n| try out.append(a, .{ .notice = .{ .file = file_ix, .notice = @intCast(n) } });
    for (file.hunks, 0..) |hunk, hi| {
        const h: u32 = @intCast(hi);
        try out.append(a, .{ .hunk_header = .{ .file = file_ix, .hunk = h } });
        switch (mode) {
            .unified => for (hunk.lines, 0..) |*line, li| {
                try out.append(a, .{ .line = .{ .file = file_ix, .hunk = h, .line = @intCast(li) } });
                try pushCards(a, out, file_ix, file_comments, draft, &.{lineAnchor(line)});
            },
            .split => {
                // `splitPairs` leaks its scratch lists (arena-oriented): pair
                // in a local arena.
                var scratch: std.heap.ArenaAllocator = .init(a);
                defer scratch.deinit();
                const pairs = try diff.splitPairs(scratch.allocator(), hunk.lines);
                for (pairs) |p| {
                    try out.append(a, .{ .split_line = .{ .file = file_ix, .hunk = h, .left = p.left, .right = p.right } });
                    const anchors = pairAnchors(hunk.lines, p.left, p.right);
                    try pushCards(a, out, file_ix, file_comments, draft, &anchors);
                }
            },
        }
    }
    try out.append(a, .{ .body_pad = file_ix });
}

pub fn bodyRows(a: Allocator, out: *std.ArrayList(DiffRow), file_ix: u32, file: *const FileDiff, mode: DiffMode) Allocator.Error!void {
    return bodyRowsWith(a, out, file_ix, file, &.{}, null, mode);
}

/// Analytic expanded-body height (drives the fold tween), cards included.
pub fn bodyHeightWith(a: Allocator, file: *const FileDiff, file_comments: []const ReviewComment, draft: ?DiffAnchor, mode: DiffMode) f32 {
    var rows: std.ArrayList(DiffRow) = .empty;
    defer rows.deinit(a);
    bodyRowsWith(a, &rows, 0, file, file_comments, draft, mode) catch return 0;
    var h: f32 = 0;
    for (rows.items) |r| h += r.height(file_comments);
    return h;
}

pub fn bodyHeight(a: Allocator, file: *const FileDiff, mode: DiffMode) f32 {
    return bodyHeightWith(a, file, &.{}, null, mode);
}

/// The diff comments staged on `path` (file comments never render in a diff).
pub fn commentsFor(a: Allocator, staged: []const ReviewComment, path: []const u8) Allocator.Error![]ReviewComment {
    var out: std.ArrayList(ReviewComment) = .empty;
    errdefer out.deinit(a);
    for (staged) |c| if (!c.isFile() and std.mem.eql(u8, c.path, path)) try out.append(a, c);
    return out.toOwnedSlice(a);
}

/// A draft anchored in one file (`(path, side, line)`).
pub const DraftAnchor = struct { path: []const u8, anchor: DiffAnchor };

pub const Flattened = struct {
    rows: std.ArrayList(DiffRow) = .empty,
    ranges: std.ArrayList(RowRange) = .empty,

    pub fn deinit(self: *Flattened, a: Allocator) void {
        self.rows.deinit(a);
        self.ranges.deinit(a);
    }
};

/// Flatten all files into rows plus each file's row span (header at
/// `range.start`). `collapsed[ix]` folds a file to just its header;
/// `staged` is the whole staged comment set (each file takes its slice).
pub fn flattenRowsWith(a: Allocator, files: []const FileDiff, staged: []const ReviewComment, draft: ?DraftAnchor, mode: DiffMode, collapsed: []const bool) Allocator.Error!Flattened {
    var out: Flattened = .{};
    errdefer out.deinit(a);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    for (files, 0..) |*f, ix| {
        const start = out.rows.items.len;
        try out.rows.append(a, .{ .file_header = @intCast(ix) });
        const shut = ix < collapsed.len and collapsed[ix];
        if (!shut) {
            const fc = try commentsFor(scratch.allocator(), staged, f.path);
            const fd: ?DiffAnchor = if (draft) |d| (if (std.mem.eql(u8, d.path, f.path)) d.anchor else null) else null;
            try bodyRowsWith(a, &out.rows, @intCast(ix), f, fc, fd, mode);
        }
        try out.ranges.append(a, .{ .start = start, .end = out.rows.items.len });
    }
    return out;
}

pub fn flattenRows(a: Allocator, files: []const FileDiff, mode: DiffMode, collapsed: []const bool) Allocator.Error!Flattened {
    return flattenRowsWith(a, files, &.{}, null, mode, collapsed);
}

/// `comment_state_key`: changes whenever a staged comment's identity/body or
/// the draft anchor does (cheap re-flatten gate).
pub fn commentStateKey(staged: []const ReviewComment, draft: ?DraftAnchor) u64 {
    var h = std.hash.Wyhash.init(0);
    for (staged) |c| {
        h.update(c.id);
        h.update(&.{0});
        h.update(c.body);
        h.update(&.{0});
    }
    if (draft) |d| {
        h.update("draft:");
        h.update(d.path);
        h.update(d.anchor.side.tag());
        h.update(std.mem.asBytes(&d.anchor.line));
    }
    return h.final();
}

/// `comment_adder_left`: a unified row carries both gutters side by side, and
/// a deletion numbers in the first.
pub fn commentAdderLeft(side: comments.CommentSide, gutter_px: f32) f32 {
    const column: f32 = if (side == .old) 0 else gutter_px;
    return accent_bar_width + column + (gutter_px - comments.comment_adder_size) / 2;
}

/// `split_adder_left`: a split row's `+` only appears in the right column.
pub fn splitAdderLeft(gutter_px: f32) f32 {
    return accent_bar_width + (gutter_px - comments.comment_adder_size) / 2;
}

/// Replace one file's body rows (everything after its header) with `new_body`,
/// shifting later ranges. Returns the changed row range in the OLD model and
/// the new count there (what `ListState.splice` needs), or null if unchanged.
pub fn replaceFileBody(a: Allocator, flat: *Flattened, file_ix: usize, new_body: []const DiffRow) Allocator.Error!?struct { start: usize, end: usize, count: usize } {
    if (file_ix >= flat.ranges.items.len) return null;
    const range = flat.ranges.items[file_ix];
    const body_start = range.start + 1;
    const old = flat.rows.items[body_start..range.end];
    var prefix: usize = 0;
    while (prefix < old.len and prefix < new_body.len and old[prefix].eql(new_body[prefix])) prefix += 1;
    var suffix: usize = 0;
    while (suffix < old.len - prefix and suffix < new_body.len - prefix and
        old[old.len - 1 - suffix].eql(new_body[new_body.len - 1 - suffix])) suffix += 1;
    if (old.len == new_body.len and prefix + suffix >= old.len) return null;
    const changed_start = body_start + prefix;
    const changed_end = range.end - suffix;
    const mid = new_body[prefix .. new_body.len - suffix];
    try flat.rows.replaceRange(a, changed_start, changed_end - changed_start, mid);
    const delta: isize = @as(isize, @intCast(new_body.len)) - @as(isize, @intCast(old.len));
    flat.ranges.items[file_ix].end = @intCast(@as(isize, @intCast(range.end)) + delta);
    for (flat.ranges.items[file_ix + 1 ..]) |*r| {
        r.start = @intCast(@as(isize, @intCast(r.start)) + delta);
        r.end = @intCast(@as(isize, @intCast(r.end)) + delta);
    }
    return .{ .start = changed_start, .end = changed_end, .count = mid.len };
}

// ---------------------------------------------------------------------------
// Sticky file header
// ---------------------------------------------------------------------------

pub const StickyFileHeader = struct {
    file_ix: usize,
    header_row: usize,
    next_header_row: ?usize,
};

/// The file header that should stay pinned for a logical list position.
pub fn stickyFileHeader(ranges: []const RowRange, item_ix: usize, offset_in_item: f32) ?StickyFileHeader {
    // partition_point(range.start <= item_ix) - 1
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (ranges[mid].start <= item_ix) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const file_ix = lo - 1;
    const range = ranges[file_ix];
    if (!range.contains(item_ix) or (item_ix == range.start and offset_in_item <= 0)) return null;
    return .{
        .file_ix = file_ix,
        .header_row = range.start,
        .next_header_row = if (file_ix + 1 < ranges.len) ranges[file_ix + 1].start else null,
    };
}

/// Push a sticky header upward as the next file header enters its slot.
pub fn stickyPushOffset(next_header_y: ?f32) f32 {
    const y = next_header_y orelse return 0;
    return @min(y - file_header_height, 0);
}

// ---------------------------------------------------------------------------
// Folds
// ---------------------------------------------------------------------------

pub const FileFold = struct {
    collapsed: bool = false,
    /// Bumped per toggle — keys the height tween + chevron transition.
    epoch: u32 = 0,
    from: f32 = 0,
    to: f32 = 0,
    /// Monotonic ns of the toggle (tweens arm only briefly after a click).
    toggled_at_ns: ?u64 = null,

    pub fn animating(self: FileFold, now_ns: u64) bool {
        const at = self.toggled_at_ns orelse return false;
        return self.epoch > 0 and now_ns -| at < fold_tween_window_ms * std.time.ns_per_ms;
    }
};

// ---------------------------------------------------------------------------
// Horizontal geometry
// ---------------------------------------------------------------------------

/// Terminal-style display columns (tab stops at 4; wide CJK counts 2).
pub fn visualColumns(text: []const u8) usize {
    var cols: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\t') {
            cols += tab_size - cols % tab_size;
        } else if (cp >= 0x1100 and (cp <= 0x115f or (cp >= 0x2e80 and cp <= 0xa4cf) or (cp >= 0xac00 and cp <= 0xd7a3) or (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xfe30 and cp <= 0xfe4f) or (cp >= 0xff00 and cp <= 0xff60) or (cp >= 0x1f300 and cp <= 0x1faff))) {
            cols += 2;
        } else if (cp >= 0x20) {
            cols += 1;
        }
    }
    return cols;
}

pub fn maxColumns(file: *const FileDiff) usize {
    var m: usize = 0;
    for (file.hunks) |h| for (h.lines) |l| {
        m = @max(m, visualColumns(l.text));
    };
    return m;
}

/// Expand tabs to 4-column stops (the code plane renders spaces).
pub fn expandTabs(a: Allocator, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\t') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var col: usize = 0;
    for (s) |c| {
        if (c == '\t') {
            const n = tab_size - col % tab_size;
            out.appendNTimes(a, ' ', n) catch return s;
            col += n;
        } else {
            out.append(a, c) catch return s;
            if (c & 0xC0 != 0x80) col += 1;
        }
    }
    return out.toOwnedSlice(a) catch s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const sample_patch =
    \\diff --git a/src/a.rs b/src/a.rs
    \\--- a/src/a.rs
    \\+++ b/src/a.rs
    \\@@ -1,3 +1,3 @@
    \\ one
    \\-two
    \\+TWO
    \\ three
    \\diff --git a/new.txt b/new.txt
    \\new file mode 100644
    \\--- /dev/null
    \\+++ b/new.txt
    \\@@ -0,0 +1,2 @@
    \\+x
    \\+y
    \\
;

test "labels" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("1 Uncommitted change", uncommittedLabel(a, 1));
    try testing.expectEqualStrings("3 Uncommitted changes", scopeLabel(a, .working_tree, 3, null));
    try testing.expectEqualStrings("2 Changed files vs main", scopeLabel(a, .branch, 2, "main"));
    try testing.expectEqualStrings("1 Changed file this turn", scopeLabel(a, .latest_turn, 1, null));
    try testing.expectEqualStrings("No changes vs main", cleanMessage(a, .branch, "main"));
}

test "default base ref" {
    try testing.expectEqualStrings("main", defaultBaseRef(&.{ "main", "feat" }, "feat").?);
    try testing.expectEqualStrings("master", defaultBaseRef(&.{ "feat", "dev", "master" }, "feat").?);
    try testing.expectEqualStrings("dev", defaultBaseRef(&.{ "feat", "dev" }, "feat").?);
    try testing.expect(defaultBaseRef(&.{}, null) == null);
}

test "flatten, fold and sticky" {
    var ps = try diff.parsePatch(testing.allocator, sample_patch);
    defer ps.deinit();
    try testing.expectEqual(@as(usize, 2), ps.files.len);
    var flat = try flattenRows(testing.allocator, ps.files, .unified, &.{});
    defer flat.deinit(testing.allocator);
    // file0: header, hunk, 4 lines, pad; file1: header, notice, hunk, 2 lines, pad
    try testing.expectEqual(@as(usize, 7 + 6), flat.rows.items.len);
    try testing.expectEqual(RowRange{ .start = 7, .end = 13 }, flat.ranges.items[1]);
    // Collapse file 0.
    const r = (try replaceFileBody(testing.allocator, &flat, 0, &.{})).?;
    try testing.expectEqual(@as(usize, 1), r.start);
    try testing.expectEqual(@as(usize, 7), r.end);
    try testing.expectEqual(@as(usize, 0), r.count);
    try testing.expectEqual(RowRange{ .start = 1, .end = 7 }, flat.ranges.items[1]);
    try testing.expect(stickyFileHeader(flat.ranges.items, 0, 0) == null);
    const s = stickyFileHeader(flat.ranges.items, 3, 0).?;
    try testing.expectEqual(@as(usize, 1), s.file_ix);
    try testing.expectEqual(@as(?usize, null), s.next_header_row);
    try testing.expectEqual(@as(f32, -10), stickyPushOffset(28));
    try testing.expectEqual(@as(f32, 0), stickyPushOffset(null));
    // Split mode pairs the -two/+TWO edit into one row.
    var split = try flattenRows(testing.allocator, ps.files, .split, &.{});
    defer split.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6 + 6), split.rows.items.len);
    try testing.expectEqual(@as(f32, 28 + 3 * 21 + 8), bodyHeight(testing.allocator, &ps.files[0], .split));
}

test "gutter and columns" {
    var f: FileDiff = .{ .path = "x", .max_line = 12345 };
    try testing.expectEqual(@as(f32, 5 * 6.6 + 14), gutterWidth(&f));
    f.max_line = 9;
    try testing.expectEqual(@as(f32, 36), gutterWidth(&f));
    try testing.expectEqual(@as(usize, 8), visualColumns("\tab"[0..1] ++ "abcd"));
    const ex = expandTabs(testing.allocator, "\tx");
    defer testing.allocator.free(ex);
    try testing.expectEqualStrings("    x", ex);
}

test "resolve diff" {
    const d1: protocol.CheckoutDiff = .{ .checkoutId = "c1", .deviceId = "d", .cwd = "/a", .patch = "", .files = &.{}, .additions = 0, .deletions = 0, .truncated = false, .checksum = "", .updatedAt = "" };
    const d2: protocol.CheckoutDiff = .{ .checkoutId = "c2", .deviceId = "e", .cwd = "/b", .patch = "x", .files = &.{}, .additions = 0, .deletions = 0, .truncated = false, .checksum = "", .updatedAt = "" };
    const list = [_]*const protocol.CheckoutDiff{ &d1, &d2 };
    var chat: protocol.Chat = .{ .id = "x", .deviceId = "d", .archived = false, .createdAt = "", .cwd = "/b" };
    try testing.expectEqual(&d2, resolveDiff(&list, &chat).?);
    chat.checkoutId = "c1";
    try testing.expectEqual(&d1, resolveDiff(&list, &chat).?);
    try testing.expectEqual(DiffPhase.clean, diffPhase(&d1));
    try testing.expectEqual(DiffPhase.list, diffPhase(&d2));
    try testing.expectEqual(DiffPhase.preparing, diffPhase(null));
}

const rust_patch =
    \\diff --git a/src/main.rs b/src/main.rs
    \\index 111..222 100644
    \\--- a/src/main.rs
    \\+++ b/src/main.rs
    \\@@ -1,4 +1,5 @@ fn main
    \\ fn main() {
    \\-    println!("old");
    \\+    println!("new");
    \\+    let x = 1;
    \\ }
    \\@@ -10,2 +11,2 @@
    \\ // tail
    \\-old_line
    \\+new_line
    \\
;

fn diffComment(path: []const u8, side: comments.CommentSide, line: u32, body: []const u8) ReviewComment {
    return .{ .id = body, .path = path, .line = line, .body = body, .source = .{ .diff = .{ .side = side } } };
}

test "comments: a split row offers each column its own anchor" {
    var ps = try diff.parsePatch(testing.allocator, rust_patch);
    defer ps.deinit();
    const lines = ps.files[0].hunks[0].lines;
    const edit = pairAnchors(lines, 1, 2);
    try testing.expectEqual(DiffAnchor{ .side = .old, .line = 2 }, edit[0].?);
    try testing.expectEqual(DiffAnchor{ .side = .new, .line = 2 }, edit[1].?);
    const ctx = pairAnchors(lines, 0, 0);
    try testing.expectEqual(DiffAnchor{ .side = .new, .line = 1 }, ctx[0].?);
    try testing.expect(ctx[1] == null);
    const stranded = pairAnchors(lines, null, 3);
    try testing.expect(stranded[0] == null);
    try testing.expectEqual(DiffAnchor{ .side = .new, .line = 3 }, stranded[1].?);
}

test "comments: split rows carry the comments of both columns" {
    var ps = try diff.parsePatch(testing.allocator, rust_patch);
    defer ps.deinit();
    const a = testing.allocator;
    var rows: std.ArrayList(DiffRow) = .empty;
    defer rows.deinit(a);
    try bodyRowsWith(a, &rows, 0, &ps.files[0], &.{diffComment("src/main.rs", .new, 1, "why")}, null, .split);
    var cards: usize = 0;
    for (rows.items) |r| if (r == .comment_card) {
        cards += 1;
    };
    try testing.expectEqual(@as(usize, 1), cards);

    rows.clearRetainingCapacity();
    const staged = [_]ReviewComment{ diffComment("src/main.rs", .old, 2, "left"), diffComment("src/main.rs", .new, 2, "right") };
    try bodyRowsWith(a, &rows, 0, &ps.files[0], &staged, null, .split);
    const edit = for (rows.items, 0..) |r, i| {
        if (r == .split_line and r.split_line.left == 1) break i;
    } else return error.TestUnexpectedResult;
    try testing.expect(rows.items[edit + 1].eql(.{ .comment_card = .{ .file = 0, .card = 0 } }));
    try testing.expect(rows.items[edit + 2].eql(.{ .comment_card = .{ .file = 0, .card = 1 } }));
}

test "comments: cards anchor to (side, line) through diff edits" {
    const a = testing.allocator;
    const staged = [_]ReviewComment{
        diffComment("src/main.rs", .old, 2, "why dropped?"),
        diffComment("src/main.rs", .new, 3, "nit"),
        diffComment("other.rs", .new, 1, "elsewhere"),
        .{ .id = "f", .path = "src/main.rs", .line = 1, .body = "file", .source = .file },
    };
    var ps = try diff.parsePatch(a, rust_patch);
    defer ps.deinit();
    var flat = try flattenRowsWith(a, ps.files, &staged, .{ .path = "src/main.rs", .anchor = .{ .side = .new, .line = 12 } }, .unified, &.{});
    defer flat.deinit(a);
    // Unified: the deletion `-old("old")` (L2) and `+let x` (R3) each take their card,
    // right after their own line; the draft hangs under `+new_line` (R12).
    var seen: [3]?usize = .{ null, null, null };
    for (flat.rows.items, 0..) |r, i| switch (r) {
        .comment_card => |c| seen[c.card] = i,
        .comment_draft => seen[2] = i,
        else => {},
    };
    const del_row = flat.rows.items[seen[0].? - 1].line;
    try testing.expectEqual(diff.LineKind.del, ps.files[0].hunks[del_row.hunk].lines[del_row.line].kind);
    const add_row = flat.rows.items[seen[1].? - 1].line;
    try testing.expectEqual(@as(?u32, 3), ps.files[0].hunks[add_row.hunk].lines[add_row.line].new_no);
    const draft_row = flat.rows.items[seen[2].? - 1].line;
    try testing.expectEqual(@as(?u32, 12), ps.files[0].hunks[draft_row.hunk].lines[draft_row.line].new_no);

    // The patch changes under the staged set: a line inserted above shifts the
    // new side; R3 is now a context line and the card follows the number, and
    // the old-side L2 no longer exists in the diff, so its card is not drawn.
    const edited =
        \\diff --git a/src/main.rs b/src/main.rs
        \\--- a/src/main.rs
        \\+++ b/src/main.rs
        \\@@ -1,3 +1,4 @@
        \\+// header
        \\ fn main() {
        \\     println!("new");
        \\     let x = 1;
        \\
    ;
    var ps2 = try diff.parsePatch(a, edited);
    defer ps2.deinit();
    var flat2 = try flattenRowsWith(a, ps2.files, &staged, null, .unified, &.{});
    defer flat2.deinit(a);
    var cards: usize = 0;
    for (flat2.rows.items, 0..) |r, i| if (r == .comment_card) {
        cards += 1;
        try testing.expectEqual(@as(u32, 1), r.comment_card.card);
        const l = flat2.rows.items[i - 1].line;
        try testing.expectEqual(@as(?u32, 3), ps2.files[0].hunks[l.hunk].lines[l.line].new_no);
    };
    try testing.expectEqual(@as(usize, 1), cards);
    // Folded bodies carry their cards' analytic heights.
    const fc = try commentsFor(a, &staged, "src/main.rs");
    defer a.free(fc);
    try testing.expectEqual(bodyHeight(a, &ps.files[0], .unified) + comments.cardHeight("why dropped?") + comments.cardHeight("nit") + comments.draft_card_height,
        bodyHeightWith(a, &ps.files[0], fc, .{ .side = .new, .line = 12 }, .unified));
    // The state key moves with bodies and the draft, not with unrelated fields.
    const k0 = commentStateKey(&staged, null);
    var edited_staged = staged;
    edited_staged[1].body = "nit!";
    try testing.expect(k0 != commentStateKey(&edited_staged, null));
    edited_staged[1].line = 99;
    try testing.expectEqual(commentStateKey(&edited_staged, null), commentStateKey(&edited_staged, null));
    try testing.expect(k0 != commentStateKey(&staged, .{ .path = "a", .anchor = .{ .side = .old, .line = 1 } }));
    try testing.expectEqual(@as(f32, 3 + 36 + (36 - 16) / 2), commentAdderLeft(.new, 36));
    try testing.expectEqual(@as(f32, 3 + (36 - 16) / 2), splitAdderLeft(36));
}
