//! `EditorCore`: the layout-independent half of the file editor — a port of
//! the editing semantics of gpui-component's `InputBaseState<EditorMode>`
//! (`crates/base/src/input/base/state.rs`, `editor/indent.rs`,
//! `base/undo_manager.rs`, `editor/search.rs`) on top of the chunked
//! `Buffer`, reusing the composer's pure segmentation (`zeron_input`'s
//! `segment.zig`: graphemes, words, UTF-16) and undo timing.
//!
//! - one selection (anchor + head; gpui-component has no multi-cursor);
//! - undo/redo as transactions of edits (inverse replay), coalescing runs of
//!   typing / backspace / forward delete while they stay adjacent and within
//!   the composer's 700 ms window; IME composition is one step;
//! - `version` ids per transaction so a document knows when undo returns it
//!   to the saved state (`isDirty`);
//! - code-editor behaviors: auto-indent on Enter (`indent_of_next_line`),
//!   Tab/Shift-Tab inline and block (de)indent with 2-space soft tabs
//!   (gpui-component's `TabSize::default`), smart Home;
//! - find / replace (case-insensitive by default, optional whole word), a
//!   streaming chunk search that never materializes the document.
//!
//! Every mutation appends a `LineEdit` (which lines were replaced by how
//! many) so owners can update line-indexed caches (wrap rows, highlights).

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("zeron_input");
const seg = input.segment;
const buffer_mod = @import("buffer.zig");

pub const Buffer = buffer_mod.Buffer;
pub const Range = buffer_mod.Range;

/// Typing runs merge within this window (the composer's `undo_coalesce_ns`).
pub const undo_coalesce_ns: u64 = input.editor.undo_coalesce_ns;
/// gpui-component `MAX_UNDO_TRANSACTIONS`.
pub const undo_limit: usize = 1000;
/// gpui-component `TabSize::default()`: two spaces, soft tabs.
pub const default_tab_size: usize = 2;
/// Find results stop counting here (huge files with common needles).
pub const max_matches: usize = 100_000;

pub const Selection = struct {
    anchor: usize = 0,
    head: usize = 0,

    pub fn collapsed(at: usize) Selection {
        return .{ .anchor = at, .head = at };
    }
    pub fn start(s: Selection) usize {
        return @min(s.anchor, s.head);
    }
    pub fn end(s: Selection) usize {
        return @max(s.anchor, s.head);
    }
    pub fn isEmpty(s: Selection) bool {
        return s.anchor == s.head;
    }
    pub fn reversed(s: Selection) bool {
        return s.head < s.anchor;
    }
    pub fn range(s: Selection) Range {
        return .{ .start = s.start(), .end = s.end() };
    }
};

pub const Intent = enum { typing, backspace, delete_forward, atomic };

/// Lines `[line, line + removed)` were replaced by `added` lines. For a
/// single-line edit (`removed == added == 1`) `col`/`old_len`/`new_len`
/// describe the byte edit inside the line.
/// One buffer edit as line bookkeeping (`start`: its byte offset; `full`: a
/// whole-document reload, which detaches every tracked range).
pub const LineEdit = struct { line: usize, removed: usize, added: usize, col: usize = 0, old_len: usize = 0, new_len: usize = 0, start: usize = 0, full: bool = false };

const Edit = struct {
    start: usize,
    old: []u8,
    new: []u8,

    fn deinit(e: Edit, gpa: Allocator) void {
        gpa.free(e.old);
        gpa.free(e.new);
    }
};

const Transaction = struct {
    edits: std.ArrayList(Edit) = .empty,
    before: Selection,
    after: Selection,
    intent: Intent,
    time: u64,
    version: u64,

    fn deinit(t: *Transaction, gpa: Allocator) void {
        for (t.edits.items) |e| e.deinit(gpa);
        t.edits.deinit(gpa);
    }
};

pub const Search = struct {
    query: std.ArrayList(u8) = .empty,
    case_sensitive: bool = false,
    whole_word: bool = false,
    matches: std.ArrayList(Range) = .empty,
    /// Index of the active match.
    active: ?usize = null,
    capped: bool = false,
    /// Buffer revision / settings the matches were computed for.
    computed_for: ?u64 = null,

    pub fn deinit(s: *Search, gpa: Allocator) void {
        s.query.deinit(gpa);
        s.matches.deinit(gpa);
    }
};

pub const EditorCore = struct {
    gpa: Allocator,
    buffer: Buffer,
    sel: Selection = .{},
    /// IME composition range (bytes).
    marked: ?Range = null,
    read_only: bool = false,
    tab_size: usize = default_tab_size,
    /// Display column (in characters) kept across vertical moves.
    preferred_x: ?f32 = null,

    undo_stack: std.ArrayList(Transaction) = .empty,
    redo_stack: std.ArrayList(Transaction) = .empty,
    coalesce_break: bool = false,
    /// IME: the open composition transaction absorbs every marked update.
    composing: bool = false,
    next_version: u64 = 1,
    base_version: u64 = 0,
    saved_version: u64 = 0,

    line_edits: std.ArrayList(LineEdit) = .empty,
    search: Search = .{},
    scratch: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) EditorCore {
        return .{ .gpa = gpa, .buffer = .init(gpa) };
    }

    pub fn deinit(self: *EditorCore) void {
        self.clearHistory();
        self.undo_stack.deinit(self.gpa);
        self.redo_stack.deinit(self.gpa);
        self.line_edits.deinit(self.gpa);
        self.search.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.buffer.deinit();
    }

    fn clearHistory(self: *EditorCore) void {
        for (self.undo_stack.items) |*t| t.deinit(self.gpa);
        for (self.redo_stack.items) |*t| t.deinit(self.gpa);
        self.undo_stack.clearRetainingCapacity();
        self.redo_stack.clearRetainingCapacity();
    }

    // ---- document ------------------------------------------------------------------

    /// Load a new baseline (history resets, clean).
    pub fn load(self: *EditorCore, owned: []u8) Allocator.Error!void {
        const old_lines = self.buffer.lineCount();
        try self.buffer.adopt(owned);
        self.clearHistory();
        self.sel = .{};
        self.marked = null;
        self.composing = false;
        self.base_version = self.next_version;
        self.next_version += 1;
        self.saved_version = self.base_version;
        self.search.computed_for = null;
        try self.line_edits.append(self.gpa, .{ .line = 0, .removed = old_lines, .added = self.buffer.lineCount(), .full = true });
    }

    /// Replace the contents as a new disk baseline, keeping the selection
    /// (clamped). Not undoable (zeron `replace_file_contents`).
    pub fn reloadKeepingSelection(self: *EditorCore, owned: []u8) Allocator.Error!void {
        const sel = self.sel;
        try self.load(owned);
        const n = self.buffer.len();
        self.sel = .{ .anchor = self.clampBoundary(@min(sel.anchor, n)), .head = self.clampBoundary(@min(sel.head, n)) };
    }

    pub fn len(self: *const EditorCore) usize {
        return self.buffer.len();
    }

    pub fn currentVersion(self: *const EditorCore) u64 {
        if (self.undo_stack.items.len == 0) return self.base_version;
        return self.undo_stack.items[self.undo_stack.items.len - 1].version;
    }

    pub fn isDirty(self: *const EditorCore) bool {
        return self.currentVersion() != self.saved_version;
    }

    /// Record the current state as saved (after a successful write).
    pub fn markSaved(self: *EditorCore, version: u64) void {
        self.saved_version = version;
        self.breakUndoRun();
    }

    pub fn canUndo(self: *const EditorCore) bool {
        return self.undo_stack.items.len > 0;
    }
    pub fn canRedo(self: *const EditorCore) bool {
        return self.redo_stack.items.len > 0;
    }

    pub fn takeLineEdits(self: *EditorCore, out: *std.ArrayList(LineEdit), gpa: Allocator) void {
        out.appendSlice(gpa, self.line_edits.items) catch @panic("OOM");
        self.line_edits.clearRetainingCapacity();
    }

    pub fn cursor(self: *const EditorCore) usize {
        return self.sel.head;
    }

    pub fn selectedText(self: *EditorCore, out: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!void {
        try self.buffer.appendRange(self.sel.start(), self.sel.end(), out, gpa);
    }

    // ---- low-level edit plumbing -----------------------------------------------------

    fn copyRange(self: *EditorCore, r: Range) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try self.buffer.appendRange(r.start, r.end, &out, self.gpa);
        return out.toOwnedSlice(self.gpa);
    }

    fn applyRaw(self: *EditorCore, start: usize, old_len: usize, new: []const u8) Allocator.Error!void {
        const line = self.buffer.lineOf(start);
        var removed_nl: usize = 0;
        if (old_len > 0) {
            var it = self.buffer.chunksIn(start, start + old_len);
            while (it.next()) |s| removed_nl += std.mem.count(u8, s, "\n");
        }
        const col = start - self.buffer.lineStart(line);
        self.buffer.delete(start, start + old_len);
        try self.buffer.insert(start, new);
        try self.line_edits.append(self.gpa, .{ .line = line, .removed = removed_nl + 1, .added = std.mem.count(u8, new, "\n") + 1, .col = col, .old_len = old_len, .new_len = new.len, .start = start });
    }

    /// Replace `range` with `text` as an undoable edit and select `after`.
    fn edit(self: *EditorCore, range: Range, text: []const u8, intent: Intent, after: Selection, now: u64) Allocator.Error!void {
        const before = self.sel;
        const old = try self.copyRange(range);
        errdefer self.gpa.free(old);
        if (std.mem.eql(u8, old, text)) {
            self.gpa.free(old);
            self.sel = after;
            return;
        }
        try self.applyRaw(range.start, range.len(), text);
        self.sel = after;
        self.marked = null;
        for (self.redo_stack.items) |*t| t.deinit(self.gpa);
        self.redo_stack.clearRetainingCapacity();

        if (self.tryCoalesce(range, old, text, intent, now)) {
            self.gpa.free(old);
            return;
        }
        const new_copy = try self.gpa.dupe(u8, text);
        var t: Transaction = .{ .before = before, .after = after, .intent = intent, .time = now, .version = self.next_version };
        self.next_version += 1;
        try t.edits.append(self.gpa, .{ .start = range.start, .old = old, .new = new_copy });
        try self.pushUndo(t);
        self.coalesce_break = false;
    }

    fn pushUndo(self: *EditorCore, t: Transaction) Allocator.Error!void {
        if (self.undo_stack.items.len >= undo_limit) {
            var first = self.undo_stack.orderedRemove(0);
            // The dropped step's version becomes the new floor.
            self.base_version = first.version;
            first.deinit(self.gpa);
        }
        try self.undo_stack.append(self.gpa, t);
    }

    fn tryCoalesce(self: *EditorCore, range: Range, old: []const u8, text: []const u8, intent: Intent, now: u64) bool {
        if (self.composing) {
            // The open IME transaction absorbs the update: rewrite its edit.
            if (self.undo_stack.items.len == 0) return false;
            const t = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (t.edits.items.len != 1) return false;
            const e = &t.edits.items[0];
            // The composition replaced e.new at e.start; this update replaces a
            // range inside it (range ⊆ [e.start, e.start + e.new.len]).
            if (range.start < e.start or range.end > e.start + e.new.len) return false;
            const merged = std.mem.concat(self.gpa, u8, &.{ e.new[0 .. range.start - e.start], text, e.new[range.end - e.start ..] }) catch return false;
            self.gpa.free(e.new);
            e.new = merged;
            t.after = self.sel;
            return true;
        }
        if (intent == .atomic or self.coalesce_break) return false;
        if (self.undo_stack.items.len == 0) return false;
        const t = &self.undo_stack.items[self.undo_stack.items.len - 1];
        if (t.intent != intent or t.edits.items.len != 1) return false;
        if (now -| t.time > undo_coalesce_ns) return false;
        if (t.version == self.saved_version) return false;
        const e = &t.edits.items[0];
        switch (intent) {
            .typing => {
                if (old.len != 0 or range.start != e.start + e.new.len) return false;
                const merged = std.mem.concat(self.gpa, u8, &.{ e.new, text }) catch return false;
                self.gpa.free(e.new);
                e.new = merged;
            },
            .backspace => {
                if (text.len != 0 or e.new.len != 0 or range.end != e.start) return false;
                const merged = std.mem.concat(self.gpa, u8, &.{ old, e.old }) catch return false;
                self.gpa.free(e.old);
                e.old = merged;
                e.start = range.start;
            },
            .delete_forward => {
                if (text.len != 0 or e.new.len != 0 or range.start != e.start) return false;
                const merged = std.mem.concat(self.gpa, u8, &.{ e.old, old }) catch return false;
                self.gpa.free(e.old);
                e.old = merged;
            },
            .atomic => return false,
        }
        t.after = self.sel;
        t.time = now;
        return true;
    }

    /// End the current typing run (cursor moves, saves, focus changes).
    pub fn breakUndoRun(self: *EditorCore) void {
        self.coalesce_break = true;
    }

    pub fn undo(self: *EditorCore) Allocator.Error!bool {
        if (self.read_only) return false;
        self.endComposition();
        const t = self.undo_stack.pop() orelse return false;
        var i = t.edits.items.len;
        while (i > 0) {
            i -= 1;
            const e = t.edits.items[i];
            try self.applyRaw(e.start, e.new.len, e.old);
        }
        self.sel = t.before;
        self.marked = null;
        try self.redo_stack.append(self.gpa, t);
        self.coalesce_break = true;
        return true;
    }

    pub fn redo(self: *EditorCore) Allocator.Error!bool {
        if (self.read_only) return false;
        const t = self.redo_stack.pop() orelse return false;
        for (t.edits.items) |e| try self.applyRaw(e.start, e.old.len, e.new);
        self.sel = t.after;
        self.marked = null;
        try self.undo_stack.append(self.gpa, t);
        self.coalesce_break = true;
        return true;
    }

    // ---- boundaries ----------------------------------------------------------------

    /// Never leave an offset inside a UTF-8 scalar.
    pub fn clampBoundary(self: *EditorCore, offset: usize) usize {
        var o = @min(offset, self.buffer.len());
        while (o > 0 and o < self.buffer.len() and self.buffer.byteAt(o) & 0xC0 == 0x80) o -= 1;
        return o;
    }

    fn lineCtx(self: *EditorCore, offset: usize) struct { start: usize, text: []const u8, rel: usize, line: usize } {
        const line = self.buffer.lineOf(offset);
        const r = self.buffer.lineRange(line);
        const text = self.buffer.slice(r.start, r.end, &self.scratch, self.gpa);
        return .{ .start = r.start, .text = text, .rel = offset - r.start, .line = line };
    }

    pub fn prevBoundary(self: *EditorCore, offset: usize) usize {
        if (offset == 0) return 0;
        const c = self.lineCtx(offset);
        if (c.rel == 0) return offset - 1; // join with the previous line's newline
        return c.start + seg.prevGrapheme(c.text, c.rel);
    }

    pub fn nextBoundary(self: *EditorCore, offset: usize) usize {
        if (offset >= self.buffer.len()) return self.buffer.len();
        const c = self.lineCtx(offset);
        if (c.rel >= c.text.len) return offset + 1;
        return c.start + seg.nextGrapheme(c.text, c.rel);
    }

    pub fn prevWordBoundary(self: *EditorCore, offset: usize) usize {
        if (offset == 0) return 0;
        const c = self.lineCtx(offset);
        if (c.rel == 0) return offset - 1;
        return c.start + seg.prevWordBoundary(c.text, c.rel);
    }

    pub fn nextWordBoundary(self: *EditorCore, offset: usize) usize {
        if (offset >= self.buffer.len()) return self.buffer.len();
        const c = self.lineCtx(offset);
        if (c.rel >= c.text.len) return offset + 1;
        return c.start + seg.nextWordBoundary(c.text, c.rel);
    }

    /// The word (or whitespace / punctuation run) under `offset` (double click).
    pub fn wordRangeAt(self: *EditorCore, offset: usize) Range {
        const c = self.lineCtx(offset);
        if (c.text.len == 0) return .{ .start = offset, .end = offset };
        const w = seg.wordRange(c.text, @min(c.rel, c.text.len -| 1));
        return .{ .start = c.start + w.start, .end = c.start + w.end };
    }

    /// The whole line including its newline (triple click).
    pub fn lineRangeWithNewline(self: *EditorCore, offset: usize) Range {
        const line = self.buffer.lineOf(offset);
        const r = self.buffer.lineRange(line);
        return .{ .start = r.start, .end = @min(r.end + 1, self.buffer.len()) };
    }

    fn indentEnd(text: []const u8) usize {
        var i: usize = 0;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        return i;
    }

    /// Smart home: first non-blank column, or column 0 when already there.
    pub fn homeTarget(self: *EditorCore, offset: usize) usize {
        const c = self.lineCtx(offset);
        const first = indentEnd(c.text);
        if (c.rel == first or first == c.text.len) return c.start;
        return c.start + first;
    }

    pub fn lineEndOf(self: *EditorCore, offset: usize) usize {
        return self.buffer.lineEnd(self.buffer.lineOf(offset));
    }

    // ---- selection -----------------------------------------------------------------

    pub fn moveTo(self: *EditorCore, offset: usize) void {
        const o = self.clampBoundary(offset);
        self.sel = .collapsed(o);
        self.marked = null;
        self.endComposition();
        self.breakUndoRun();
    }

    pub fn selectTo(self: *EditorCore, offset: usize) void {
        self.sel.head = self.clampBoundary(offset);
        self.endComposition();
        self.breakUndoRun();
    }

    pub fn setSelection(self: *EditorCore, s: Selection) void {
        self.sel = .{ .anchor = self.clampBoundary(s.anchor), .head = self.clampBoundary(s.head) };
        self.endComposition();
        self.breakUndoRun();
    }

    pub fn selectAll(self: *EditorCore) void {
        self.setSelection(.{ .anchor = 0, .head = self.buffer.len() });
    }

    /// Collapse a selection to its edge, else step one grapheme.
    pub fn left(self: *EditorCore, select: bool) void {
        if (!select and !self.sel.isEmpty()) return self.moveTo(self.sel.start());
        const t = self.prevBoundary(self.sel.head);
        if (select) self.selectTo(t) else self.moveTo(t);
    }

    pub fn right(self: *EditorCore, select: bool) void {
        if (!select and !self.sel.isEmpty()) return self.moveTo(self.sel.end());
        const t = self.nextBoundary(self.sel.head);
        if (select) self.selectTo(t) else self.moveTo(t);
    }

    pub fn wordLeft(self: *EditorCore, select: bool) void {
        const t = self.prevWordBoundary(self.sel.head);
        if (select) self.selectTo(t) else self.moveTo(t);
    }

    pub fn wordRight(self: *EditorCore, select: bool) void {
        const t = self.nextWordBoundary(self.sel.head);
        if (select) self.selectTo(t) else self.moveTo(t);
    }

    pub fn home(self: *EditorCore, select: bool) void {
        const t = self.homeTarget(self.sel.head);
        if (select) self.selectTo(t) else self.moveTo(t);
    }

    pub fn end(self: *EditorCore, select: bool) void {
        const t = self.lineEndOf(self.sel.head);
        if (select) self.selectTo(t) else self.moveTo(t);
    }

    pub fn docStart(self: *EditorCore, select: bool) void {
        if (select) self.selectTo(0) else self.moveTo(0);
    }

    pub fn docEnd(self: *EditorCore, select: bool) void {
        const n = self.buffer.len();
        if (select) self.selectTo(n) else self.moveTo(n);
    }

    // ---- editing -------------------------------------------------------------------

    /// Insert `text` over the selection (typing / paste). Paste is atomic.
    pub fn insertText(self: *EditorCore, text: []const u8, intent: Intent, now: u64) Allocator.Error!bool {
        if (self.read_only) return false;
        const r = self.sel.range();
        if (r.isEmpty() and text.len == 0) return false;
        try self.edit(r, text, intent, .collapsed(r.start + text.len), now);
        return true;
    }

    /// The indent Enter carries over: the current line's leading whitespace,
    /// or the next line's when that is deeper (gpui-component `indent_of_next_line`).
    pub fn indentForNewline(self: *EditorCore, out: *std.ArrayList(u8)) Allocator.Error!void {
        out.clearRetainingCapacity();
        const head = self.sel.start();
        const line = self.buffer.lineOf(head);
        const cur = self.buffer.lineRange(line);
        const cur_text = self.buffer.slice(cur.start, cur.end, &self.scratch, self.gpa);
        const cur_indent = indentEnd(cur_text[0..@min(cur_text.len, head - cur.start)]);
        try out.appendSlice(self.gpa, cur_text[0..cur_indent]);
        if (line + 1 < self.buffer.lineCount()) {
            const next = self.buffer.lineRange(line + 1);
            const next_text = self.buffer.slice(next.start, next.end, &self.scratch, self.gpa);
            const next_indent = indentEnd(next_text);
            if (next_indent > cur_indent and head == cur.end) {
                out.clearRetainingCapacity();
                try out.appendSlice(self.gpa, next_text[0..next_indent]);
            }
        }
    }

    pub fn newline(self: *EditorCore, now: u64) Allocator.Error!bool {
        if (self.read_only) return false;
        var lead: std.ArrayList(u8) = .empty;
        defer lead.deinit(self.gpa);
        try self.indentForNewline(&lead);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        try text.append(self.gpa, '\n');
        try text.appendSlice(self.gpa, lead.items);
        self.breakUndoRun();
        const ok = try self.insertText(text.items, .atomic, now);
        self.breakUndoRun();
        return ok;
    }

    pub fn deleteRange(self: *EditorCore, r: Range, intent: Intent, now: u64) Allocator.Error!bool {
        if (self.read_only or r.isEmpty()) return false;
        try self.edit(r, "", intent, .collapsed(r.start), now);
        return true;
    }

    pub fn backspace(self: *EditorCore, now: u64) Allocator.Error!bool {
        if (!self.sel.isEmpty()) return self.deleteRange(self.sel.range(), .atomic, now);
        const head = self.sel.head;
        return self.deleteRange(.{ .start = self.prevBoundary(head), .end = head }, .backspace, now);
    }

    pub fn deleteForward(self: *EditorCore, now: u64) Allocator.Error!bool {
        if (!self.sel.isEmpty()) return self.deleteRange(self.sel.range(), .atomic, now);
        const head = self.sel.head;
        return self.deleteRange(.{ .start = head, .end = self.nextBoundary(head) }, .delete_forward, now);
    }

    pub fn deleteWordLeft(self: *EditorCore, now: u64) Allocator.Error!bool {
        if (!self.sel.isEmpty()) return self.deleteRange(self.sel.range(), .atomic, now);
        const head = self.sel.head;
        return self.deleteRange(.{ .start = self.prevWordBoundary(head), .end = head }, .atomic, now);
    }

    pub fn deleteWordRight(self: *EditorCore, now: u64) Allocator.Error!bool {
        if (!self.sel.isEmpty()) return self.deleteRange(self.sel.range(), .atomic, now);
        const head = self.sel.head;
        return self.deleteRange(.{ .start = head, .end = self.nextWordBoundary(head) }, .atomic, now);
    }

    pub fn deleteToLineStart(self: *EditorCore, now: u64) Allocator.Error!bool {
        if (!self.sel.isEmpty()) return self.deleteRange(self.sel.range(), .atomic, now);
        const head = self.sel.head;
        const start = self.buffer.lineStart(self.buffer.lineOf(head));
        return self.deleteRange(.{ .start = if (start == head) self.prevBoundary(head) else start, .end = head }, .atomic, now);
    }

    pub fn deleteToLineEnd(self: *EditorCore, now: u64) Allocator.Error!bool {
        if (!self.sel.isEmpty()) return self.deleteRange(self.sel.range(), .atomic, now);
        const head = self.sel.head;
        const e = self.lineEndOf(head);
        return self.deleteRange(.{ .start = head, .end = if (e == head) self.nextBoundary(head) else e }, .atomic, now);
    }

    fn tabText(self: *const EditorCore, buf: *[16]u8) []const u8 {
        const n = @min(self.tab_size, buf.len);
        @memset(buf[0..n], ' ');
        return buf[0..n];
    }

    /// Tab (inline) / indent action (block): with a selection or `block`,
    /// prefix every touched line; else insert one indent at the caret.
    pub fn indent(self: *EditorCore, block: bool, now: u64) Allocator.Error!bool {
        if (self.read_only) return false;
        var tab_buf: [16]u8 = undefined;
        const tab = self.tabText(&tab_buf);
        if (self.sel.isEmpty() and !block) {
            self.breakUndoRun();
            const ok = try self.insertText(tab, .atomic, now);
            self.breakUndoRun();
            return ok;
        }
        const first = self.buffer.lineOf(self.sel.start());
        var last = self.buffer.lineOf(self.sel.end());
        // A selection ending at column 0 does not touch that line.
        if (last > first and self.buffer.lineStart(last) == self.sel.end()) last -= 1;
        return self.rewriteLines(first, last, .indent, tab, now);
    }

    pub fn outdent(self: *EditorCore, block: bool, now: u64) Allocator.Error!bool {
        _ = block;
        if (self.read_only) return false;
        var tab_buf: [16]u8 = undefined;
        const tab = self.tabText(&tab_buf);
        const first = self.buffer.lineOf(self.sel.start());
        var last = self.buffer.lineOf(self.sel.end());
        if (last > first and self.buffer.lineStart(last) == self.sel.end()) last -= 1;
        return self.rewriteLines(first, last, .outdent, tab, now);
    }

    const Rewrite = enum { indent, outdent };

    /// Rewrite lines `[first, last]` as one transaction, shifting the
    /// selection with the text.
    fn rewriteLines(self: *EditorCore, first: usize, last: usize, how: Rewrite, tab: []const u8, now: u64) Allocator.Error!bool {
        const start = self.buffer.lineStart(first);
        const stop = self.buffer.lineEnd(last);
        var old: std.ArrayList(u8) = .empty;
        defer old.deinit(self.gpa);
        try self.buffer.appendRange(start, stop, &old, self.gpa);
        var new: std.ArrayList(u8) = .empty;
        defer new.deinit(self.gpa);
        // Track how the anchor / head move with their lines (old coordinates in,
        // new coordinates out; column 0 stays at column 0 like gpui-component).
        const orig = [2]usize{ self.sel.anchor, self.sel.head };
        var moved = orig;
        var done = [2]bool{ false, false };
        var it = std.mem.splitScalar(u8, old.items, '\n');
        var line_start_old: usize = start;
        var delta: isize = 0;
        var first_line = true;
        while (it.next()) |line| {
            if (!first_line) try new.append(self.gpa, '\n');
            first_line = false;
            var removed: usize = 0;
            var added: usize = 0;
            switch (how) {
                .indent => {
                    try new.appendSlice(self.gpa, tab);
                    try new.appendSlice(self.gpa, line);
                    added = tab.len;
                },
                .outdent => {
                    var n: usize = 0;
                    if (line.len > 0 and line[0] == '\t') n = 1 else while (n < tab.len and n < line.len and line[n] == ' ') n += 1;
                    try new.appendSlice(self.gpa, line[n..]);
                    removed = n;
                },
            }
            for (orig, 0..) |o, k| {
                if (done[k] or o < line_start_old or o > line_start_old + line.len) continue;
                const col = o - line_start_old;
                const new_col = switch (how) {
                    .indent => if (col == 0) 0 else col + added,
                    .outdent => col - @min(col, removed),
                };
                moved[k] = @intCast(@as(isize, @intCast(line_start_old)) + delta + @as(isize, @intCast(new_col)));
                done[k] = true;
            }
            delta += @as(isize, @intCast(added)) - @as(isize, @intCast(removed));
            line_start_old += line.len + 1;
        }
        const anchor = moved[0];
        const head = moved[1];
        if (std.mem.eql(u8, old.items, new.items)) return false;
        self.breakUndoRun();
        try self.edit(.{ .start = start, .end = stop }, new.items, .atomic, .{ .anchor = anchor, .head = head }, now);
        self.breakUndoRun();
        return true;
    }

    // ---- IME -----------------------------------------------------------------------

    /// Replace (and mark) composition text; consecutive updates are one undo step.
    pub fn replaceAndMark(self: *EditorCore, range_opt: ?Range, text: []const u8, new_selected: ?Range, now: u64) Allocator.Error!bool {
        if (self.read_only) return false;
        const r = range_opt orelse self.marked orelse self.sel.range();
        const was_composing = self.composing;
        if (!was_composing) self.breakUndoRun();
        try self.edit(r, text, .atomic, .collapsed(r.start + text.len), now);
        self.composing = true;
        self.marked = if (text.len > 0) .{ .start = r.start, .end = r.start + text.len } else null;
        if (new_selected) |s| self.sel = .{ .anchor = r.start + @min(s.start, text.len), .head = r.start + @min(s.end, text.len) };
        return true;
    }

    pub fn endComposition(self: *EditorCore) void {
        if (self.composing) {
            self.composing = false;
            self.coalesce_break = true;
        }
    }

    pub fn unmark(self: *EditorCore) bool {
        const had = self.marked != null;
        self.marked = null;
        self.endComposition();
        return had;
    }

    /// IME commit / plain text input over `range_opt` (or the marked range, or the selection).
    pub fn commitText(self: *EditorCore, range_opt: ?Range, text: []const u8, now: u64) Allocator.Error!bool {
        if (self.read_only) return false;
        const r = range_opt orelse self.marked orelse self.sel.range();
        const composing = self.composing;
        try self.edit(r, text, .typing, .collapsed(r.start + text.len), now);
        self.marked = null;
        if (composing) self.endComposition();
        return true;
    }

    /// Replace `range` as one undo step, keeping the selection where it was
    /// (a same-length edit, e.g. a Markdown task marker toggled from the preview).
    pub fn replaceKeepingSelection(self: *EditorCore, range: Range, text: []const u8, now: u64) Allocator.Error!bool {
        if (self.read_only) return false;
        const keep = self.sel;
        try self.edit(range, text, .atomic, keep, now);
        return true;
    }

    // ---- search --------------------------------------------------------------------

    pub fn setSearchQuery(self: *EditorCore, query: []const u8) void {
        if (std.mem.eql(u8, query, self.search.query.items)) return;
        self.search.query.clearRetainingCapacity();
        self.search.query.appendSlice(self.gpa, query) catch @panic("OOM");
        self.search.computed_for = null;
    }

    pub fn setSearchOptions(self: *EditorCore, case_sensitive: bool, whole_word: bool) void {
        if (self.search.case_sensitive == case_sensitive and self.search.whole_word == whole_word) return;
        self.search.case_sensitive = case_sensitive;
        self.search.whole_word = whole_word;
        self.search.computed_for = null;
    }

    fn searchKey(self: *const EditorCore) u64 {
        return self.buffer.revision *% 4 + @as(u64, @intFromBool(self.search.case_sensitive)) * 2 + @intFromBool(self.search.whole_word);
    }

    fn isWordByte(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
    }

    /// Recompute matches if the text or query changed; keeps the active match
    /// nearest the caret.
    pub fn refreshSearch(self: *EditorCore) void {
        const key = self.searchKey();
        if (self.search.computed_for) |k| if (k == key) return;
        self.search.computed_for = key;
        self.search.matches.clearRetainingCapacity();
        self.search.capped = false;
        self.search.active = null;
        const q = self.search.query.items;
        if (q.len == 0) return;
        const cs = self.search.case_sensitive;
        // Streaming search: a window of (needle-1) carried bytes + the next chunk.
        var window: std.ArrayList(u8) = .empty;
        defer window.deinit(self.gpa);
        var window_start: usize = 0; // document offset of window[0]
        var it = self.buffer.chunksIn(0, self.buffer.len());
        var last_end: usize = 0;
        while (it.next()) |chunk| {
            window.appendSlice(self.gpa, chunk) catch @panic("OOM");
            var i: usize = 0;
            while (i + q.len <= window.items.len) {
                const found = if (cs) std.mem.indexOfPos(u8, window.items, i, q) else indexOfIgnoreCasePos(window.items, i, q);
                const f = found orelse break;
                const s = window_start + f;
                if (s >= last_end) {
                    var ok = true;
                    if (self.search.whole_word) {
                        const before = if (s == 0) ' ' else self.buffer.byteAt(s - 1);
                        const after = if (s + q.len >= self.buffer.len()) ' ' else self.buffer.byteAt(s + q.len);
                        ok = !isWordByte(before) and !isWordByte(after);
                    }
                    if (ok) {
                        if (self.search.matches.items.len >= max_matches) {
                            self.search.capped = true;
                            break;
                        }
                        self.search.matches.append(self.gpa, .{ .start = s, .end = s + q.len }) catch @panic("OOM");
                        last_end = s + q.len;
                    }
                }
                i = f + 1;
            }
            if (self.search.capped) break;
            // Keep the last q.len-1 bytes for matches spanning chunks.
            const keep = @min(window.items.len, q.len - 1);
            const drop = window.items.len - keep;
            window_start += drop;
            std.mem.copyForwards(u8, window.items[0..keep], window.items[drop..]);
            window.shrinkRetainingCapacity(keep);
        }
        self.search.active = self.matchAtOrAfter(self.sel.start());
    }

    fn matchAtOrAfter(self: *const EditorCore, offset: usize) ?usize {
        const m = self.search.matches.items;
        if (m.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = m.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (m[mid].start < offset) lo = mid + 1 else hi = mid;
        }
        return if (lo < m.len) lo else 0;
    }

    /// Select the next (or previous) match from the caret; returns it.
    pub fn findNext(self: *EditorCore, forward: bool) ?Range {
        self.refreshSearch();
        const m = self.search.matches.items;
        if (m.len == 0) return null;
        var ix: usize = undefined;
        if (forward) {
            const from = if (self.sel.isEmpty()) self.sel.head else self.sel.end();
            ix = self.matchAtOrAfter(from).?;
        } else {
            const from = self.sel.start();
            const after = self.matchAtOrAfter(from).?;
            ix = if (m[after].start >= from) (if (after == 0) m.len - 1 else after - 1) else m.len - 1;
        }
        self.search.active = ix;
        self.setSelection(.{ .anchor = m[ix].start, .head = m[ix].end });
        return m[ix];
    }

    /// Replace the active match (when it is the selection), then move on.
    pub fn replaceCurrent(self: *EditorCore, replacement: []const u8, now: u64) Allocator.Error!bool {
        if (self.read_only) return false;
        self.refreshSearch();
        const m = self.search.matches.items;
        if (m.len == 0) return false;
        const r = self.sel.range();
        var hit = false;
        for (m) |x| if (x.start == r.start and x.end == r.end) {
            hit = true;
            break;
        };
        if (!hit) {
            _ = self.findNext(true);
            return false;
        }
        self.breakUndoRun();
        try self.edit(r, replacement, .atomic, .collapsed(r.start + replacement.len), now);
        self.breakUndoRun();
        self.refreshSearch();
        _ = self.findNext(true);
        return true;
    }

    /// Replace every match as one undo step; returns the count.
    pub fn replaceAll(self: *EditorCore, replacement: []const u8, now: u64) Allocator.Error!usize {
        if (self.read_only) return 0;
        self.refreshSearch();
        const m = self.search.matches.items;
        if (m.len == 0) return 0;
        const count = m.len;
        const before = self.sel;
        var t: Transaction = .{ .before = before, .after = before, .intent = .atomic, .time = now, .version = self.next_version };
        errdefer t.deinit(self.gpa);
        // Apply from the end so earlier offsets stay valid; record in apply order.
        var i = m.len;
        const ranges = try self.gpa.dupe(Range, m);
        defer self.gpa.free(ranges);
        while (i > 0) {
            i -= 1;
            const r = ranges[i];
            const old = try self.copyRange(r);
            try self.applyRaw(r.start, r.len(), replacement);
            try t.edits.append(self.gpa, .{ .start = r.start, .old = old, .new = try self.gpa.dupe(u8, replacement) });
        }
        self.next_version += 1;
        const first = ranges[0];
        self.sel = .collapsed(@min(first.start + replacement.len, self.buffer.len()));
        t.after = self.sel;
        for (self.redo_stack.items) |*rt| rt.deinit(self.gpa);
        self.redo_stack.clearRetainingCapacity();
        try self.pushUndo(t);
        self.breakUndoRun();
        return count;
    }
};

fn indexOfIgnoreCasePos(hay: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return start;
    const first = std.ascii.toLower(needle[0]);
    var i = start;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.toLower(hay[i]) != first) continue;
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn coreWith(text: []const u8) !EditorCore {
    var c = EditorCore.init(testing.allocator);
    try c.load(try testing.allocator.dupe(u8, text));
    return c;
}

fn expectText(c: *EditorCore, expected: []const u8) !void {
    const got = try c.buffer.toOwned(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "typing coalesces into one undo step and dirty tracks undo" {
    var c = try coreWith("");
    defer c.deinit();
    try testing.expect(!c.isDirty());
    var t: u64 = 0;
    for ("hello") |ch| {
        _ = try c.insertText(&.{ch}, .typing, t);
        t += 10 * std.time.ns_per_ms;
    }
    try expectText(&c, "hello");
    try testing.expect(c.isDirty());
    try testing.expectEqual(@as(usize, 1), c.undo_stack.items.len);
    _ = try c.undo();
    try expectText(&c, "");
    try testing.expect(!c.isDirty());
    _ = try c.redo();
    try expectText(&c, "hello");
    try testing.expectEqual(@as(usize, 5), c.cursor());
}

test "saving breaks the run so undo returns to dirty correctly" {
    var c = try coreWith("");
    defer c.deinit();
    _ = try c.insertText("a", .typing, 0);
    c.markSaved(c.currentVersion());
    try testing.expect(!c.isDirty());
    _ = try c.insertText("b", .typing, 1);
    try testing.expect(c.isDirty());
    _ = try c.undo();
    try testing.expect(!c.isDirty());
    try expectText(&c, "a");
}

test "backspace runs coalesce and newline auto-indents" {
    var c = try coreWith("fn main() {\n    let x = 1;\n}");
    defer c.deinit();
    c.moveTo(c.buffer.lineEnd(1));
    _ = try c.newline(0);
    try expectText(&c, "fn main() {\n    let x = 1;\n    \n}");
    _ = try c.insertText("y", .typing, 1);
    _ = try c.backspace(2);
    _ = try c.backspace(3);
    try expectText(&c, "fn main() {\n    let x = 1;\n   \n}");
    _ = try c.undo();
    try expectText(&c, "fn main() {\n    let x = 1;\n    y\n}");
    // Enter at the end of a line whose next line is deeper takes the deeper indent.
    c.moveTo(c.buffer.lineEnd(0));
    _ = try c.newline(4);
    try expectText(&c, "fn main() {\n    \n    let x = 1;\n    y\n}");
}

test "block indent and outdent keep the selection on its text" {
    var c = try coreWith("a\nb\nc");
    defer c.deinit();
    c.setSelection(.{ .anchor = 0, .head = 3 });
    _ = try c.indent(false, 0);
    try expectText(&c, "  a\n  b\nc");
    try testing.expectEqual(@as(usize, 0), c.sel.anchor);
    try testing.expectEqual(@as(usize, 7), c.sel.head);
    _ = try c.outdent(false, 1);
    try expectText(&c, "a\nb\nc");
    _ = try c.undo();
    try expectText(&c, "  a\n  b\nc");
    // Inline tab inserts two spaces at the caret.
    c.moveTo(c.buffer.len());
    _ = try c.indent(false, 2);
    try expectText(&c, "  a\n  b\nc  ");
}

test "smart home toggles between indent and column 0" {
    var c = try coreWith("    let x;");
    defer c.deinit();
    c.moveTo(8);
    c.home(false);
    try testing.expectEqual(@as(usize, 4), c.cursor());
    c.home(false);
    try testing.expectEqual(@as(usize, 0), c.cursor());
    c.home(false);
    try testing.expectEqual(@as(usize, 4), c.cursor());
}

test "motions cross line boundaries" {
    var c = try coreWith("ab\ncd");
    defer c.deinit();
    c.moveTo(3);
    c.left(false);
    try testing.expectEqual(@as(usize, 2), c.cursor());
    c.right(false);
    try testing.expectEqual(@as(usize, 3), c.cursor());
    c.wordLeft(false);
    try testing.expectEqual(@as(usize, 2), c.cursor());
}

test "search finds matches across chunks, case insensitive, replace all is one step" {
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..3000) |i| try text.appendSlice(gpa, if (i % 3 == 0) "Needle " else "hay ");
    var c = try coreWith(text.items);
    defer c.deinit();
    c.setSearchQuery("needle");
    c.refreshSearch();
    try testing.expectEqual(@as(usize, 1000), c.search.matches.items.len);
    const first = c.findNext(true).?;
    try testing.expectEqual(@as(usize, 0), first.start);
    const second = c.findNext(true).?;
    try testing.expect(second.start > first.start);
    const back = c.findNext(false).?;
    try testing.expectEqual(first.start, back.start);
    const n = try c.replaceAll("pin", 5);
    try testing.expectEqual(@as(usize, 1000), n);
    c.refreshSearch();
    try testing.expectEqual(@as(usize, 0), c.search.matches.items.len);
    _ = try c.undo();
    c.refreshSearch();
    try testing.expectEqual(@as(usize, 1000), c.search.matches.items.len);
    c.setSearchOptions(true, false);
    c.refreshSearch();
    try testing.expectEqual(@as(usize, 0), c.search.matches.items.len);
}

test "whole word search" {
    var c = try coreWith("cat concat cat_x cat.");
    defer c.deinit();
    c.setSearchQuery("cat");
    c.setSearchOptions(false, true);
    c.refreshSearch();
    try testing.expectEqual(@as(usize, 2), c.search.matches.items.len);
}

test "ime composition is one undo step" {
    var c = try coreWith("x");
    defer c.deinit();
    c.moveTo(1);
    _ = try c.replaceAndMark(null, "n", null, 0);
    _ = try c.replaceAndMark(null, "ni", null, 1);
    _ = try c.commitText(null, "你", 2);
    try expectText(&c, "x你");
    try testing.expect(c.marked == null);
    _ = try c.undo();
    try expectText(&c, "x");
}

test "line edits describe replaced lines" {
    var c = try coreWith("a\nb\nc");
    defer c.deinit();
    var edits: std.ArrayList(LineEdit) = .empty;
    defer edits.deinit(testing.allocator);
    c.takeLineEdits(&edits, testing.allocator);
    edits.clearRetainingCapacity();
    c.setSelection(.{ .anchor = 1, .head = 4 });
    _ = try c.insertText("X\nY\nZ", .atomic, 0);
    c.takeLineEdits(&edits, testing.allocator);
    try testing.expectEqual(@as(usize, 1), edits.items.len);
    try testing.expectEqual(@as(usize, 3), edits.items[0].removed);
    try testing.expectEqual(@as(usize, 3), edits.items[0].added);
}
