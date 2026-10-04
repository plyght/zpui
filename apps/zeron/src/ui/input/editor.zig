//! `EditorState`: the layout-independent half of zeron's `ComposerInput`
//! (`crates/ui/src/composer.rs` ~1826–4440): the UTF-8 buffer, selection
//! (with direction and soft-wrap caret affinity), IME marked range, undo /
//! redo with 700 ms typing-run coalescing (200 steps), grapheme / word / line
//! motions and the `EntityInputHandler` range logic (UTF-16 in, UTF-8 inside).
//!
//! Everything here is pure (time is passed in as nanoseconds) so the editing
//! semantics are unit-tested without a window; `text_input.zig` wraps it in a
//! zpui view with layout, painting and input plumbing.
//!
//! The buffer is a contiguous `ArrayList(u8)`: composer drafts and text fields
//! are small (a few KB), every edit already re-shapes the touched paragraphs,
//! and the shaper wants contiguous text — a rope or gap buffer would only add
//! copies. Snapshots for undo store whole contents, exactly like Rust's
//! `EditSnapshot`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const seg = @import("segment.zig");

/// Byte range in the buffer (`start <= end`).
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn collapsed(at: usize) Range {
        return .{ .start = at, .end = at };
    }
    pub fn isEmpty(r: Range) bool {
        return r.start == r.end;
    }
    pub fn len(r: Range) usize {
        return r.end - r.start;
    }
    pub fn eql(a: Range, b: Range) bool {
        return a.start == b.start and a.end == b.end;
    }
    pub fn contains(r: Range, i: usize) bool {
        return r.start <= i and i < r.end;
    }
};

/// A soft-wrap boundary is both the previous row's end and the next row's
/// start; affinity records which side the caret is drawn on.
pub const CaretAffinity = enum { upstream, downstream };

/// How long a run of single-character edits keeps merging into one undo step.
pub const undo_coalesce_ns: u64 = 700 * std.time.ns_per_ms;
/// Cap on retained undo steps.
pub const undo_limit: usize = 200;

pub const EditKind = enum { insert, delete };

pub const Snapshot = struct {
    content: []u8,
    selected: Range,
    reversed: bool,
    affinity: CaretAffinity,

    fn deinit(self: Snapshot, gpa: Allocator) void {
        gpa.free(self.content);
    }
};

const LastEdit = struct { kind: EditKind, at: usize, when: u64 };

pub const EditorState = struct {
    gpa: Allocator,
    content: std.ArrayList(u8) = .empty,
    selected: Range = .collapsed(0),
    reversed: bool = false,
    affinity: CaretAffinity = .downstream,
    marked: ?Range = null,
    /// Retained through vertical moves across short rows; other moves reset it.
    preferred_column: ?f32 = null,
    single_line: bool = false,
    read_only: bool = false,
    /// Bumped on every content change.
    revision: u64 = 0,
    undo_stack: std.ArrayList(Snapshot) = .empty,
    redo_stack: std.ArrayList(Snapshot) = .empty,
    last_edit: ?LastEdit = null,

    pub fn init(gpa: Allocator) EditorState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *EditorState) void {
        self.content.deinit(self.gpa);
        clearStack(self.gpa, &self.undo_stack);
        self.undo_stack.deinit(self.gpa);
        clearStack(self.gpa, &self.redo_stack);
        self.redo_stack.deinit(self.gpa);
    }

    fn clearStack(gpa: Allocator, stack: *std.ArrayList(Snapshot)) void {
        for (stack.items) |s| s.deinit(gpa);
        stack.clearRetainingCapacity();
    }

    pub fn text(self: *const EditorState) []const u8 {
        return self.content.items;
    }

    pub fn isEmpty(self: *const EditorState) bool {
        return self.content.items.len == 0;
    }

    pub fn hasNewline(self: *const EditorState) bool {
        return std.mem.indexOfScalar(u8, self.content.items, '\n') != null;
    }

    pub fn canUndo(self: *const EditorState) bool {
        return self.undo_stack.items.len > 0;
    }

    pub fn canRedo(self: *const EditorState) bool {
        return self.redo_stack.items.len > 0;
    }

    /// The caret: the moving end of the selection.
    pub fn cursor(self: *const EditorState) usize {
        return if (self.reversed) self.selected.start else self.selected.end;
    }

    /// The selected text.
    pub fn selectedText(self: *const EditorState) []const u8 {
        return self.content.items[self.selected.start..self.selected.end];
    }

    // ---- whole-document replacement ----------------------------------------------------

    /// Programmatic replacement (draft load, clear-on-submit): a new document,
    /// not an edit — history is cleared and the caret goes to the end.
    pub fn setText(self: *EditorState, new_text: []const u8) Allocator.Error!void {
        self.content.clearRetainingCapacity();
        try self.content.appendSlice(self.gpa, new_text);
        if (self.single_line) flattenNewlines(self.content.items);
        self.revision +%= 1;
        const last = self.content.items.len;
        self.selected = .collapsed(last);
        self.reversed = false;
        self.affinity = .downstream;
        self.preferred_column = null;
        self.marked = null;
        clearStack(self.gpa, &self.undo_stack);
        clearStack(self.gpa, &self.redo_stack);
        self.last_edit = null;
    }

    fn flattenNewlines(buf: []u8) void {
        for (buf) |*c| if (c.* == '\r' or c.* == '\n') {
            c.* = ' ';
        };
    }

    // ---- caret / selection -------------------------------------------------------------

    /// Collapse the selection at `offset` (`move_to`).
    pub fn moveTo(self: *EditorState, offset: usize) void {
        self.last_edit = null;
        const off = seg.floorCharBoundary(self.content.items, offset);
        self.selected = .collapsed(off);
        self.reversed = false;
        self.affinity = .downstream;
        self.preferred_column = null;
    }

    /// Move the caret end of the selection to `offset` (`select_to`).
    pub fn selectTo(self: *EditorState, offset: usize) void {
        self.last_edit = null;
        self.extendSelection(offset);
    }

    /// Like `selectTo` without breaking a typing run (deletions extend
    /// internally).
    pub fn extendSelection(self: *EditorState, offset: usize) void {
        self.affinity = .downstream;
        self.preferred_column = null;
        const off = seg.floorCharBoundary(self.content.items, offset);
        if (self.reversed) self.selected.start = off else self.selected.end = off;
        if (self.selected.end < self.selected.start) {
            self.reversed = !self.reversed;
            const r = self.selected;
            self.selected = .{ .start = r.end, .end = r.start };
        }
    }

    pub fn selectAll(self: *EditorState) void {
        self.moveTo(0);
        self.selectTo(self.content.items.len);
    }

    /// Select `range` with the caret at its end.
    pub fn selectRange(self: *EditorState, range: Range) void {
        self.moveTo(range.start);
        self.selectTo(range.end);
    }

    // ---- boundaries --------------------------------------------------------------------

    pub fn prevBoundary(self: *const EditorState, offset: usize) usize {
        return seg.prevGrapheme(self.content.items, offset);
    }

    pub fn nextBoundary(self: *const EditorState, offset: usize) usize {
        return seg.nextGrapheme(self.content.items, offset);
    }

    pub fn prevWordBoundary(self: *const EditorState, offset: usize) usize {
        return seg.prevWordBoundary(self.content.items, offset);
    }

    pub fn nextWordBoundary(self: *const EditorState, offset: usize) usize {
        return seg.nextWordBoundary(self.content.items, offset);
    }

    /// Byte range of the logical line containing `offset` (without its '\n').
    pub fn lineRangeAt(self: *const EditorState, offset: usize) Range {
        const t = self.content.items;
        const off = seg.floorCharBoundary(t, offset);
        const start = if (std.mem.lastIndexOfScalar(u8, t[0..off], '\n')) |i| i + 1 else 0;
        const stop = if (std.mem.indexOfScalarPos(u8, t, off, '\n')) |i| i else t.len;
        return .{ .start = start, .end = stop };
    }

    /// Navigation stops before the whole line ending (CR of a CRLF included).
    pub fn lineContentEndAt(self: *const EditorState, offset: usize) usize {
        const stop = self.lineRangeAt(offset).end;
        const t = self.content.items;
        if (stop < t.len and t[stop] == '\n' and stop > 0 and t[stop - 1] == '\r') return stop - 1;
        return stop;
    }

    /// The selection unit for a double (word) or triple (line) click at `index`.
    pub fn selectionUnit(self: *const EditorState, line: bool, index: usize) Range {
        if (line) {
            var r = self.lineRangeAt(index);
            if (r.end < self.content.items.len) r.end += 1;
            return r;
        }
        const w = seg.wordRange(self.content.items, index);
        return .{ .start = w.start, .end = w.end };
    }

    // ---- undo history ------------------------------------------------------------------

    fn snapshot(self: *const EditorState) Allocator.Error!Snapshot {
        return .{
            .content = try self.gpa.dupe(u8, self.content.items),
            .selected = self.selected,
            .reversed = self.reversed,
            .affinity = self.affinity,
        };
    }

    fn pushUndo(self: *EditorState) Allocator.Error!void {
        try self.undo_stack.append(self.gpa, try self.snapshot());
        if (self.undo_stack.items.len > undo_limit) self.undo_stack.orderedRemove(0).deinit(self.gpa);
    }

    /// Called with the range about to be replaced, BEFORE the content
    /// changes, so the pushed snapshot is the pre-edit state (`record_edit`).
    fn recordEdit(self: *EditorState, range: Range, new_text: []const u8, now: u64) Allocator.Error!void {
        const kind: EditKind = if (new_text.len == 0) .delete else .insert;
        // A run merges only while it stays single-character, contiguous with
        // the previous edit, of the same kind, and inside the idle window.
        const coalescible = switch (kind) {
            .insert => range.isEmpty() and codepointCount(new_text) == 1,
            .delete => range.end <= self.content.items.len and seg.graphemeCount(self.content.items[range.start..range.end]) == 1,
        };
        const mergeable = coalescible and if (self.last_edit) |last| switch (kind) {
            .insert => last.kind == .insert and range.isEmpty() and range.start == last.at and
                codepointCount(new_text) == 1 and !(new_text[0] == '\n' or new_text[0] == ' ' or new_text[0] == '\t') and
                now -| last.when < undo_coalesce_ns,
            .delete => last.kind == .delete and range.end == last.at and now -| last.when < undo_coalesce_ns,
        } else false;
        if (!mergeable) try self.pushUndo();
        clearStack(self.gpa, &self.redo_stack);
        const tail = switch (kind) {
            .insert => range.start + new_text.len,
            .delete => range.start,
        };
        self.last_edit = if (coalescible) .{ .kind = kind, .at = tail, .when = now } else null;
    }

    fn restore(self: *EditorState, s: Snapshot) Allocator.Error!void {
        self.content.clearRetainingCapacity();
        try self.content.appendSlice(self.gpa, s.content);
        self.selected = s.selected;
        self.reversed = s.reversed;
        self.affinity = s.affinity;
        self.preferred_column = null;
        self.marked = null;
        self.last_edit = null;
        self.revision +%= 1;
    }

    /// Returns whether anything changed.
    pub fn undo(self: *EditorState) Allocator.Error!bool {
        if (self.read_only) return false;
        const prev = self.undo_stack.pop() orelse return false;
        defer prev.deinit(self.gpa);
        try self.redo_stack.append(self.gpa, try self.snapshot());
        try self.restore(prev);
        return true;
    }

    pub fn redo(self: *EditorState) Allocator.Error!bool {
        if (self.read_only) return false;
        const next = self.redo_stack.pop() orelse return false;
        defer next.deinit(self.gpa);
        try self.undo_stack.append(self.gpa, try self.snapshot());
        try self.restore(next);
        return true;
    }

    /// Forget the typing run so the next edit starts a new undo step
    /// (clipboard operations are always their own steps).
    pub fn breakUndoRun(self: *EditorState) void {
        self.last_edit = null;
    }

    // ---- edits -------------------------------------------------------------------------

    fn clampRange(self: *const EditorState, r: Range) Range {
        const t = self.content.items;
        const a = seg.floorCharBoundary(t, @min(r.start, r.end));
        const b = seg.floorCharBoundary(t, @max(r.start, r.end));
        return .{ .start = a, .end = b };
    }

    fn splice(self: *EditorState, range: Range, new_text: []const u8) Allocator.Error!void {
        try self.content.replaceRange(self.gpa, range.start, range.len(), new_text);
        if (self.single_line) flattenNewlines(self.content.items[range.start..][0..new_text.len]);
        self.revision +%= 1;
    }

    /// `replace_text_in_range` with a UTF-8 range: `range` (or the marked
    /// range, or the selection) becomes `new_text`; the caret lands after it
    /// and any composition ends. Returns false when read-only.
    pub fn replace(self: *EditorState, range_opt: ?Range, new_text: []const u8, now: u64) Allocator.Error!bool {
        if (self.read_only) return false;
        const range = self.clampRange(range_opt orelse self.marked orelse self.selected);
        // An IME commit is the tail of a composition whose pre-composition
        // snapshot was already taken by `replaceAndMark`.
        if (self.marked == null) try self.recordEdit(range, new_text, now);
        try self.splice(range, new_text);
        const c = range.start + new_text.len;
        self.selected = .collapsed(c);
        self.reversed = false;
        self.affinity = .downstream;
        self.preferred_column = null;
        self.marked = null;
        return true;
    }

    /// `replace_and_mark_text_in_range` with UTF-8 ranges: insert IME
    /// composition text and mark it. `new_selected` is relative to
    /// `new_text` (UTF-8). The first composition keystroke snapshots the
    /// pre-composition text so one undo drops the whole composition.
    pub fn replaceAndMark(self: *EditorState, range_opt: ?Range, new_text: []const u8, new_selected: ?Range) Allocator.Error!bool {
        if (self.read_only) return false;
        const range = self.clampRange(range_opt orelse self.marked orelse self.selected);
        if (self.marked == null) {
            try self.pushUndo();
            clearStack(self.gpa, &self.redo_stack);
            self.last_edit = null;
        }
        try self.splice(range, new_text);
        self.marked = if (new_text.len == 0) null else .{ .start = range.start, .end = range.start + new_text.len };
        if (new_selected) |ns| {
            const a = @min(ns.start, new_text.len);
            const b = @min(ns.end, new_text.len);
            self.selected = .{ .start = range.start + @min(a, b), .end = range.start + @max(a, b) };
        } else self.selected = .collapsed(range.start + new_text.len);
        self.reversed = false;
        self.affinity = .downstream;
        self.preferred_column = null;
        return true;
    }

    /// Commit the composition as typed (`unmark_text`). Returns whether a
    /// composition was active.
    pub fn unmark(self: *EditorState) bool {
        if (self.marked == null) return false;
        self.marked = null;
        self.last_edit = null;
        return true;
    }

    /// Backspace: the selection, else the grapheme before the caret.
    pub fn backspace(self: *EditorState, now: u64) Allocator.Error!bool {
        if (self.selected.isEmpty()) {
            const prev = self.prevBoundary(self.cursor());
            if (prev == self.cursor()) return false;
            self.extendSelection(prev);
        }
        return self.replace(null, "", now);
    }

    /// Forward delete: the selection, else the grapheme after the caret.
    pub fn delete(self: *EditorState, now: u64) Allocator.Error!bool {
        if (self.selected.isEmpty()) {
            const next = self.nextBoundary(self.cursor());
            if (next == self.cursor()) return false;
            self.extendSelection(next);
        }
        return self.replace(null, "", now);
    }

    /// Opt/Cmd + Delete family: with a live selection these delete the
    /// selection only (`delete_to`).
    pub fn deleteTo(self: *EditorState, offset: usize, now: u64) Allocator.Error!bool {
        if (self.selected.isEmpty()) {
            if (self.cursor() == offset) return false;
            self.extendSelection(offset);
        }
        return self.replace(null, "", now);
    }

    pub fn deleteWordLeft(self: *EditorState, now: u64) Allocator.Error!bool {
        return self.deleteTo(self.prevWordBoundary(self.cursor()), now);
    }
    pub fn deleteWordRight(self: *EditorState, now: u64) Allocator.Error!bool {
        return self.deleteTo(self.nextWordBoundary(self.cursor()), now);
    }
    pub fn deleteToLineStart(self: *EditorState, now: u64) Allocator.Error!bool {
        return self.deleteTo(self.lineRangeAt(self.cursor()).start, now);
    }
    pub fn deleteToLineEnd(self: *EditorState, now: u64) Allocator.Error!bool {
        return self.deleteTo(self.lineContentEndAt(self.cursor()), now);
    }

    /// The newline to insert at the caret: CRLF on lines that already end in
    /// one (`newline`).
    pub fn newlineText(self: *const EditorState) []const u8 {
        const c = self.cursor();
        return if (self.lineContentEndAt(c) < self.lineRangeAt(c).end) "\r\n" else "\n";
    }

    /// Insert a pasted / programmatic string as its own undo step.
    pub fn insertAsStep(self: *EditorState, s: []const u8, now: u64) Allocator.Error!bool {
        self.last_edit = null;
        const changed = try self.replace(null, s, now);
        self.last_edit = null;
        return changed;
    }

    // ---- motions (left/right/home/end/...) --------------------------------------------

    pub fn left(self: *EditorState) void {
        if (self.selected.isEmpty()) self.moveTo(self.prevBoundary(self.cursor())) else self.moveTo(self.selected.start);
    }
    pub fn right(self: *EditorState) void {
        if (self.selected.isEmpty()) self.moveTo(self.nextBoundary(self.selected.end)) else self.moveTo(self.selected.end);
    }
    pub fn selectLeft(self: *EditorState) void {
        self.selectTo(self.prevBoundary(self.cursor()));
    }
    pub fn selectRight(self: *EditorState) void {
        self.selectTo(self.nextBoundary(self.cursor()));
    }
    pub fn home(self: *EditorState) void {
        self.moveTo(self.lineRangeAt(self.cursor()).start);
    }
    pub fn end(self: *EditorState) void {
        self.moveTo(self.lineContentEndAt(self.cursor()));
    }
    pub fn selectHome(self: *EditorState) void {
        self.selectTo(self.lineRangeAt(self.cursor()).start);
    }
    pub fn selectEnd(self: *EditorState) void {
        self.selectTo(self.lineContentEndAt(self.cursor()));
    }
    pub fn docStart(self: *EditorState) void {
        self.moveTo(0);
    }
    pub fn docEnd(self: *EditorState) void {
        self.moveTo(self.content.items.len);
    }
    pub fn selectDocStart(self: *EditorState) void {
        self.selectTo(0);
    }
    pub fn selectDocEnd(self: *EditorState) void {
        self.selectTo(self.content.items.len);
    }
    pub fn wordLeft(self: *EditorState) void {
        self.moveTo(self.prevWordBoundary(self.cursor()));
    }
    pub fn wordRight(self: *EditorState) void {
        self.moveTo(self.nextWordBoundary(self.cursor()));
    }
    pub fn selectWordLeft(self: *EditorState) void {
        self.selectTo(self.prevWordBoundary(self.cursor()));
    }
    pub fn selectWordRight(self: *EditorState) void {
        self.selectTo(self.nextWordBoundary(self.cursor()));
    }

    // ---- UTF-16 (IME) ------------------------------------------------------------------

    pub fn toUtf16(self: *const EditorState, offset: usize) usize {
        return seg.utf16FromUtf8(self.content.items, offset);
    }
    pub fn fromUtf16(self: *const EditorState, offset: usize) usize {
        return seg.utf8FromUtf16(self.content.items, offset);
    }
    pub fn rangeToUtf16(self: *const EditorState, r: Range) Range {
        return .{ .start = self.toUtf16(r.start), .end = self.toUtf16(r.end) };
    }
    pub fn rangeFromUtf16(self: *const EditorState, r: Range) Range {
        return .{ .start = self.fromUtf16(r.start), .end = self.fromUtf16(r.end) };
    }

    /// `replace_and_mark_text_in_range` with UTF-16 ranges, as the platform
    /// IME delivers them (`new_selected` relative to `new_text`).
    pub fn replaceAndMarkUtf16(self: *EditorState, range: ?Range, new_text: []const u8, new_selected: ?Range) Allocator.Error!bool {
        const r8 = if (range) |r| self.rangeFromUtf16(r) else null;
        const sel8: ?Range = if (new_selected) |s| .{ .start = seg.utf8FromUtf16(new_text, s.start), .end = seg.utf8FromUtf16(new_text, s.end) } else null;
        return self.replaceAndMark(r8, new_text, sel8);
    }

    pub fn replaceUtf16(self: *EditorState, range: ?Range, new_text: []const u8, now: u64) Allocator.Error!bool {
        const r8 = if (range) |r| self.rangeFromUtf16(r) else null;
        return self.replace(r8, new_text, now);
    }
};

fn codepointCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const ms = std.time.ns_per_ms;

fn editor() EditorState {
    return .init(testing.allocator);
}

fn typeText(e: *EditorState, s: []const u8, start_ns: u64, step_ns: u64) !u64 {
    var now = start_ns;
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        _ = try e.replace(null, s[i..][0..n], now);
        i += n;
        now += step_ns;
    }
    return now;
}

test "typing, selection replace and caret placement" {
    var e = editor();
    defer e.deinit();
    _ = try typeText(&e, "hello world", 0, ms);
    try testing.expectEqualStrings("hello world", e.text());
    try testing.expectEqual(@as(usize, 11), e.cursor());
    e.selectRange(.{ .start = 6, .end = 11 });
    _ = try e.replace(null, "zig", 20 * ms);
    try testing.expectEqualStrings("hello zig", e.text());
    try testing.expect(e.selected.eql(.collapsed(9)));
    // Reversed selection via selectTo behind the anchor.
    e.moveTo(5);
    e.selectTo(0);
    try testing.expect(e.reversed);
    try testing.expectEqual(@as(usize, 0), e.cursor());
    try testing.expectEqualStrings("hello", e.selectedText());
    e.selectTo(9); // crosses the anchor: flips back
    try testing.expect(!e.reversed);
    try testing.expectEqualStrings(" zig", e.selectedText());
}

test "undo coalesces typing runs and breaks on spaces, pauses and jumps" {
    var e = editor();
    defer e.deinit();
    var now = try typeText(&e, "hello", 0, 100 * ms); // one run
    now = try typeText(&e, " world", now, 100 * ms); // space starts a new step
    try testing.expectEqual(@as(usize, 2), e.undo_stack.items.len);
    try testing.expect(try e.undo());
    try testing.expectEqualStrings("hello", e.text());
    try testing.expect(try e.undo());
    try testing.expectEqualStrings("", e.text());
    try testing.expect(!try e.undo());
    try testing.expect(try e.redo());
    try testing.expect(try e.redo());
    try testing.expectEqualStrings("hello world", e.text());
    try testing.expect(!try e.redo());

    // A pause longer than 700ms splits a run.
    var p = editor();
    defer p.deinit();
    now = try typeText(&p, "ab", 0, 100 * ms);
    now = try typeText(&p, "cd", now + 800 * ms, 100 * ms);
    try testing.expectEqual(@as(usize, 2), p.undo_stack.items.len);
    _ = try p.undo();
    try testing.expectEqualStrings("ab", p.text());

    // A caret jump splits a run.
    var j = editor();
    defer j.deinit();
    now = try typeText(&j, "ab", 0, 10 * ms);
    j.moveTo(0);
    now = try typeText(&j, "x", now, 10 * ms);
    try testing.expectEqualStrings("xab", j.text());
    try testing.expectEqual(@as(usize, 2), j.undo_stack.items.len);

    // A fresh edit after undo clears the redo branch.
    _ = try j.undo();
    try testing.expect(j.canRedo());
    _ = try j.replace(null, "!", now + 10 * ms);
    try testing.expect(!j.canRedo());
}

test "backspace runs coalesce; delete by grapheme" {
    var e = editor();
    defer e.deinit();
    try e.setText("abc👍🏽d");
    var now: u64 = 0;
    _ = try e.backspace(now); // d
    now += 50 * ms;
    _ = try e.backspace(now); // 👍🏽 (one grapheme, two code points)
    try testing.expectEqualStrings("abc", e.text());
    now += 50 * ms;
    _ = try e.backspace(now);
    try testing.expectEqualStrings("ab", e.text());
    try testing.expectEqual(@as(usize, 1), e.undo_stack.items.len);
    _ = try e.undo();
    try testing.expectEqualStrings("abc👍🏽d", e.text());
    e.moveTo(3);
    _ = try e.delete(now);
    try testing.expectEqualStrings("abcd", e.text());
    e.moveTo(0);
    try testing.expect(!try e.backspace(now));
    e.moveTo(4);
    try testing.expect(!try e.delete(now));
}

test "undo limit drops the oldest steps" {
    var e = editor();
    defer e.deinit();
    var now: u64 = 0;
    for (0..undo_limit + 25) |_| {
        _ = try e.replace(null, "x", now);
        now += 2 * undo_coalesce_ns;
    }
    try testing.expectEqual(undo_limit, e.undo_stack.items.len);
}

test "grapheme-aware left/right over emoji, CJK and combining marks" {
    var e = editor();
    defer e.deinit();
    try e.setText("a中👨‍👩‍👧e\u{301}");
    e.moveTo(0);
    e.right();
    try testing.expectEqual(@as(usize, 1), e.cursor());
    e.right();
    try testing.expectEqual(@as(usize, 4), e.cursor());
    e.right();
    try testing.expectEqual(@as(usize, 4 + "👨‍👩‍👧".len), e.cursor());
    e.right();
    try testing.expectEqual(e.text().len, e.cursor());
    e.left();
    try testing.expectEqual(@as(usize, 4 + "👨‍👩‍👧".len), e.cursor());
    e.left();
    try testing.expectEqual(@as(usize, 4), e.cursor());
    // Left/Right with a selection collapse to its edges.
    e.selectRange(.{ .start = 1, .end = 4 });
    e.left();
    try testing.expectEqual(@as(usize, 1), e.cursor());
    e.selectRange(.{ .start = 1, .end = 4 });
    e.right();
    try testing.expectEqual(@as(usize, 4), e.cursor());
}

test "word and line motions, line deletes, CRLF endings" {
    var e = editor();
    defer e.deinit();
    try e.setText("one two\r\nthree four");
    e.moveTo(0);
    e.wordRight();
    try testing.expectEqual(@as(usize, 3), e.cursor());
    e.wordRight();
    try testing.expectEqual(@as(usize, 7), e.cursor());
    e.end();
    try testing.expectEqual(@as(usize, 7), e.cursor()); // stops before CR
    e.moveTo(12);
    e.home();
    try testing.expectEqual(@as(usize, 9), e.cursor());
    e.end();
    try testing.expectEqual(e.text().len, e.cursor());
    e.selectHome();
    try testing.expectEqualStrings("three four", e.selectedText());
    e.wordLeft();
    try testing.expectEqual(@as(usize, 4), e.cursor()); // from 9 back over "\r\n"? (start of "two")
    e.moveTo(3);
    try testing.expectEqualStrings("\r\n", e.newlineText());
    e.moveTo(12);
    try testing.expectEqualStrings("\n", e.newlineText());
    _ = try e.deleteToLineStart(0);
    try testing.expectEqualStrings("one two\r\nee four", e.text());
    _ = try e.deleteToLineEnd(0);
    try testing.expectEqualStrings("one two\r\n", e.text());
    e.moveTo(7);
    _ = try e.deleteWordLeft(0);
    try testing.expectEqualStrings("one \r\n", e.text());
    e.moveTo(0);
    _ = try e.deleteWordRight(0);
    try testing.expectEqualStrings(" \r\n", e.text());
    // Selection units.
    try e.setText("alpha beta\ngamma");
    const w = e.selectionUnit(false, 7);
    try testing.expectEqualStrings("beta", e.text()[w.start..w.end]);
    const l = e.selectionUnit(true, 2);
    try testing.expectEqualStrings("alpha beta\n", e.text()[l.start..l.end]);
    const last = e.selectionUnit(true, 13);
    try testing.expectEqualStrings("gamma", e.text()[last.start..last.end]);
}

test "IME composition with UTF-16 ranges commits as one undo step" {
    var e = editor();
    defer e.deinit();
    _ = try typeText(&e, "a😀", 0, ms); // the emoji is two UTF-16 units
    // Compose "にほん" → "日本" after the emoji.
    _ = try e.replaceAndMarkUtf16(null, "に", null);
    try testing.expect(e.marked.?.eql(.{ .start = 5, .end = 8 }));
    try testing.expectEqual(@as(usize, 3), e.toUtf16(e.marked.?.start));
    _ = try e.replaceAndMarkUtf16(null, "にほ", .{ .start = 2, .end = 2 });
    _ = try e.replaceAndMarkUtf16(null, "にほん", .{ .start = 3, .end = 3 });
    try testing.expectEqualStrings("a😀にほん", e.text());
    try testing.expectEqual(@as(usize, 6), e.toUtf16(e.cursor()));
    // Candidate selection may select inside the marked text.
    _ = try e.replaceAndMarkUtf16(null, "日本", .{ .start = 0, .end = 2 });
    try testing.expect(e.selected.eql(.{ .start = 5, .end = 11 }));
    // Commit through replaceTextInRange (range = the marked range, in UTF-16).
    _ = try e.replaceUtf16(e.rangeToUtf16(e.marked.?), "日本", 5 * ms);
    try testing.expectEqualStrings("a😀日本", e.text());
    try testing.expect(e.marked == null);
    try testing.expect(e.selected.eql(.collapsed(e.text().len)));
    // One undo drops the whole composition.
    _ = try e.undo();
    try testing.expectEqualStrings("a😀", e.text());
    // Unmark commits the composition as typed; empty composition clears it.
    _ = try e.replaceAndMark(null, "x", null);
    try testing.expect(e.unmark());
    try testing.expect(!e.unmark());
    _ = try e.replaceAndMark(null, "y", null);
    _ = try e.replaceAndMark(null, "", null);
    try testing.expect(e.marked == null);
    try testing.expectEqualStrings("a😀x", e.text());
}

test "single-line mode flattens newlines; read-only rejects edits" {
    var e = editor();
    defer e.deinit();
    e.single_line = true;
    try e.setText("a\nb");
    try testing.expectEqualStrings("a b", e.text());
    _ = try e.insertAsStep("c\r\nd", 0);
    try testing.expectEqualStrings("a bc  d", e.text());
    e.read_only = true;
    try testing.expect(!try e.replace(null, "z", 0));
    try testing.expect(!try e.undo());
}
