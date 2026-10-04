//! Per-file diff syntax highlighting — port of zeron `changes.rs`
//! `DiffHighlights`, `excerpt_side` / `excerpt_highlights` (highlight each
//! hunk's visible old/new lines as a contiguous excerpt — immediate, no I/O)
//! and `full_highlights` (whole old/new documents from
//! `GetCheckoutFileDiffText`, used once they verifiably match the patch).
//!
//! Spans are paint-only run colors; layout never changes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diff = @import("zeron_diff");
const syntax = @import("zeron_syntax");

const FileDiff = diff.FileDiff;
const DiffLine = diff.DiffLine;
const Span = syntax.HighlightSpan;

pub const max_excerpt_source_lines: usize = 200_000;

pub const Side = struct {
    /// `lines[n - 1]` = spans of source line `n` (empty when unknown).
    lines: [][]const Span,
    docs: std.ArrayList(syntax.HighlightedDocument) = .empty,

    fn deinit(self: *Side, gpa: Allocator) void {
        for (self.docs.items) |*d| d.deinit(gpa);
        self.docs.deinit(gpa);
        gpa.free(self.lines);
    }

    fn get(self: *const Side, n: u32) []const Span {
        if (n == 0 or n > self.lines.len) return &.{};
        return self.lines[n - 1];
    }
};

pub const FileHighlights = struct {
    old: ?Side = null,
    new: ?Side = null,

    pub fn deinit(self: *FileHighlights, gpa: Allocator) void {
        if (self.old) |*s| s.deinit(gpa);
        if (self.new) |*s| s.deinit(gpa);
    }
};

/// `DiffHighlights::spans`: deletions read the old side, additions the new
/// side, context the new side when known (else old).
pub fn spansFor(h: ?*const FileHighlights, line: *const DiffLine) []const Span {
    const hh = h orelse return &.{};
    switch (line.kind) {
        .del => if (hh.old) |*s| if (line.old_no) |n| return s.get(n),
        .add => if (hh.new) |*s| if (line.new_no) |n| return s.get(n),
        .context => {
            if (hh.new) |*s| if (line.new_no) |n| return s.get(n);
            if (hh.old) |*s| if (line.old_no) |n| return s.get(n);
        },
        .meta => {},
    }
    return &.{};
}

pub fn supported(path: []const u8) bool {
    const lang = syntax.languageForPath(path) orelse return false;
    return syntax.supportsLanguage(lang);
}

const Which = enum { old, new };

fn numberOf(line: *const DiffLine, which: Which) ?u32 {
    return if (which == .old) line.old_no else line.new_no;
}

fn excerptSide(gpa: Allocator, file: *const FileDiff, which: Which, path: []const u8) !?Side {
    var max_line: u32 = 0;
    for (file.hunks) |h| for (h.lines) |l| {
        if (numberOf(&l, which)) |n| max_line = @max(max_line, n);
    };
    if (max_line > max_excerpt_source_lines) return null;
    var side: Side = .{ .lines = try gpa.alloc([]const Span, max_line) };
    errdefer side.deinit(gpa);
    @memset(side.lines, &.{});
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    var nums: std.ArrayList(u32) = .empty;
    defer nums.deinit(gpa);
    for (file.hunks) |h| {
        src.clearRetainingCapacity();
        nums.clearRetainingCapacity();
        for (h.lines) |*l| {
            if (l.kind == .meta) continue;
            const n = numberOf(l, which) orelse continue;
            if (nums.items.len > 0) try src.append(gpa, '\n');
            try src.appendSlice(gpa, l.text);
            try nums.append(gpa, n);
        }
        if (nums.items.len == 0) continue;
        var doc = syntax.highlight(gpa, .{ .source = src.items, .path = path }) catch return null;
        try side.docs.append(gpa, doc);
        doc = side.docs.items[side.docs.items.len - 1];
        for (nums.items, 0..) |n, i| {
            if (i < doc.lineCount()) side.lines[n - 1] = doc.line(i);
        }
    }
    return side;
}

/// Excerpt highlights for a file (null when the language is unsupported).
pub fn excerpt(gpa: Allocator, file: *const FileDiff) ?FileHighlights {
    if (!supported(file.path)) return null;
    var out: FileHighlights = .{};
    if (file.status != .added) {
        out.old = (excerptSide(gpa, file, .old, file.old_path orelse file.path) catch null) orelse {
            out.deinit(gpa);
            return null;
        };
    }
    if (file.status != .deleted) {
        out.new = (excerptSide(gpa, file, .new, file.path) catch null) orelse {
            out.deinit(gpa);
            return null;
        };
    }
    return out;
}

fn lineAt(lines: []const []const u8, n: ?u32) ?[]const u8 {
    const k = n orelse return null;
    if (k == 0 or k > lines.len) return null;
    return lines[k - 1];
}

fn splitLines(gpa: Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try out.append(gpa, std.mem.trimEnd(u8, l, "\r"));
    if (out.items.len > 0 and s.len > 0 and s[s.len - 1] == '\n') _ = out.pop();
    return out.toOwnedSlice(gpa);
}

/// `sources_match_patch`: every patch line equals the source line it cites.
pub fn sourcesMatchPatch(gpa: Allocator, file: *const FileDiff, old_text: ?[]const u8, new_text: ?[]const u8) bool {
    const old = if (old_text) |t| splitLines(gpa, t) catch return false else &[_][]const u8{};
    defer if (old_text != null) gpa.free(old);
    const new = if (new_text) |t| splitLines(gpa, t) catch return false else &[_][]const u8{};
    defer if (new_text != null) gpa.free(new);
    for (file.hunks) |h| for (h.lines) |*l| {
        const actual = switch (l.kind) {
            .del => lineAt(old, l.old_no),
            .add => lineAt(new, l.new_no),
            .context => lineAt(new, l.new_no) orelse lineAt(old, l.old_no),
            .meta => continue,
        };
        if (actual == null or !std.mem.eql(u8, actual.?, l.text)) return false;
    };
    return true;
}

fn fullSide(gpa: Allocator, source: []const u8, path: []const u8) ?Side {
    const doc = syntax.highlight(gpa, .{ .source = source, .path = path }) catch return null;
    var side: Side = .{ .lines = gpa.alloc([]const Span, doc.lineCount()) catch {
        var d = doc;
        d.deinit(gpa);
        return null;
    } };
    side.docs.append(gpa, doc) catch {
        var d = doc;
        d.deinit(gpa);
        gpa.free(side.lines);
        return null;
    };
    const d = &side.docs.items[0];
    for (side.lines, 0..) |*l, i| l.* = d.line(i);
    return side;
}

/// `full_highlights` from a `GetCheckoutFileDiffText` reply.
pub fn full(gpa: Allocator, file: *const FileDiff, old_text: ?[]const u8, new_text: ?[]const u8) ?FileHighlights {
    if (!sourcesMatchPatch(gpa, file, old_text, new_text)) return null;
    var out: FileHighlights = .{};
    if (old_text) |t| out.old = fullSide(gpa, t, file.old_path orelse file.path) orelse {
        out.deinit(gpa);
        return null;
    };
    if (new_text) |t| out.new = fullSide(gpa, t, file.path) orelse {
        out.deinit(gpa);
        return null;
    };
    if (out.old == null and out.new == null) return null;
    return out;
}

test "excerpt highlights map spans to source line numbers" {
    const gpa = std.testing.allocator;
    var ps = try diff.parsePatch(gpa,
        \\diff --git a/src/a.rs b/src/a.rs
        \\--- a/src/a.rs
        \\+++ b/src/a.rs
        \\@@ -10,2 +10,2 @@
        \\ fn main() {
        \\-    let x = 1;
        \\+    let x = 2;
        \\
    );
    defer ps.deinit();
    var h = excerpt(gpa, &ps.files[0]) orelse return error.SkipZigTest;
    defer h.deinit(gpa);
    const del = &ps.files[0].hunks[0].lines[1];
    try std.testing.expect(spansFor(&h, del).len > 0);
    try std.testing.expect(sourcesMatchPatch(gpa, &ps.files[0], "\n\n\n\n\n\n\n\n\nfn main() {\n    let x = 1;\n", "\n\n\n\n\n\n\n\n\nfn main() {\n    let x = 2;\n"));
    try std.testing.expect(!sourcesMatchPatch(gpa, &ps.files[0], "nope", null));
}
