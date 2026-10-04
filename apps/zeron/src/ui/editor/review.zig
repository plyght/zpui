//! Review comments on editor lines — the editor half of zeron
//! `files/preview.rs` (`render_editor_comment_overlays`,
//! `sync_editor_comment_anchors` / `_lines`, the review-comment flush).
//!
//! - every visible line start gets a gutter cell: a hovered `+` opens a draft
//!   (`Add a comment…`), a commented line shows a chat glyph that toggles its
//!   card;
//! - staged file comments track a byte range of the buffer through edits
//!   (`comments.LineAnchor`, gpui-component decoration semantics) and their
//!   `line` follows the text; a detached range re-anchors from the last line;
//! - a comment citing unsaved text holds a flush on the store, so the
//!   composer cannot send until the buffer reaches disk (or the save fails /
//!   conflicts, or the editor closes).
//!
//! State lives on the `FileEditor` (`review: State`); comments themselves are
//! in `model.ReviewCommentStore`, reached through its global.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const zmodel = @import("zeron_model");
const input = @import("zeron_input");
const ui = @import("../components/root.zig");
const comment_ui = @import("../changes/comment_ui.zig");
const view = @import("view.zig");
const core_mod = @import("core.zig");

const FileEditor = view.FileEditor;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const AnyElement = zpui.AnyElement;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = zt.Theme;
const cm = zmodel.comments;
const ReviewCommentStore = zmodel.ReviewCommentStore;
const LineAnchor = cm.LineAnchor;

const Draft = struct {
    editing_id: ?[]u8 = null,
    /// The composer key the note stages onto.
    key: []u8,
    line: u32,
    input: Entity(input.TextInput),
    sub: zpui.Subscription,
};

pub const State = struct {
    /// comment id (owned) → tracked range.
    anchors: std.StringHashMapUnmanaged(LineAnchor) = .empty,
    draft: ?Draft = null,
    /// The comment whose card is open (owned id).
    active: ?[]u8 = null,
    /// The key a flush is held on while this buffer's comments wait for a write.
    flush_key: ?[]u8 = null,
    store_sub: ?zpui.Subscription = null,

    pub fn deinit(self: *State, ed: *FileEditor, app: *zpui.App) void {
        finishFlush(ed, app);
        if (self.store_sub) |*s| s.deinit();
        self.store_sub = null;
        dropDraft(ed, app);
        clearAnchors(ed);
        self.anchors.deinit(ed.gpa);
        freeOpt(ed.gpa, &self.active);
    }
};

fn freeOpt(gpa: Allocator, p: *?[]u8) void {
    if (p.*) |s| gpa.free(s);
    p.* = null;
}

fn clearAnchors(ed: *FileEditor) void {
    var it = ed.review.anchors.keyIterator();
    while (it.next()) |k| ed.gpa.free(k.*);
    ed.review.anchors.clearRetainingCapacity();
}

pub fn store(app: *zpui.App) ?Entity(ReviewCommentStore) {
    return zmodel.review_comments.current(app);
}

/// Observe the store (once one exists) so staged comments re-render here.
pub fn attach(ed: *FileEditor, cx: *Context(FileEditor)) void {
    if (ed.review.store_sub != null) return;
    const s = store(cx.app) orelse return;
    ed.review.store_sub = cx.observe(s, onStoreChanged) catch null;
}

fn onStoreChanged(ed: *FileEditor, _: Entity(ReviewCommentStore), cx: *Context(FileEditor)) void {
    syncAnchors(ed, cx);
    cx.notify();
}

/// Comments are only offered on an editable, loaded buffer.
pub fn enabled(ed: *const FileEditor) bool {
    if (ed.core.read_only) return false;
    return switch (ed.phase) {
        .ready, .saving, .save_failed, .externally_modified, .conflict, .deleted_on_disk => true,
        else => false,
    };
}

/// `staged_file_comments(path)`: shallow copies in `a`.
pub fn fileComments(ed: *const FileEditor, a: Allocator, app: *zpui.App) []cm.ReviewComment {
    const s = store(app) orelse return &.{};
    const st = s.read(app);
    var out: std.ArrayList(cm.ReviewComment) = .empty;
    for (st.comments(st.composerKey())) |c| {
        if (c.isFile() and std.mem.eql(u8, c.path, ed.path)) out.append(a, c) catch break;
    }
    return out.items;
}

/// `comment_anchor_range` over the editor buffer.
fn anchorForLine(ed: *FileEditor, line: u32) ?LineAnchor {
    const buf = &ed.core.buffer;
    const n = buf.lineCount();
    const ix: usize = if (line == 0) 0 else line - 1;
    if (ix >= n) return null;
    const start = buf.lineStart(ix);
    const end = if (ix + 1 < n) buf.lineStart(ix + 1) else buf.len();
    if (start < end) return .{ .start = start, .end = end, .edge = .start };
    if (start > 0) return .{ .start = start - 1, .end = start, .edge = .end };
    return null;
}

/// `tracked_comment_line`.
fn trackedLine(ed: *FileEditor, a: LineAnchor) u32 {
    const off = @min(switch (a.edge) {
        .start => a.start,
        .end => a.end,
    }, ed.core.buffer.len());
    return @intCast(ed.core.buffer.lineOf(off) + 1);
}

/// `sync_editor_comment_anchors`: drop anchors of removed comments, anchor new ones.
pub fn syncAnchors(ed: *FileEditor, cx: *Context(FileEditor)) void {
    if (!enabled(ed)) return;
    var arena: std.heap.ArenaAllocator = .init(ed.gpa);
    defer arena.deinit();
    const list = fileComments(ed, arena.allocator(), cx.app);
    var it = ed.review.anchors.iterator();
    var stale: std.ArrayList([]const u8) = .empty;
    while (it.next()) |e| {
        const keep = for (list) |c| {
            if (std.mem.eql(u8, c.id, e.key_ptr.*)) break true;
        } else false;
        if (!keep) stale.append(arena.allocator(), e.key_ptr.*) catch {};
    }
    for (stale.items) |k| if (ed.review.anchors.fetchRemove(k)) |kv| ed.gpa.free(kv.key);
    const lines: u32 = @intCast(@max(ed.core.buffer.lineCount(), 1));
    for (list) |c| {
        if (ed.review.anchors.contains(c.id)) continue;
        const anchor = anchorForLine(ed, @min(c.line, lines)) orelse continue;
        const key = ed.gpa.dupe(u8, c.id) catch continue;
        ed.review.anchors.put(ed.gpa, key, anchor) catch ed.gpa.free(key);
    }
}

/// Fold buffer edits into the anchors, then `sync_editor_comment_lines`.
pub fn applyEdits(ed: *FileEditor, edits: []const core_mod.LineEdit, cx: *Context(FileEditor)) void {
    if (ed.review.anchors.count() == 0) return;
    var arena: std.heap.ArenaAllocator = .init(ed.gpa);
    defer arena.deinit();
    var detached: std.ArrayList([]const u8) = .empty;
    for (edits) |e| {
        var it = ed.review.anchors.iterator();
        while (it.next()) |entry| {
            if (e.full or !entry.value_ptr.applyEdit(e.start, e.old_len, e.new_len)) {
                detached.append(arena.allocator(), entry.key_ptr.*) catch {};
            }
        }
    }
    for (detached.items) |k| if (ed.review.anchors.fetchRemove(k)) |kv| ed.gpa.free(kv.key);
    const s = store(cx.app) orelse return;
    const key = ed.gpa.dupe(u8, s.read(cx).composerKey()) catch return;
    defer ed.gpa.free(key);
    var it = ed.review.anchors.iterator();
    var updates: std.ArrayList(struct { []const u8, u32 }) = .empty;
    while (it.next()) |entry| updates.append(arena.allocator(), .{ entry.key_ptr.*, trackedLine(ed, entry.value_ptr.*) }) catch {};
    for (updates.items) |u| {
        s.update(cx, ReviewCommentStore.updateLine, .{ key, u[0], u[1] });
        if (ed.review.draft) |*d| if (d.editing_id) |id| if (std.mem.eql(u8, id, u[0])) {
            d.line = u[1];
        };
    }
    if (detached.items.len > 0) syncAnchors(ed, cx);
}

/// After an edit: comments on a dirty buffer wait for the write.
pub fn afterEdit(ed: *FileEditor, cx: *Context(FileEditor)) void {
    if (ed.review.anchors.count() == 0) return;
    requireFlush(ed, cx);
}

/// `require_review_comment_flush`.
fn requireFlush(ed: *FileEditor, cx: *Context(FileEditor)) void {
    if (!ed.core.isDirty() or ed.review.flush_key != null) return;
    const s = store(cx.app) orelse return;
    const key = ed.gpa.dupe(u8, s.read(cx).composerKey()) catch return;
    ed.review.flush_key = key;
    s.update(cx, ReviewCommentStore.beginFlush, .{ key, flushSource(ed) });
}

fn flushSource(ed: *const FileEditor) u64 {
    return @intFromPtr(ed);
}

fn finishFlush(ed: *FileEditor, app: *zpui.App) void {
    const key = ed.review.flush_key orelse return;
    ed.review.flush_key = null;
    defer ed.gpa.free(key);
    const s = store(app) orelse return;
    s.update(app, ReviewCommentStore.finishFlush, .{ key, flushSource(ed) });
}

/// `document_finishes_review_comment_flush`: a clean write, a failed save or
/// a conflict releases the composer.
pub fn onSaveOutcome(ed: *FileEditor, cx: *Context(FileEditor)) void {
    if (ed.review.flush_key == null) return;
    const done = (!ed.core.isDirty() and ed.phase == .ready) or ed.phase == .save_failed or ed.phase == .conflict;
    if (done) finishFlush(ed, cx.app);
}

/// `rename_review_comment_path`: file comments follow the renamed document.
pub fn renamed(ed: *FileEditor, old_path: []const u8, new_path: []const u8, cx: *Context(FileEditor)) void {
    const s = store(cx.app) orelse return;
    const key = ed.gpa.dupe(u8, s.read(cx).composerKey()) catch return;
    defer ed.gpa.free(key);
    s.update(cx, ReviewCommentStore.renamePath, .{ key, old_path, new_path });
}

// ---- drafts -------------------------------------------------------------------------

fn dropDraft(ed: *FileEditor, app: *zpui.App) void {
    var d = ed.review.draft orelse return;
    ed.review.draft = null;
    d.sub.deinit();
    d.input.release(app);
    if (d.editing_id) |id| ed.gpa.free(id);
    ed.gpa.free(d.key);
}

/// `open_editor_comment_draft`.
pub fn openDraft(ed: *FileEditor, line: u32, window: ?*Window, cx: *Context(FileEditor)) void {
    const s = store(cx.app) orelse return;
    const theme = ui.theme.get(cx).forPopup();
    const text_input = cx.newWith(input.TextInput, input.TextInput.init, .{input.Options{
        .placeholder = "Add a comment\u{2026}",
        .text_size = 12,
        .line_height = 22.75, // composer INPUT_LINE_HEIGHT
        .colors = .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
    }}) catch return;
    const sub = cx.subscribe(text_input, onDraftInput) catch {
        text_input.release(cx);
        return;
    };
    const key = ed.gpa.dupe(u8, s.read(cx).composerKey()) catch return;
    dropDraft(ed, cx.app);
    ed.review.draft = .{ .key = key, .line = line, .input = text_input, .sub = sub };
    freeOpt(ed.gpa, &ed.review.active);
    if (window) |w| w.focus(text_input.read(cx).focusHandle());
    cx.notify();
}

/// `edit_editor_comment`.
pub fn editComment(ed: *FileEditor, id: []const u8, window: *Window, cx: *Context(FileEditor)) void {
    editCommentIn(ed, id, window, cx);
}

pub fn editCommentIn(ed: *FileEditor, id: []const u8, window: ?*Window, cx: *Context(FileEditor)) void {
    const s = store(cx.app) orelse return;
    const st = s.read(cx);
    const c = st.find(st.composerKey(), id) orelse return;
    if (!c.isFile()) return;
    const body = ed.gpa.dupe(u8, c.body) catch return;
    defer ed.gpa.free(body);
    const owned = ed.gpa.dupe(u8, c.id) catch return;
    openDraft(ed, c.line, window, cx);
    const d = if (ed.review.draft) |*dd| dd else {
        ed.gpa.free(owned);
        return;
    };
    d.editing_id = owned;
    d.input.update(cx, input.TextInput.setText, .{body});
    cx.notify();
}

/// `cancel_editor_comment`: an edit's card stays open.
pub fn cancelDraft(ed: *FileEditor, cx: *Context(FileEditor)) void {
    if (ed.review.draft) |d| if (d.editing_id) |id| {
        freeOpt(ed.gpa, &ed.review.active);
        ed.review.active = ed.gpa.dupe(u8, id) catch null;
    };
    dropDraft(ed, cx.app);
    cx.notify();
}

/// `commit_editor_comment`.
pub fn commitDraft(ed: *FileEditor, cx: *Context(FileEditor)) void {
    const d = ed.review.draft orelse return;
    const s = store(cx.app) orelse return;
    const body = cm.trimUnicode(d.input.read(cx).text());
    if (body.len == 0) return cancelDraft(ed, cx);
    if (d.editing_id) |id| {
        s.update(cx, ReviewCommentStore.updateBody, .{ d.key, id, body });
        freeOpt(ed.gpa, &ed.review.active);
        ed.review.active = ed.gpa.dupe(u8, id) catch null;
        dropDraft(ed, cx.app);
        cx.notify();
        return;
    }
    _ = s.update(cx, ReviewCommentStore.add, .{ d.key, zmodel.review_comments.NewComment{ .path = ed.path, .line = d.line, .body = body, .source = .file } }) catch {};
    dropDraft(ed, cx.app);
    syncAnchors(ed, cx);
    freeOpt(ed.gpa, &ed.review.active);
    requireFlush(ed, cx);
    cx.notify();
}

/// `remove_editor_comment`.
pub fn removeComment(ed: *FileEditor, id: []const u8, cx: *Context(FileEditor)) void {
    const s = store(cx.app) orelse return;
    const key = ed.gpa.dupe(u8, s.read(cx).composerKey()) catch return;
    defer ed.gpa.free(key);
    if (ed.review.active) |a| if (std.mem.eql(u8, a, id)) freeOpt(ed.gpa, &ed.review.active);
    if (ed.review.anchors.fetchRemove(id)) |kv| ed.gpa.free(kv.key);
    s.update(cx, ReviewCommentStore.remove, .{ key, id });
    // The last comment on this file no longer needs the write.
    var arena: std.heap.ArenaAllocator = .init(ed.gpa);
    defer arena.deinit();
    if (fileComments(ed, arena.allocator(), cx.app).len == 0) finishFlush(ed, cx.app);
    cx.notify();
}

fn toggleComment(ed: *FileEditor, id: []const u8, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
    if (ed.review.active) |a| if (std.mem.eql(u8, a, id)) {
        freeOpt(ed.gpa, &ed.review.active);
        return cx.notify();
    };
    freeOpt(ed.gpa, &ed.review.active);
    ed.review.active = ed.gpa.dupe(u8, id) catch null;
    dropDraft(ed, cx.app);
    cx.notify();
}

fn onGutterClick(ed: *FileEditor, line: u32, _: *const zpui.ClickEvent, window: *Window, cx: *Context(FileEditor)) void {
    openDraft(ed, line, window, cx);
}

fn onDraftInput(ed: *FileEditor, _: Entity(input.TextInput), ev: *const input.TextInputEvent, cx: *Context(FileEditor)) void {
    switch (ev.*) {
        .submitted => commitDraft(ed, cx),
        .escape => cancelDraft(ed, cx),
        .edited => cx.notify(),
        else => {},
    }
}

fn stopDown(_: *const zpui.input.MouseDownEvent, _: *Window, cx: *zpui.App) void {
    cx.propagate_event = false;
}

// ---- overlays -----------------------------------------------------------------------

const RowTop = struct { line: u32, top: f32 };

/// `editor_comment_overlay_top` for `line` when it is on screen.
fn topFor(tops: []const RowTop, line: u32, line_h: f32, view_h: f32, card_h: f32) ?f32 {
    for (tops) |t| if (t.line == line) return comment_ui.editorOverlayTop(t.top, line_h, view_h, card_h);
    return null;
}

/// `render_editor_comment_overlays`: gutter cells for the visible line
/// starts plus the open card or draft. Positioned in the body's space.
pub fn overlays(ed: *FileEditor, theme: *const Theme, cx: *Context(FileEditor)) []AnyElement {
    if (!enabled(ed) or store(cx.app) == null) return &.{};
    // Anchors dropped by a reload (or staged before the buffer loaded) re-anchor here.
    syncAnchors(ed, cx);
    const bounds = ed.body_bounds orelse return &.{};
    const a = zpui.window.arena_mod.frameAllocator();
    const list = fileComments(ed, a, cx.app);
    const lh = ed.line_height;
    const off_y = ed.scroll.offset().y;
    const vh = bounds.size.height;
    const gutter = std.math.clamp(ed.gutterWidthPx(), 24, 64);
    var out: std.ArrayList(AnyElement) = .empty;
    const rows = ed.display.rowCount();
    if (rows == 0 or lh <= 0) return &.{};
    const first: usize = @intFromFloat(@max(@floor(-off_y / lh), 0));
    const last: usize = @min(rows, @as(usize, @intFromFloat(@max(@ceil((vh - off_y) / lh), 0))) + 1);
    var row_tops: std.ArrayList(RowTop) = .empty;
    var r = first;
    while (r < last) : (r += 1) {
        const pos = ed.display.lineForRow(r);
        if (pos.sub != 0) continue;
        const line: u32 = @intCast(pos.line + 1);
        const top = @as(f32, @floatFromInt(r)) * lh + off_y;
        row_tops.append(a, .{ .line = line, .top = top }) catch {};
        const commented: ?*const cm.ReviewComment = for (list) |*c| {
            if (c.line == line) break c;
        } else null;
        const cell = div().id(.{ "file-comment-gutter", @as(usize, line) }).absolute().left(px(0)).top(px(top)).w(px(gutter)).h(px(lh))
            .flex().itemsCenter().justifyCenter().cursorPointer().onMouseDown(.left, stopDown);
        if (commented) |c| {
            const id = a.dupe(u8, c.id) catch continue;
            out.append(a, zpui.intoAnyElement(cell.bg(theme.surface_card).hover(sb.bg(theme.wash(0.08)))
                .onClick(cx.listenerWith(id, toggleComment))
                .child(ui.icon.of(.chat_round_line, 10.5, theme.text_muted)))) catch {};
        } else {
            const group = zpui.fmt("file-comment-gutter-{d}", .{line});
            out.append(a, zpui.intoAnyElement(cell.group(group).hover(sb.bg(theme.surface_card))
                .onClick(cx.listenerWith(line, onGutterClick))
                .child(div().size(px(cm.comment_adder_size)).opacity(0).groupHover(group, sb.opacity(1)).rounded(px(4)).bg(theme.solid)
                .flex().itemsCenter().justifyCenter().child(ui.icon.of(.plus, 11, theme.on_solid))))) catch {};
        }
    }
    const h = comment_ui.editorOverlayHorizontal(gutter, bounds.size.width);
    const active: ?*const cm.ReviewComment = if (ed.review.active) |id| for (list) |*c| {
        if (std.mem.eql(u8, c.id, id)) break c;
    } else null else null;
    if (active) |c| {
        if (topFor(row_tops.items, c.line, lh, vh, cm.cardHeight(c.body))) |top|
            out.append(a, comment_ui.editorCard(FileEditor, c, h.left, h.width, top, theme, cx, editComment, removeComment)) catch {};
    } else if (ed.review.draft) |d| {
        if (topFor(row_tops.items, d.line, lh, vh, comment_ui.editor_draft_height)) |top|
            out.append(a, comment_ui.editorDraft(FileEditor, d.input, d.editing_id != null, h.left, h.width, top, theme, cx, cancelDraft, commitDraft)) catch {};
    }
    return out.items;
}
