//! Syntax colors for the file editor: zeron `files/editor_adapter.rs`
//! (`ZeronInputHighlighter`) on top of `zeron_syntax`.
//!
//! The highlighted document is line-relative, so an edit only invalidates
//! the lines it touched: `applyLineEdit` splices a current-line → document-
//! line map (untouched lines keep their spans, edited ones paint plain) and
//! the owner re-highlights the whole document on a worker after a short
//! debounce (`HighlightJob`), discarding results for stale revisions. This
//! is the Rust adapter's "shift spans, then reinstall" strategy without
//! ever painting misaligned colors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const syntax = @import("zeron_syntax");

pub const HighlightSpan = syntax.HighlightSpan;
pub const HighlightKind = syntax.HighlightKind;

/// Debounce between the last edit and a background re-highlight.
pub const rehighlight_delay_ms: u64 = 120;
/// Documents above this are not highlighted (the syntax crate's default limit).
pub const max_source_bytes: usize = syntax.default_max_source_bytes;

const none: u32 = std.math.maxInt(u32);
/// `line_map` values with this bit index `overrides` instead of the document.
const override_bit: u32 = 1 << 31;

pub const Highlights = struct {
    gpa: Allocator,
    doc: ?syntax.HighlightedDocument = null,
    /// Current line → line in `doc` (or `none` when edited since).
    line_map: std.ArrayList(u32) = .empty,
    /// Spans of lines edited in place since the last install (shifted copies).
    overrides: std.ArrayList(std.ArrayList(HighlightSpan)) = .empty,
    /// Bumped on every install / edit; jobs carry it to drop stale results.
    generation: u64 = 0,

    pub fn init(gpa: Allocator) Highlights {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Highlights) void {
        if (self.doc) |*d| d.deinit(self.gpa);
        self.line_map.deinit(self.gpa);
        self.clearOverrides();
        self.overrides.deinit(self.gpa);
    }

    fn clearOverrides(self: *Highlights) void {
        for (self.overrides.items) |*o| o.deinit(self.gpa);
        self.overrides.clearRetainingCapacity();
    }

    pub fn clear(self: *Highlights) void {
        if (self.doc) |*d| d.deinit(self.gpa);
        self.doc = null;
        self.line_map.clearRetainingCapacity();
        self.clearOverrides();
        self.generation +%= 1;
    }

    /// A byte edit inside one line: spans before it stay, spans after it
    /// shift, a span the insertion extends grows; overlapped spans drop.
    pub fn applyInlineEdit(self: *Highlights, line: usize, col: usize, old_len: usize, new_len: usize) void {
        self.generation +%= 1;
        if (self.doc == null or line >= self.line_map.items.len) return;
        const current = self.spans(line);
        var next: std.ArrayList(HighlightSpan) = .empty;
        const delta: isize = @as(isize, @intCast(new_len)) - @as(isize, @intCast(old_len));
        for (current) |sp| {
            if (sp.end <= col and !(old_len == 0 and sp.end == col and sp.start < col)) {
                next.append(self.gpa, sp) catch {};
            } else if (sp.start >= col + old_len and !(old_len == 0 and sp.start == col)) {
                next.append(self.gpa, .{ .start = shift(sp.start, delta), .end = shift(sp.end, delta), .kind = sp.kind }) catch {};
            } else if (old_len == 0 and col > sp.start and col <= sp.end) {
                next.append(self.gpa, .{ .start = sp.start, .end = shift(sp.end, delta), .kind = sp.kind }) catch {};
            } else if (old_len == 0 and col == sp.start) {
                next.append(self.gpa, .{ .start = shift(sp.start, delta), .end = shift(sp.end, delta), .kind = sp.kind }) catch {};
            }
        }
        const m = self.line_map.items[line];
        if (m != none and m & override_bit != 0) {
            var slot = &self.overrides.items[m & ~override_bit];
            slot.deinit(self.gpa);
            slot.* = next;
        } else {
            self.overrides.append(self.gpa, next) catch return;
            self.line_map.items[line] = override_bit | @as(u32, @intCast(self.overrides.items.len - 1));
        }
    }

    fn shift(v: usize, d: isize) usize {
        return @intCast(@max(@as(isize, @intCast(v)) + d, 0));
    }

    /// Install a fresh document for the current text (`line_count` lines).
    pub fn install(self: *Highlights, doc: syntax.HighlightedDocument, line_count: usize) void {
        if (self.doc) |*d| d.deinit(self.gpa);
        self.clearOverrides();
        self.doc = doc;
        self.line_map.resize(self.gpa, line_count) catch @panic("OOM");
        const n = doc.lineCount();
        for (self.line_map.items, 0..) |*m, i| m.* = if (i < n) @intCast(i) else none;
    }

    pub fn applyLineEdit(self: *Highlights, line: usize, removed: usize, added: usize) void {
        self.generation +%= 1;
        if (self.doc == null) return;
        const at = @min(line, self.line_map.items.len);
        const rm = @min(removed, self.line_map.items.len - at);
        if (added <= 64) {
            var fresh: [64]u32 = @splat(none);
            self.line_map.replaceRange(self.gpa, at, rm, fresh[0..added]) catch @panic("OOM");
        } else {
            const buf = self.gpa.alloc(u32, added) catch @panic("OOM");
            defer self.gpa.free(buf);
            @memset(buf, none);
            self.line_map.replaceRange(self.gpa, at, rm, buf) catch @panic("OOM");
        }
    }

    /// Spans for current line `line` (byte offsets relative to the line).
    pub fn spans(self: *const Highlights, line: usize) []const HighlightSpan {
        const d = self.doc orelse return &.{};
        if (line >= self.line_map.items.len) return &.{};
        const m = self.line_map.items[line];
        if (m == none) return &.{};
        if (m & override_bit != 0) return self.overrides.items[m & ~override_bit].items;
        if (m >= d.lineCount()) return &.{};
        return d.line(m);
    }

    pub fn hasDocument(self: *const Highlights) bool {
        return self.doc != null;
    }
};

pub const HighlightOutcome = struct {
    doc: ?syntax.HighlightedDocument,
    generation: u64,
};

/// Background highlight of a text snapshot (owns `source` and `path`).
pub const HighlightJob = struct {
    gpa: Allocator,
    source: []u8,
    path: []u8,
    generation: u64,

    pub fn run(self: *HighlightJob) HighlightOutcome {
        const doc = syntax.highlightWithLimits(self.gpa, .{ .source = self.source, .path = self.path }, .{ .max_source_bytes = max_source_bytes }, null) catch null;
        return .{ .doc = doc, .generation = self.generation };
    }

    pub fn discard(self: *HighlightJob, r: HighlightOutcome) void {
        if (r.doc) |d| {
            var dd = d;
            dd.deinit(self.gpa);
        }
    }

    pub fn deinit(self: *HighlightJob) void {
        self.gpa.free(self.source);
        self.gpa.free(self.path);
    }
};

/// Whether `path` names a language the highlighter knows.
pub fn supported(path: []const u8, first_line: ?[]const u8) bool {
    const lang = syntax.detectLanguage(path, null, first_line) orelse return false;
    return syntax.supportsLanguage(lang);
}

test "edits keep untouched lines' spans" {
    const gpa = std.testing.allocator;
    var h = Highlights.init(gpa);
    defer h.deinit();
    const src = "fn a() {}\nlet x = 1;\nfn b() {}";
    const doc = try syntax.highlight(gpa, .{ .source = src, .path = "x.rs" });
    h.install(doc, 3);
    const before_last = h.spans(2).len;
    try std.testing.expect(before_last > 0);
    h.applyLineEdit(1, 1, 2); // line 1 split in two
    try std.testing.expectEqual(@as(usize, 0), h.spans(1).len);
    try std.testing.expectEqual(@as(usize, 0), h.spans(2).len);
    try std.testing.expectEqual(before_last, h.spans(3).len);
    try std.testing.expect(h.spans(0).len > 0);
    // Typing inside line 0 shifts its spans instead of dropping them.
    const first = h.spans(0)[h.spans(0).len - 1];
    h.applyInlineEdit(0, 0, 0, 3);
    try std.testing.expectEqual(first.end + 3, h.spans(0)[h.spans(0).len - 1].end);
}
