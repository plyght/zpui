//! `FileEditor`: the right-pane file editor surface — zeron's editor-mode
//! `FilesSurface` (`files/mod.rs` + `files/preview.rs` + `files/document.rs`)
//! hosting a port of gpui-component's code `Editor`
//! (`base/element.rs`: gutter, active line, indent guides, selections,
//! search highlights, caret; `editor_adapter.rs`: zeron's colors).
//!
//! Layout: the 38px toolbar (file icon, `src › stream.rs` breadcrumb, save
//! status, reveal-in-tree, word wrap), lifecycle banners, then the body —
//! a `uniformList` over *display rows* (one per line, or per wrapped
//! segment with soft wrap), each row painting its gutter number, guides,
//! selection, matches, highlighted text and caret. Only visible rows are
//! laid out, so 30 MB files scroll like 30-line ones. Geist Mono at
//! zeron's metrics: 13px (code size 12.5 × 13/12.5) on a 22px line.
//!
//! Documents load through `WorkspaceFiles`; saves are hash-guarded
//! (`WriteWorkspaceFile` with the loaded content hash) and a conflict, an
//! external modification or a deletion keeps the buffer and shows zeron's
//! banners ("This file changed outside Zeron." Keep Editing / Reload from
//! Disk → "Discard unsaved changes?").
//!
//! ```zig
//! const ed = try cx.newWith(FileEditor, FileEditor.init, .{ files, "src/stream.rs", .{} });
//! div().child(ed)       // toolbar + body, fills its parent
//! ed.read(cx).tabTitle() / .tabIcon() / .hasUnsavedChanges()
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const input = @import("zeron_input");
const zeron_actions = @import("zeron_actions");
const md = @import("zeron_ui_markdown");
const ui = @import("../components/root.zig");
const client = @import("../files/client.zig");
const markdown_preview = @import("../files/markdown_preview.zig");
const image_preview = @import("../files/image_preview.zig");
const proto = @import("../files/protocol.zig");
const core_mod = @import("core.zig");
const wrap_mod = @import("wrap.zig");
const hl = @import("highlight.zig");
const A = @import("actions.zig");
const review = @import("review.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Task = zpui.Task;
const AnyElement = zpui.AnyElement;
const Hsla = zpui.Hsla;
const Pixels = zpui.Pixels;
const Point = zpui.Point(Pixels);
const Bounds = zpui.Bounds(Pixels);
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = zt.Theme;
const EditorCore = core_mod.EditorCore;
const Range = core_mod.Range;
const Selection = core_mod.Selection;
const DisplayMap = wrap_mod.DisplayMap;
const TextInput = input.TextInput;

/// gpui-component `LINE_NUMBER_RIGHT_MARGIN` / `RIGHT_MARGIN`.
pub const line_number_right_margin: f32 = 10;
pub const right_margin: f32 = 10;
/// zeron `EDITOR_TEXT_SIZE` at the default 12.5px code size.
pub const editor_text_ratio: f32 = 13.0 / 12.5;
/// gpui-component keeps three blank rows below the last line.
pub const bottom_margin_rows: usize = 3;
pub const caret_blink_ms: u64 = 500;
pub const caret_width: f32 = 2;
/// Toolbar (zeron `surface_chrome`).
pub const header_height: f32 = zt.layout.titlebar_height;
pub const control_size: f32 = 24;
pub const control_radius: f32 = 6;
pub const icon_size: f32 = 14;
pub const control_gap: f32 = 4;
pub const edge_inset: f32 = 8;

pub const Phase = enum {
    loading,
    ready,
    saving,
    save_failed,
    externally_modified,
    conflict,
    deleted_on_disk,
    /// Text that cannot be edited (too large, mixed endings, outside).
    read_only,
    /// No text to show (binary, unsupported encoding, symlink…).
    unavailable,
    failed,
};

pub const Options = struct {
    soft_wrap: bool = false,
    /// Settings → Files → Autosave (`files_autosave_enabled` / `_delay_ms`).
    autosave: bool = false,
    autosave_delay_ms: u64 = 900,
    /// Force read-only (preview surfaces).
    read_only: bool = false,
    show_header: bool = true,
};

/// The breadcrumb's reveal button (`FilesEvent::RevealFile`).
pub const RevealFile = struct { path: []const u8 };
pub const WordWrapChanged = struct { enabled: bool };
/// Dirty state or phase changed (hosts refresh the tab's unsaved dot).
pub const StateChanged = struct {};
pub const Saved = struct { path: []const u8 };
/// A Markdown preview link opened another workspace document.
pub const OpenPath = struct { path: []const u8 };

const DragUnit = enum { char, word, line };

const ContextMenu = struct { position: Point, active: ?usize = null };

pub const FileEditor = struct {
    gpa: Allocator,
    files: Entity(client.WorkspaceFiles),
    files_sub: zpui.Subscription,
    path: []u8,
    opts: Options,
    phase: Phase = .loading,
    message: ?[]u8 = null,
    read_only_reason: ?proto.ReadOnlyReason = null,
    truncated: bool = false,
    /// The content hash the next save must match on disk.
    expected_hash: ?[]u8 = null,
    checkout_id: ?[]u8 = null,
    encoding: proto.WritableEncoding = .utf8,
    line_ending: proto.WritableLineEnding = .lf,
    saving_version: ?u64 = null,
    reload_confirmation: bool = false,
    read_generation: u64 = 0,
    /// A clean external change is being re-read (keeps selection & scroll).
    silent_reload: bool = false,

    core: EditorCore,
    display: DisplayMap,
    highlights: hl.Highlights,
    highlight_task: Task(hl.HighlightOutcome) = .none,
    rehighlight_timer: Task(void) = .none,
    /// The pending autosave and the edit version it was scheduled for.
    autosave_timer: Task(void) = .none,
    autosave_version: u64 = 0,
    highlightable: bool = false,
    max_line_bytes: usize = 0,
    line_edits: std.ArrayList(core_mod.LineEdit) = .empty,

    focus: zpui.FocusHandle,
    scroll: zpui.UniformListScrollHandle,
    hscroll: zpui.ScrollHandle,
    scroll_x: f32 = 0,
    /// The horizontal offset last written to `hscroll` (a drag changes it).
    bar_x: f32 = 0,
    reveal_cursor: bool = false,
    center_cursor: bool = false,

    // metrics (rem-independent: code sizes are absolute)
    font_size: f32 = 13,
    line_height: f32 = 22,
    char_width: f32 = 7.8,
    measured_font: f32 = 0,
    body_bounds: ?Bounds = null,
    wrap_cols: ?usize = null,

    // pointer
    selecting: bool = false,
    drag_unit: DragUnit = .char,
    drag_origin: Range = .{ .start = 0, .end = 0 },
    drag_pos: ?Point = null,
    drag_task: Task(void) = .none,

    // caret blink
    blink_anchor: u64 = 0,
    blink_task: Task(void) = .none,

    // find / replace
    find_open: bool = false,
    replace_open: bool = false,
    find_input: ?Entity(TextInput) = null,
    replace_input: ?Entity(TextInput) = null,
    find_subs: zpui.Subscriptions = .{},
    // go to line
    goto_open: bool = false,
    goto_input: ?Entity(TextInput) = null,
    goto_sub: ?zpui.Subscription = null,

    context_menu: ?ContextMenu = null,
    /// [motion] The context menu's closing phase (MENU_OUT).
    context_exit: ui.popover.Exit = .{},
    pending_focus: bool = false,
    /// [wiring] A transcript link's `:line[:col]`, applied once the document loads.
    pending_goto: ?struct { line: usize, col: ?usize } = null,
    window_id: zpui.WindowId = undefined,

    /// Markdown documents open rendered (`FileDocument::show_markdown`); the
    /// toolbar toggles back to the code.
    show_markdown: bool = false,
    markdown: ?Entity(markdown_preview.MarkdownPreview) = null,
    markdown_sub: ?zpui.Subscription = null,
    /// Buffer version the preview last parsed.
    markdown_version: ?u64 = null,
    /// Workspace images render instead of the "binary" notice.
    image_view: ?Entity(image_preview.ImagePreview) = null,
    open_path_buf: std.ArrayList(u8) = .empty,

    /// Row layouts computed outside a draw (listeners, IME queries).
    tmp_arena: std.heap.ArenaAllocator,
    scratch: std.ArrayList(u8) = .empty,
    wrap_scratch: std.ArrayList(u8) = .empty,
    row_starts: std.ArrayList(usize) = .empty,
    /// Review comments on this file's lines (`review.zig`).
    review: review.State = .{},

    pub const Events = .{ RevealFile, WordWrapChanged, StateChanged, Saved, OpenPath };

    pub fn init(files: Entity(client.WorkspaceFiles), path: []const u8, opts: Options, cx: *Context(FileEditor)) !FileEditor {
        const gpa = cx.gpa();
        var self: FileEditor = .{
            .gpa = gpa,
            .files = files.retain(cx),
            .files_sub = undefined,
            .path = try gpa.dupe(u8, path),
            .opts = opts,
            .core = .init(gpa),
            .display = .init(gpa),
            .highlights = .init(gpa),
            .focus = cx.focusHandle().tabStop(true),
            .scroll = zpui.UniformListScrollHandle.init(gpa),
            .hscroll = zpui.ScrollHandle.init(gpa),
            .tmp_arena = .init(gpa),
            .show_markdown = markdown_preview.isMarkdown(path),
        };
        self.files_sub = try cx.subscribe(files, onFileChanges);
        self.blink_anchor = cx.app.executor.now();
        files.update(cx, client.WorkspaceFiles.watchFile, .{ path, cx.entityId() });
        files.update(cx, client.WorkspaceFiles.ensureWatch, .{});
        self.startRead(cx);
        review.attach(&self, cx);
        return self;
    }

    pub fn deinit(self: *FileEditor, app: *App) void {
        self.review.deinit(self, app);
        self.files_sub.deinit();
        if (self.markdown_sub) |*sub| sub.deinit();
        if (self.markdown) |m| m.release(app);
        if (self.image_view) |v| v.release(app);
        self.open_path_buf.deinit(self.gpa);
        self.find_subs.deinit(self.gpa);
        if (self.goto_sub) |*s| s.deinit();
        self.highlight_task.cancel();
        self.rehighlight_timer.cancel();
        self.autosave_timer.cancel();
        self.drag_task.cancel();
        self.blink_task.cancel();
        self.files.release(app);
        if (self.find_input) |e| e.release(app);
        if (self.replace_input) |e| e.release(app);
        if (self.goto_input) |e| e.release(app);
        self.focus.release(app);
        self.scroll.release();
        self.hscroll.release();
        self.core.deinit();
        self.display.deinit();
        self.highlights.deinit();
        self.line_edits.deinit(self.gpa);
        self.tmp_arena.deinit();
        self.scratch.deinit(self.gpa);
        self.wrap_scratch.deinit(self.gpa);
        self.row_starts.deinit(self.gpa);
        self.freeOpt(&self.message);
        self.freeOpt(&self.expected_hash);
        self.freeOpt(&self.checkout_id);
        self.gpa.free(self.path);
    }

    fn freeOpt(self: *FileEditor, p: *?[]u8) void {
        if (p.*) |s| self.gpa.free(s);
        p.* = null;
    }

    fn setOpt(self: *FileEditor, p: *?[]u8, v: ?[]const u8) void {
        self.freeOpt(p);
        if (v) |s| p.* = self.gpa.dupe(u8, s) catch null;
    }

    // ---- public API -------------------------------------------------------------------

    pub fn filePath(self: *const FileEditor) []const u8 {
        return self.path;
    }

    /// Tab title: the file name (zeron `tab_title`).
    pub fn tabTitle(self: *const FileEditor) []const u8 {
        const p = std.mem.trimEnd(u8, self.path, "/");
        if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
        return p;
    }

    /// The tab chip icon: the file's polychrome icon (render it with
    /// `md.file_icons.icon(tabIcon(), theme, 14)`).
    pub fn tabIcon(self: *const FileEditor) []const u8 {
        return self.path;
    }

    pub fn hasUnsavedChanges(self: *const FileEditor) bool {
        return switch (self.phase) {
            .loading, .unavailable, .failed => false,
            else => self.core.isDirty(),
        };
    }

    pub fn isReadOnly(self: *const FileEditor) bool {
        return self.core.read_only;
    }

    pub fn softWrap(self: *const FileEditor) bool {
        return self.opts.soft_wrap;
    }

    /// Focus the editor body (deferred until the document has loaded).
    pub fn focusEditor(self: *FileEditor, window: *Window) void {
        if (self.phase == .loading) {
            self.pending_focus = true;
            return;
        }
        window.focus(self.focus);
    }

    pub fn setReadOnly(self: *FileEditor, read_only: bool, cx: *Context(FileEditor)) void {
        self.opts.read_only = read_only;
        self.core.read_only = read_only or self.phase == .read_only;
        cx.notify();
    }

    pub fn setSoftWrap(self: *FileEditor, enabled: bool, cx: *Context(FileEditor)) void {
        if (self.opts.soft_wrap == enabled) return;
        self.opts.soft_wrap = enabled;
        self.scroll_x = 0;
        self.rebuildDisplay();
        self.reveal_cursor = true;
        cx.emit(WordWrapChanged{ .enabled = enabled });
        cx.notify();
    }

    /// Text contents (copy; caller frees).
    pub fn text(self: *FileEditor, gpa: Allocator) ![]u8 {
        return self.core.buffer.toOwned(gpa);
    }

    /// Jump to a 1-based line (and optional column) and center it
    /// (zeron `navigate_to_line`).
    pub fn goToLine(self: *FileEditor, line_1: usize, col_1: ?usize, cx: *Context(FileEditor)) void {
        // Line navigation shows the code (`pending_line_navigation`).
        self.show_markdown = false;
        const line = @min(line_1 -| 1, self.core.buffer.lineCount() - 1);
        const r = self.core.buffer.lineRange(line);
        const col = if (col_1) |c| @min(c -| 1, r.end - r.start) else 0;
        self.core.moveTo(r.start + col);
        self.center_cursor = true;
        self.afterMove(cx);
    }

    /// [wiring] `goToLine` now if loaded, else as soon as the read lands.
    pub fn goToLineWhenLoaded(self: *FileEditor, line_1: usize, col_1: ?usize, cx: *Context(FileEditor)) void {
        if (self.phase == .loading) {
            self.pending_goto = .{ .line = line_1, .col = col_1 };
            self.show_markdown = false;
            return;
        }
        self.goToLine(line_1, col_1, cx);
    }

    /// Select a byte range and scroll it into view.
    pub fn selectRange(self: *FileEditor, start: usize, end: usize, cx: *Context(FileEditor)) void {
        self.core.setSelection(.{ .anchor = start, .head = end });
        self.center_cursor = true;
        self.afterMove(cx);
    }

    pub fn save(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.startSave(cx);
    }

    /// The file moved (explorer rename / move): keep the buffer, follow the path.
    pub fn setPath(self: *FileEditor, new_path: []const u8, cx: *Context(FileEditor)) void {
        if (std.mem.eql(u8, new_path, self.path)) return;
        self.files.update(cx, client.WorkspaceFiles.unwatchFile, .{ self.path, cx.entityId() });
        const was_markdown = markdown_preview.isMarkdown(self.path);
        review.renamed(self, self.path, new_path, cx);
        self.gpa.free(self.path);
        self.path = self.gpa.dupe(u8, new_path) catch @panic("OOM");
        if (was_markdown != markdown_preview.isMarkdown(self.path)) self.show_markdown = !was_markdown;
        if (self.markdown) |m| m.update(cx, markdown_preview.MarkdownPreview.setPath, .{self.path});
        self.markdown_version = null;
        if (self.image_view) |v| {
            if (image_preview.isImage(self.path)) v.update(cx, image_preview.ImagePreview.setPath, .{self.path}) else {
                v.release(cx);
                self.image_view = null;
            }
        }
        self.files.update(cx, client.WorkspaceFiles.watchFile, .{ self.path, cx.entityId() });
        self.highlightable = hl.supported(self.path, null) and self.core.len() <= hl.max_source_bytes;
        self.highlights.clear();
        self.scheduleHighlight(0, cx);
        cx.emit(StateChanged{});
        cx.notify();
    }

    /// The file was deleted by the explorer: keep the buffer for recovery.
    pub fn markDeleted(self: *FileEditor, cx: *Context(FileEditor)) void {
        if (self.image_view) |v| v.update(cx, image_preview.ImagePreview.deleted, .{});
        if (self.phase == .loading or self.phase == .failed or self.phase == .unavailable) return;
        self.phase = .deleted_on_disk;
        cx.emit(StateChanged{});
        cx.notify();
    }

    // ---- document lifecycle ---------------------------------------------------------------

    fn startRead(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.read_generation += 1;
        self.files.read(cx).readFile(cx, self.path, onRead);
    }

    fn onRead(self: *FileEditor, res_in: client.ReadResult, cx: *Context(FileEditor)) void {
        var res = res_in;
        defer res.deinit();
        const silent = self.silent_reload;
        self.silent_reload = false;
        if (res.err()) |e| {
            if (silent) return;
            self.phase = .failed;
            self.setOpt(&self.message, if (std.mem.eql(u8, e, "file not found")) "File not found." else e);
            cx.emit(StateChanged{});
            cx.notify();
            return;
        }
        const file = res.file() orelse return;
        if (silent and self.core.isDirty()) {
            // The user typed while the clean reload was in flight.
            self.phase = .externally_modified;
            cx.notify();
            return;
        }
        self.setOpt(&self.expected_hash, file.contentHash);
        self.setOpt(&self.checkout_id, file.checkoutId);
        self.encoding = if (file.encoding == .utf8Bom) .utf8Bom else .utf8;
        self.line_ending = if (file.lineEnding == .crlf) .crlf else .lf;
        self.read_only_reason = file.readOnlyReason;
        self.truncated = file.truncated;
        const owned = res.takeText() orelse {
            self.phase = .unavailable;
            self.setOpt(&self.message, readOnlyMessage(file.readOnlyReason));
            cx.emit(StateChanged{});
            cx.notify();
            return;
        };
        if (silent) {
            self.core.reloadKeepingSelection(owned) catch @panic("OOM");
        } else {
            self.core.load(owned) catch @panic("OOM");
        }
        self.core.line_edits.clearRetainingCapacity();
        const ro = file.readOnlyReason != null or file.truncated;
        self.phase = if (ro) .read_only else .ready;
        self.core.read_only = ro or self.opts.read_only;
        self.freeOpt(&self.message);
        self.scanLineLengths();
        self.rebuildDisplay();
        self.highlights.clear();
        self.highlightable = hl.supported(self.path, null) and self.core.len() <= hl.max_source_bytes;
        self.scheduleHighlight(0, cx);
        if (self.find_open) self.core.search.computed_for = null;
        if (!silent) if (self.pending_goto) |g| {
            self.pending_goto = null;
            self.goToLine(g.line, g.col, cx);
        };
        cx.emit(StateChanged{});
        cx.notify();
    }

    fn scanLineLengths(self: *FileEditor) void {
        var max: usize = 0;
        var cur: usize = 0;
        var it = self.core.buffer.chunksIn(0, self.core.len());
        while (it.next()) |chunk| {
            var i: usize = 0;
            while (std.mem.indexOfScalarPos(u8, chunk, i, '\n')) |nl| {
                cur += nl - i;
                max = @max(max, cur);
                cur = 0;
                i = nl + 1;
            }
            cur += chunk.len - i;
        }
        self.max_line_bytes = @max(max, cur);
    }

    fn onFileChanges(self: *FileEditor, _: Entity(client.WorkspaceFiles), ev: *const client.FileChangesEvent, cx: *Context(FileEditor)) void {
        if (ev.resync) return self.onExternalModify(cx);
        for (ev.changes) |ch| {
            if (ch.kind == .renamed) {
                if (ch.oldPath) |old| if (std.mem.eql(u8, old, self.path)) {
                    self.files.update(cx, client.WorkspaceFiles.unwatchFile, .{ self.path, cx.entityId() });
                    self.gpa.free(self.path);
                    self.path = self.gpa.dupe(u8, ch.path) catch @panic("OOM");
                    self.files.update(cx, client.WorkspaceFiles.watchFile, .{ self.path, cx.entityId() });
                    cx.emit(StateChanged{});
                    cx.notify();
                    return;
                };
                continue;
            }
            if (!std.mem.eql(u8, ch.path, self.path)) continue;
            switch (ch.kind) {
                .removed => {
                    if (self.phase == .loading or self.phase == .failed) return;
                    self.phase = .deleted_on_disk;
                    cx.emit(StateChanged{});
                    cx.notify();
                },
                else => self.onExternalModify(cx),
            }
        }
    }

    fn onExternalModify(self: *FileEditor, cx: *Context(FileEditor)) void {
        switch (self.phase) {
            .saving, .loading => return,
            .failed, .unavailable => return self.startRead(cx),
            else => {},
        }
        if (self.core.isDirty()) {
            self.phase = .externally_modified;
            cx.emit(StateChanged{});
            cx.notify();
            return;
        }
        // Clean: adopt the disk contents, keeping the caret and scroll.
        self.silent_reload = true;
        self.startRead(cx);
    }

    fn canSave(self: *const FileEditor) bool {
        if (self.core.read_only) return false;
        return switch (self.phase) {
            .ready, .save_failed => true,
            else => false,
        };
    }

    fn startSave(self: *FileEditor, cx: *Context(FileEditor)) void {
        if (!self.canSave()) return;
        if (!self.core.isDirty() and self.phase == .ready) return;
        const hash = self.expected_hash orelse return;
        const snapshot = self.core.buffer.toOwned(self.gpa) catch return;
        defer self.gpa.free(snapshot);
        self.saving_version = self.core.currentVersion();
        self.core.breakUndoRun();
        self.phase = .saving;
        self.files.read(cx).writeFile(cx, .{
            .path = self.path,
            .text = snapshot,
            .expected_hash = hash,
            .expected_checkout = self.checkout_id orelse "",
            .encoding = self.encoding,
            .line_ending = self.line_ending,
        }, onWritten);
        cx.notify();
    }

    fn onWritten(self: *FileEditor, res: client.WriteResult, cx: *Context(FileEditor)) void {
        defer res.deinit();
        const version = self.saving_version orelse return;
        self.saving_version = null;
        if (res.err) |e| {
            self.phase = .save_failed;
            self.setOpt(&self.message, e);
        } else if (res.value) |outcome| switch (outcome) {
            .written => |w| {
                self.setOpt(&self.expected_hash, w.contentHash);
                self.core.markSaved(version);
                self.phase = .ready;
                self.freeOpt(&self.message);
                self.files.update(cx, client.WorkspaceFiles.noteOwnWrite, .{ self.path, null });
                cx.emit(Saved{ .path = self.path });
            },
            .conflict => |c| {
                self.phase = if (c.reason == .deleted) .deleted_on_disk else .conflict;
            },
        };
        review.onSaveOutcome(self, cx);
        cx.emit(StateChanged{});
        cx.notify();
    }

    /// "Keep Editing": adopt the disk's current hash so the next save
    /// overwrites it with this buffer (zeron `keep_external_edits`).
    fn keepEditing(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.files.read(cx).readFile(cx, self.path, onKeepRead);
    }

    pub fn keepEditingForTest(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.keepEditing(cx);
    }

    fn onKeepRead(self: *FileEditor, res_in: client.ReadResult, cx: *Context(FileEditor)) void {
        var res = res_in;
        defer res.deinit();
        if (res.file()) |f| self.setOpt(&self.expected_hash, f.contentHash);
        self.phase = if (self.core.read_only) .read_only else .ready;
        self.reload_confirmation = false;
        cx.emit(StateChanged{});
        cx.notify();
    }

    fn requestReload(self: *FileEditor, cx: *Context(FileEditor)) void {
        if (self.core.isDirty()) {
            self.reload_confirmation = true;
            cx.notify();
            return;
        }
        self.confirmReload(cx);
    }

    fn confirmReload(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.reload_confirmation = false;
        self.silent_reload = false;
        self.phase = .loading;
        self.startRead(cx);
        cx.notify();
    }

    // ---- display / highlight caches ---------------------------------------------------

    fn lineTextFor(self: *FileEditor, line: usize) []const u8 {
        return self.core.buffer.lineText(line, &self.wrap_scratch, self.gpa);
    }

    fn rebuildDisplay(self: *FileEditor) void {
        const cols: ?usize = if (self.opts.soft_wrap) self.wrap_cols orelse null else null;
        self.display.rebuild(cols, self.core.buffer.lineCount(), self, lineTextFor);
    }

    /// Fold pending core line edits into the wrap map and highlight map.
    fn syncLineEdits(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.line_edits.clearRetainingCapacity();
        self.core.takeLineEdits(&self.line_edits, self.gpa);
        if (self.line_edits.items.len == 0) return;
        review.applyEdits(self, self.line_edits.items, cx);
        for (self.line_edits.items) |e| {
            self.display.applyLineEdit(e.line, e.removed, e.added, self, lineTextFor);
            if (e.removed == 1 and e.added == 1)
                self.highlights.applyInlineEdit(e.line, e.col, e.old_len, e.new_len)
            else
                self.highlights.applyLineEdit(e.line, e.removed, e.added);
            for (0..e.added) |k| self.max_line_bytes = @max(self.max_line_bytes, self.core.buffer.lineLen(e.line + k));
        }
        self.highlightable = hl.supported(self.path, null) and self.core.len() <= hl.max_source_bytes;
        self.scheduleHighlight(hl.rehighlight_delay_ms, cx);
    }

    /// `can_autosave`: savable and plainly ready (no conflict / failure / in-flight save).
    fn canAutosave(self: *const FileEditor) bool {
        return self.canSave() and self.phase == .ready and self.saving_version == null;
    }

    /// `schedule_autosave`: save `autosave_delay_ms` after the last edit,
    /// only if nothing changed in between and the document can still autosave.
    fn scheduleAutosave(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.autosave_timer.cancel();
        self.autosave_timer = .none;
        if (!self.opts.autosave or !self.canAutosave() or !self.core.isDirty()) return;
        self.autosave_version = self.core.currentVersion();
        self.autosave_timer = cx.timer(self.opts.autosave_delay_ms * std.time.ns_per_ms, onAutosaveTimer) catch .none;
    }

    fn onAutosaveTimer(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.autosave_timer.detach();
        self.autosave_timer = .none;
        const still_current = self.opts.autosave and self.canAutosave() and self.core.currentVersion() == self.autosave_version;
        if (still_current) self.startSave(cx);
    }

    /// Settings → Files changed (`set_autosave` / delay) for an open editor.
    pub fn setAutosave(self: *FileEditor, enabled: bool, delay_ms: u64, cx: *Context(FileEditor)) void {
        self.opts.autosave = enabled;
        self.opts.autosave_delay_ms = delay_ms;
        if (!enabled) {
            self.autosave_timer.cancel();
            self.autosave_timer = .none;
        } else self.scheduleAutosave(cx);
    }

    fn scheduleHighlight(self: *FileEditor, delay_ms: u64, cx: *Context(FileEditor)) void {
        if (!self.highlightable) return;
        self.rehighlight_timer.cancel();
        self.rehighlight_timer = cx.timer(delay_ms * std.time.ns_per_ms, onRehighlightTimer) catch .none;
    }

    fn onRehighlightTimer(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.rehighlight_timer.detach();
        self.rehighlight_timer = .none;
        if (!self.highlightable) return;
        self.highlight_task.cancel();
        const source = self.core.buffer.toOwned(self.gpa) catch return;
        const path = self.gpa.dupe(u8, self.path) catch {
            self.gpa.free(source);
            return;
        };
        self.highlight_task = cx.spawn(hl.HighlightJob{ .gpa = self.gpa, .source = source, .path = path, .generation = self.highlights.generation }, onHighlighted) catch .none;
    }

    fn onHighlighted(self: *FileEditor, out: hl.HighlightOutcome, cx: *Context(FileEditor)) void {
        self.highlight_task.detach();
        self.highlight_task = .none;
        const doc = out.doc orelse return;
        if (out.generation != self.highlights.generation) {
            var d = doc;
            d.deinit(self.gpa);
            return;
        }
        self.highlights.install(doc, self.core.buffer.lineCount());
        cx.notify();
    }

    // ---- bookkeeping ------------------------------------------------------------------------

    fn now(_: *const FileEditor, cx: anytype) u64 {
        return cx.app.executor.now();
    }

    fn afterEdit(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.syncLineEdits(cx);
        review.afterEdit(self, cx);
        self.scheduleAutosave(cx);
        self.reveal_cursor = true;
        self.blink_anchor = self.now(cx);
        self.closeContextMenu(cx);
        cx.emit(StateChanged{});
        cx.notify();
    }

    fn afterMove(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.reveal_cursor = true;
        self.blink_anchor = self.now(cx);
        self.closeContextMenu(cx);
        cx.notify();
    }

    fn edit(self: *FileEditor, changed: Allocator.Error!bool, cx: *Context(FileEditor)) void {
        if (changed catch @panic("OOM")) self.afterEdit(cx) else self.afterMove(cx);
    }

    // ---- geometry ---------------------------------------------------------------------------

    fn gutterWidth(self: *const FileEditor) f32 {
        const n = self.core.buffer.lineCount();
        const digits = std.math.log10_int(@max(n, 1)) + 2;
        return @as(f32, @floatFromInt(digits)) * self.char_width + line_number_right_margin;
    }

    /// The gutter's width in px (comment overlays sit over it).
    pub fn gutterWidthPx(self: *const FileEditor) f32 {
        return self.gutterWidth();
    }

    fn lineNumberLen(self: *const FileEditor) usize {
        return std.math.log10_int(@max(self.core.buffer.lineCount(), 1)) + 2;
    }

    pub const RowInfo = struct {
        line: usize,
        sub: usize,
        /// Buffer offsets of the row's segment (end excludes the newline).
        start: usize,
        end: usize,
        last_sub: bool,
        /// Display text (tabs expanded), frame-arena backed when expanded.
        text: []const u8,
        /// display byte → segment byte (len text.len + 1), when tabs expanded.
        map: ?[]const usize,

        fn toDisplay(r: RowInfo, rel: usize) usize {
            const m = r.map orelse return rel;
            // First display index whose source is >= rel.
            var lo: usize = 0;
            var hi: usize = m.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (m[mid] < rel) lo = mid + 1 else hi = mid;
            }
            return @min(lo, r.text.len);
        }

        fn toBuffer(r: RowInfo, d: usize) usize {
            const m = r.map orelse return d;
            return m[@min(d, m.len - 1)];
        }
    };

    fn rowCount(self: *FileEditor) usize {
        return self.display.rowCount();
    }

    /// Resolve display row `row` (allocates expanded text in `a`).
    fn rowInfo(self: *FileEditor, row: usize, a: Allocator) ?RowInfo {
        if (row >= self.rowCount()) return null;
        const pos = self.display.lineForRow(row);
        const lr = self.core.buffer.lineRange(pos.line);
        var seg_start = lr.start;
        var seg_end = lr.end;
        var last_sub = true;
        if (self.display.wraps() and self.display.rowsOfLine(pos.line) > 1) {
            const line_text = self.core.buffer.slice(lr.start, lr.end, &self.wrap_scratch, self.gpa);
            self.display.rowStarts(line_text, &self.row_starts, self.gpa);
            const starts = self.row_starts.items;
            const sub = @min(pos.sub, starts.len - 1);
            seg_start = lr.start + starts[sub];
            seg_end = if (sub + 1 < starts.len) lr.start + starts[sub + 1] else lr.end;
            last_sub = sub + 1 >= starts.len;
        }
        const raw = self.core.buffer.slice(seg_start, seg_end, &self.scratch, self.gpa);
        var info: RowInfo = .{ .line = pos.line, .sub = pos.sub, .start = seg_start, .end = seg_end, .last_sub = last_sub, .text = raw, .map = null };
        if (std.mem.indexOfScalar(u8, raw, '\t') != null) {
            var out: std.ArrayList(u8) = .empty;
            var map: std.ArrayList(usize) = .empty;
            for (raw, 0..) |ch, i| {
                if (ch == '\t') {
                    for (0..wrap_mod.tab_width) |_| {
                        out.append(a, ' ') catch {};
                        map.append(a, i) catch {};
                    }
                } else {
                    out.append(a, ch) catch {};
                    map.append(a, i) catch {};
                }
            }
            map.append(a, raw.len) catch {};
            info.text = out.items;
            info.map = map.items;
        } else {
            info.text = a.dupe(u8, raw) catch raw;
        }
        return info;
    }

    fn rowOfOffset(self: *FileEditor, offset: usize) usize {
        const line = self.core.buffer.lineOf(offset);
        const first = self.display.firstRowOfLine(line);
        if (!self.display.wraps() or self.display.rowsOfLine(line) <= 1) return first;
        const lr = self.core.buffer.lineRange(line);
        const line_text = self.core.buffer.slice(lr.start, lr.end, &self.wrap_scratch, self.gpa);
        self.display.rowStarts(line_text, &self.row_starts, self.gpa);
        const rel = offset - lr.start;
        var sub: usize = 0;
        for (self.row_starts.items, 0..) |s, i| {
            if (s <= rel) sub = i;
        }
        // A caret at a wrap boundary belongs to the next row.
        return first + sub;
    }

    fn font(self: *const FileEditor, window: *Window, theme: *const Theme) zpui.text.Font {
        _ = self;
        var f = window.textStyle().font();
        f.family = theme.font_mono;
        f.weight = zpui.text.weight.normal;
        f.style = .normal;
        return f;
    }

    fn ensureMetrics(self: *FileEditor, window: *Window, theme: *const Theme) void {
        const size = theme.code_font_size * editor_text_ratio;
        if (self.measured_font == size) return;
        self.font_size = size;
        self.line_height = @round(size + 8.5);
        const sample = "0000000000";
        const run: zpui.text.TextRun = .{ .len = sample.len, .font = self.font(window, theme), .color = theme.text };
        if (window.text_system.shapeLine(sample, size, &.{run}, null)) |shaped| {
            defer shaped.deinit(self.gpa);
            if (shaped.width() > 0) self.char_width = shaped.width() / 10.0;
        } else |_| {
            self.char_width = size * 0.6;
        }
        self.measured_font = size;
    }

    /// Shaped display text of a row (caller deinit's).
    fn shapeRow(self: *FileEditor, info: RowInfo, window: *Window, theme: *const Theme) ?zpui.text.ShapedLine {
        const run: zpui.text.TextRun = .{ .len = info.text.len, .font = self.font(window, theme), .color = theme.text };
        const runs: []const zpui.text.TextRun = if (info.text.len == 0) &.{} else &.{run};
        return window.text_system.shapeLine(info.text, self.font_size, runs, null) catch null;
    }

    fn tmpAlloc(self: *FileEditor) Allocator {
        _ = self.tmp_arena.reset(.retain_capacity);
        return self.tmp_arena.allocator();
    }

    fn textOriginX(self: *const FileEditor, bounds: Bounds) f32 {
        return bounds.origin.x + self.gutterWidth() - self.scroll_x;
    }

    /// Buffer offset under a window position.
    fn offsetAt(self: *FileEditor, pos: Point, window: *Window) usize {
        const b = self.body_bounds orelse return self.core.cursor();
        const theme = ui.theme.get(window.app);
        const y = pos.y - b.origin.y - self.scroll.offset().y;
        if (y < 0) return 0;
        const row_f = @floor(y / self.line_height);
        const total = self.rowCount();
        if (row_f >= @as(f32, @floatFromInt(total))) return self.core.len();
        const row: usize = @intFromFloat(row_f);
        const a = self.tmpAlloc();
        const info = self.rowInfo(row, a) orelse return self.core.len();
        const x = pos.x - self.textOriginX(b);
        if (x <= 0) return info.start;
        const shaped = self.shapeRow(info, window, theme) orelse return info.start;
        defer shaped.deinit(self.gpa);
        const d = shaped.closestIndexForX(x);
        var off = info.start + info.toBuffer(d);
        // At a wrap boundary the click lands on the row's own end, not the next row's start.
        if (!info.last_sub and off >= info.end and info.end > info.start) off = info.end -| 0;
        return self.core.clampBoundary(@min(off, info.end));
    }

    /// Content-x of the caret within its row (for vertical moves / reveal).
    fn caretX(self: *FileEditor, offset: usize, window: *Window) f32 {
        const theme = ui.theme.get(window.app);
        const row = self.rowOfOffset(offset);
        const a = self.tmpAlloc();
        const info = self.rowInfo(row, a) orelse return 0;
        const shaped = self.shapeRow(info, window, theme) orelse return 0;
        defer shaped.deinit(self.gpa);
        return shaped.xForIndex(info.toDisplay(offset -| info.start));
    }

    fn offsetForRowX(self: *FileEditor, row: usize, x: f32, window: *Window) usize {
        const theme = ui.theme.get(window.app);
        const a = self.tmpAlloc();
        const info = self.rowInfo(row, a) orelse return self.core.len();
        const shaped = self.shapeRow(info, window, theme) orelse return info.start;
        defer shaped.deinit(self.gpa);
        const d = shaped.closestIndexForX(x);
        return self.core.clampBoundary(@min(info.start + info.toBuffer(d), info.end));
    }

    fn vertical(self: *FileEditor, rows: isize, select: bool, window: *Window, cx: *Context(FileEditor)) void {
        const head = self.core.sel.head;
        if (!select and !self.core.sel.isEmpty()) {
            // Collapse toward the motion first, like gpui-component.
            const edge = if (rows < 0) self.core.sel.start() else self.core.sel.end();
            self.core.moveTo(edge);
        }
        const x = self.core.preferred_x orelse self.caretX(self.core.sel.head, window);
        const row = self.rowOfOffset(self.core.sel.head);
        const total = self.rowCount();
        const target_i: isize = @as(isize, @intCast(row)) + rows;
        var target: usize = undefined;
        if (target_i < 0) {
            target = 0;
            if (select) self.core.selectTo(0) else self.core.moveTo(0);
        } else if (target_i >= @as(isize, @intCast(total))) {
            if (select) self.core.selectTo(self.core.len()) else self.core.moveTo(self.core.len());
        } else {
            target = @intCast(target_i);
            const off = self.offsetForRowX(target, x, window);
            if (select) self.core.selectTo(off) else self.core.moveTo(off);
        }
        _ = head;
        self.core.preferred_x = x;
        self.afterMove(cx);
    }

    fn pageRows(self: *const FileEditor) isize {
        const b = self.body_bounds orelse return 20;
        return @max(1, @as(isize, @intFromFloat(@floor(b.size.height / self.line_height))) - 1);
    }

    // ---- actions ----------------------------------------------------------------------------

    fn motion(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.core.preferred_x = null;
        self.afterMove(cx);
    }

    fn aLeft(self: *FileEditor, _: *const A.Left, _: *Window, cx: *Context(FileEditor)) void {
        self.core.left(false);
        self.motion(cx);
    }
    fn aRight(self: *FileEditor, _: *const A.Right, _: *Window, cx: *Context(FileEditor)) void {
        self.core.right(false);
        self.motion(cx);
    }
    fn aSelectLeft(self: *FileEditor, _: *const A.SelectLeft, _: *Window, cx: *Context(FileEditor)) void {
        self.core.left(true);
        self.motion(cx);
    }
    fn aSelectRight(self: *FileEditor, _: *const A.SelectRight, _: *Window, cx: *Context(FileEditor)) void {
        self.core.right(true);
        self.motion(cx);
    }
    fn aUp(self: *FileEditor, _: *const A.Up, w: *Window, cx: *Context(FileEditor)) void {
        self.vertical(-1, false, w, cx);
    }
    fn aDown(self: *FileEditor, _: *const A.Down, w: *Window, cx: *Context(FileEditor)) void {
        self.vertical(1, false, w, cx);
    }
    fn aSelectUp(self: *FileEditor, _: *const A.SelectUp, w: *Window, cx: *Context(FileEditor)) void {
        self.vertical(-1, true, w, cx);
    }
    fn aSelectDown(self: *FileEditor, _: *const A.SelectDown, w: *Window, cx: *Context(FileEditor)) void {
        self.vertical(1, true, w, cx);
    }
    fn aPageUp(self: *FileEditor, _: *const A.PageUp, w: *Window, cx: *Context(FileEditor)) void {
        self.vertical(-self.pageRows(), false, w, cx);
    }
    fn aPageDown(self: *FileEditor, _: *const A.PageDown, w: *Window, cx: *Context(FileEditor)) void {
        self.vertical(self.pageRows(), false, w, cx);
    }
    fn aSelectPageUp(self: *FileEditor, _: *const A.SelectPageUp, w: *Window, cx: *Context(FileEditor)) void {
        self.vertical(-self.pageRows(), true, w, cx);
    }
    fn aSelectPageDown(self: *FileEditor, _: *const A.SelectPageDown, w: *Window, cx: *Context(FileEditor)) void {
        self.vertical(self.pageRows(), true, w, cx);
    }
    fn aWordLeft(self: *FileEditor, _: *const A.WordLeft, _: *Window, cx: *Context(FileEditor)) void {
        self.core.wordLeft(false);
        self.motion(cx);
    }
    fn aWordRight(self: *FileEditor, _: *const A.WordRight, _: *Window, cx: *Context(FileEditor)) void {
        self.core.wordRight(false);
        self.motion(cx);
    }
    fn aSelectWordLeft(self: *FileEditor, _: *const A.SelectWordLeft, _: *Window, cx: *Context(FileEditor)) void {
        self.core.wordLeft(true);
        self.motion(cx);
    }
    fn aSelectWordRight(self: *FileEditor, _: *const A.SelectWordRight, _: *Window, cx: *Context(FileEditor)) void {
        self.core.wordRight(true);
        self.motion(cx);
    }
    fn aHome(self: *FileEditor, _: *const A.Home, _: *Window, cx: *Context(FileEditor)) void {
        self.core.home(false);
        self.motion(cx);
    }
    fn aEnd(self: *FileEditor, _: *const A.End, _: *Window, cx: *Context(FileEditor)) void {
        self.core.end(false);
        self.motion(cx);
    }
    fn aSelectHome(self: *FileEditor, _: *const A.SelectHome, _: *Window, cx: *Context(FileEditor)) void {
        self.core.home(true);
        self.motion(cx);
    }
    fn aSelectEnd(self: *FileEditor, _: *const A.SelectEnd, _: *Window, cx: *Context(FileEditor)) void {
        self.core.end(true);
        self.motion(cx);
    }
    fn aDocStart(self: *FileEditor, _: *const A.DocStart, _: *Window, cx: *Context(FileEditor)) void {
        self.core.docStart(false);
        self.motion(cx);
    }
    fn aDocEnd(self: *FileEditor, _: *const A.DocEnd, _: *Window, cx: *Context(FileEditor)) void {
        self.core.docEnd(false);
        self.motion(cx);
    }
    fn aSelectDocStart(self: *FileEditor, _: *const A.SelectDocStart, _: *Window, cx: *Context(FileEditor)) void {
        self.core.docStart(true);
        self.motion(cx);
    }
    fn aSelectDocEnd(self: *FileEditor, _: *const A.SelectDocEnd, _: *Window, cx: *Context(FileEditor)) void {
        self.core.docEnd(true);
        self.motion(cx);
    }
    /// An Edit menu verb (`From`, a composer action) run as the editor's own `To`.
    fn editMenuVerb(comptime From: type, comptime To: type, comptime f: fn (*FileEditor, *const To, *Window, *Context(FileEditor)) void) fn (*FileEditor, *const From, *Window, *Context(FileEditor)) void {
        return struct {
            fn g(self: *FileEditor, _: *const From, w: *Window, cx: *Context(FileEditor)) void {
                f(self, &To{}, w, cx);
            }
        }.g;
    }

    fn aSelectAll(self: *FileEditor, _: *const A.SelectAll, _: *Window, cx: *Context(FileEditor)) void {
        self.core.selectAll();
        self.afterMove(cx);
    }
    fn aBackspace(self: *FileEditor, _: *const A.Backspace, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.backspace(self.now(cx)), cx);
    }
    fn aDelete(self: *FileEditor, _: *const A.Delete, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.deleteForward(self.now(cx)), cx);
    }
    fn aDeleteWordLeft(self: *FileEditor, _: *const A.DeleteWordLeft, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.deleteWordLeft(self.now(cx)), cx);
    }
    fn aDeleteWordRight(self: *FileEditor, _: *const A.DeleteWordRight, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.deleteWordRight(self.now(cx)), cx);
    }
    fn aDeleteToLineStart(self: *FileEditor, _: *const A.DeleteToLineStart, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.deleteToLineStart(self.now(cx)), cx);
    }
    fn aDeleteToLineEnd(self: *FileEditor, _: *const A.DeleteToLineEnd, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.deleteToLineEnd(self.now(cx)), cx);
    }
    fn aEnter(self: *FileEditor, _: *const A.Enter, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.newline(self.now(cx)), cx);
    }
    fn aIndentInline(self: *FileEditor, _: *const A.IndentInline, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.indent(false, self.now(cx)), cx);
    }
    fn aOutdentInline(self: *FileEditor, _: *const A.OutdentInline, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.outdent(false, self.now(cx)), cx);
    }
    fn aIndent(self: *FileEditor, _: *const A.Indent, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.indent(true, self.now(cx)), cx);
    }
    fn aOutdent(self: *FileEditor, _: *const A.Outdent, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.outdent(true, self.now(cx)), cx);
    }
    fn aUndo(self: *FileEditor, _: *const A.Undo, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.undo(), cx);
    }
    fn aRedo(self: *FileEditor, _: *const A.Redo, _: *Window, cx: *Context(FileEditor)) void {
        self.edit(self.core.redo(), cx);
    }
    fn aCopy(self: *FileEditor, _: *const A.Copy, _: *Window, cx: *Context(FileEditor)) void {
        self.copySelection(cx, false);
    }
    fn aCut(self: *FileEditor, _: *const A.Cut, _: *Window, cx: *Context(FileEditor)) void {
        self.copySelection(cx, true);
    }
    fn aPaste(self: *FileEditor, _: *const A.Paste, _: *Window, cx: *Context(FileEditor)) void {
        self.paste(cx);
    }
    fn aSave(self: *FileEditor, _: *const A.Save, _: *Window, cx: *Context(FileEditor)) void {
        self.startSave(cx);
    }
    fn aToggleWrap(self: *FileEditor, _: *const A.ToggleSoftWrap, _: *Window, cx: *Context(FileEditor)) void {
        self.setSoftWrap(!self.opts.soft_wrap, cx);
    }
    fn aEscape(self: *FileEditor, _: *const A.Escape, _: *Window, cx: *Context(FileEditor)) void {
        if (self.find_open) return self.closeFind(cx);
        if (!self.core.sel.isEmpty()) {
            self.core.moveTo(self.core.sel.head);
            self.afterMove(cx);
            return;
        }
        cx.propagate();
    }

    fn copySelection(self: *FileEditor, cx: *Context(FileEditor), cut: bool) void {
        var r = self.core.sel.range();
        if (r.isEmpty()) {
            // Like most editors: copy / cut the whole line without a selection.
            r = self.core.lineRangeWithNewline(self.core.cursor());
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        self.core.buffer.appendRange(r.start, r.end, &out, self.gpa) catch return;
        input.text_input.writeClipboard(cx.app, out.items);
        if (cut and !self.core.read_only) {
            self.core.breakUndoRun();
            self.edit(self.core.deleteRange(r, .atomic, self.now(cx)), cx);
            self.core.breakUndoRun();
        }
    }

    fn paste(self: *FileEditor, cx: *Context(FileEditor)) void {
        if (self.core.read_only) return;
        const clip = input.text_input.readClipboard(cx.app, self.gpa) orelse return;
        defer self.gpa.free(clip);
        // Normalize CRLF from the clipboard.
        const normalized = std.mem.replaceOwned(u8, self.gpa, clip, "\r\n", "\n") catch return;
        defer self.gpa.free(normalized);
        self.core.breakUndoRun();
        self.edit(self.core.insertText(normalized, .atomic, self.now(cx)), cx);
        self.core.breakUndoRun();
    }

    // ---- pointer ------------------------------------------------------------------------------

    fn onMouseDown(self: *FileEditor, ev: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(FileEditor)) void {
        window.focus(self.focus);
        self.closeContextMenu(cx);
        const off = self.offsetAt(ev.position, window);
        self.core.preferred_x = null;
        if (ev.click_count >= 3) {
            const r = self.core.lineRangeWithNewline(off);
            self.core.setSelection(.{ .anchor = r.start, .head = r.end });
            self.drag_unit = .line;
            self.drag_origin = r;
        } else if (ev.click_count == 2) {
            const r = self.core.wordRangeAt(off);
            self.core.setSelection(.{ .anchor = r.start, .head = r.end });
            self.drag_unit = .word;
            self.drag_origin = r;
        } else if (ev.modifiers.shift) {
            self.core.selectTo(off);
            self.drag_unit = .char;
            self.drag_origin = .{ .start = self.core.sel.anchor, .end = self.core.sel.anchor };
        } else {
            self.core.moveTo(off);
            self.drag_unit = .char;
            self.drag_origin = .{ .start = off, .end = off };
        }
        self.selecting = true;
        self.drag_pos = ev.position;
        self.afterMove(cx);
    }

    fn dragTo(self: *FileEditor, pos: Point, window: *Window) void {
        const off = self.offsetAt(pos, window);
        switch (self.drag_unit) {
            .char => self.core.selectTo(off),
            .word, .line => {
                const unit = if (self.drag_unit == .word) self.core.wordRangeAt(off) else self.core.lineRangeWithNewline(off);
                if (unit.start < self.drag_origin.start) {
                    self.core.setSelection(.{ .anchor = self.drag_origin.end, .head = unit.start });
                } else {
                    self.core.setSelection(.{ .anchor = self.drag_origin.start, .head = @max(unit.end, self.drag_origin.end) });
                }
            },
        }
    }

    fn onWindowMouseMove(self: *FileEditor, ev: *const zpui.input.MouseMoveEvent, window: *Window, cx: *Context(FileEditor)) void {
        if (!self.selecting) return;
        if (ev.pressed_button != .left) {
            self.selecting = false;
            return;
        }
        self.drag_pos = ev.position;
        self.dragTo(ev.position, window);
        if (self.dragScrollDelta(ev.position) != 0 and self.drag_task.header == null) {
            self.drag_task = cx.timer(16 * std.time.ns_per_ms, onDragTick) catch .none;
        }
        self.reveal_cursor = false;
        cx.notify();
    }

    fn dragScrollDelta(self: *const FileEditor, pos: Point) f32 {
        const b = self.body_bounds orelse return 0;
        return input.text_input.inputDragScrollDelta(pos.y, b.origin.y, b.bottom(), self.line_height);
    }

    fn onDragTick(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.drag_task.detach();
        self.drag_task = .none;
        if (!self.selecting) return;
        const pos = self.drag_pos orelse return;
        const delta = self.dragScrollDelta(pos);
        if (delta == 0) return;
        const off = self.scroll.offset();
        const max = self.scroll.baseHandle().maxOffset().y;
        const next_y = std.math.clamp(off.y - delta, -max, 0);
        if (next_y == off.y) return;
        self.scroll.setOffset(.{ .x = off.x, .y = next_y });
        if (cx.app.windowById(self.window_id)) |w| self.dragTo(pos, w);
        cx.notify();
        self.drag_task = cx.timer(16 * std.time.ns_per_ms, onDragTick) catch .none;
    }

    fn onMouseUp(self: *FileEditor, _: *const zpui.input.MouseUpEvent, _: *Window, _: *Context(FileEditor)) void {
        self.selecting = false;
        self.drag_task.cancel();
        self.drag_task = .none;
    }

    fn onRightDown(self: *FileEditor, ev: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(FileEditor)) void {
        window.focus(self.focus);
        const off = self.offsetAt(ev.position, window);
        const r = self.core.sel.range();
        if (r.isEmpty() or off < r.start or off > r.end) self.core.moveTo(off);
        // macOS: the same rows as a native menu (the drawn card stays the fallback).
        if (self.showNativeContextMenu(ev.position, window, cx)) {
            window.preventDefault();
            cx.stopPropagation();
            cx.notify();
            return;
        }
        self.context_menu = .{ .position = ev.position };
        self.context_exit.clear();
        window.preventDefault();
        cx.stopPropagation();
        cx.notify();
    }

    fn onScrollWheel(self: *FileEditor, ev: *const zpui.input.ScrollWheelEvent, _: *Window, cx: *Context(FileEditor)) void {
        if (self.opts.soft_wrap) return;
        const dx = switch (ev.delta) {
            .pixels => |p| p.x,
            .lines => |l| l.x * self.line_height,
        };
        if (dx == 0) return;
        const max = self.maxScrollX();
        const next = std.math.clamp(self.scroll_x - dx, 0, max);
        if (next != self.scroll_x) {
            self.scroll_x = next;
            cx.notify();
        }
    }

    fn maxScrollX(self: *const FileEditor) f32 {
        const b = self.body_bounds orelse return 0;
        const content = @as(f32, @floatFromInt(self.max_line_bytes)) * self.char_width + self.gutterWidth() + right_margin + caret_width;
        return @max(content - b.size.width, 0);
    }

    fn onBlink(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.blink_task.detach();
        self.blink_task = .none;
        cx.notify();
    }

    fn caretShown(self: *FileEditor, window: *Window, cx: *Context(FileEditor)) bool {
        if (!self.focus.isFocused(window) or !window.isWindowActive()) {
            self.blink_task.cancel();
            self.blink_task = .none;
            return false;
        }
        if (window.prefersReducedMotion()) return true;
        if (self.blink_task.header == null) self.blink_task = cx.timer(caret_blink_ms * std.time.ns_per_ms, onBlink) catch .none;
        const elapsed_ms = (self.now(cx) -| self.blink_anchor) / std.time.ns_per_ms;
        return (elapsed_ms / caret_blink_ms) % 2 == 0;
    }

    // ---- IME --------------------------------------------------------------------------------

    const IRange = zpui.window.input_handler.Range;
    const ISelection = zpui.window.input_handler.Selection;

    fn toU16(self: *FileEditor, r: Range) IRange {
        return .{ .start = self.core.buffer.utf16Offset(r.start), .end = self.core.buffer.utf16Offset(r.end) };
    }

    fn fromU16(self: *FileEditor, r: IRange) Range {
        return .{ .start = self.core.buffer.offsetForUtf16(r.start), .end = self.core.buffer.offsetForUtf16(r.end) };
    }

    pub fn selectedTextRange(self: *FileEditor, _: *Window, _: *Context(FileEditor)) ?ISelection {
        return .{ .range = self.toU16(self.core.sel.range()), .reversed = self.core.sel.reversed() };
    }

    pub fn markedTextRange(self: *FileEditor, _: *Window, _: *Context(FileEditor)) ?IRange {
        const m = self.core.marked orelse return null;
        return self.toU16(m);
    }

    pub fn textForRange(self: *FileEditor, range: IRange, out: *std.ArrayList(u8), _: *Window, _: *Context(FileEditor)) ?IRange {
        const r = self.fromU16(range);
        // Bound what the platform can ask for (huge documents).
        const end = @min(r.end, r.start + 64 * 1024);
        self.core.buffer.appendRange(r.start, end, out, self.gpa) catch return null;
        return self.toU16(.{ .start = r.start, .end = end });
    }

    pub fn replaceTextInRange(self: *FileEditor, range: ?IRange, new_text: []const u8, _: *Window, cx: *Context(FileEditor)) void {
        if (self.core.read_only) return;
        const r: ?Range = if (range) |x| self.fromU16(x) else null;
        // Plain typing: replace the selection (or marked text).
        const changed = self.core.commitText(r, new_text, self.now(cx));
        self.core.preferred_x = null;
        self.edit(changed, cx);
    }

    pub fn replaceAndMarkTextInRange(self: *FileEditor, range: ?IRange, new_text: []const u8, new_selected: ?IRange, _: *Window, cx: *Context(FileEditor)) void {
        if (self.core.read_only) return;
        const r: ?Range = if (range) |x| self.fromU16(x) else null;
        const s: ?Range = if (new_selected) |x| .{ .start = buffer_utf16Byte(new_text, x.start), .end = buffer_utf16Byte(new_text, x.end) } else null;
        self.edit(self.core.replaceAndMark(r, new_text, s, self.now(cx)), cx);
    }

    pub fn unmarkText(self: *FileEditor, _: *Window, cx: *Context(FileEditor)) void {
        if (self.core.unmark()) cx.notify();
    }

    pub fn boundsForRange(self: *FileEditor, range: IRange, element_bounds: Bounds, window: *Window, _: *Context(FileEditor)) ?Bounds {
        _ = element_bounds;
        const b = self.body_bounds orelse return null;
        const r = self.fromU16(range);
        const row = self.rowOfOffset(r.start);
        const x = self.caretX(r.start, window);
        const y = b.origin.y + self.scroll.offset().y + @as(f32, @floatFromInt(row)) * self.line_height;
        return .{ .origin = .{ .x = self.textOriginX(b) + x, .y = y }, .size = .{ .width = 2, .height = self.line_height } };
    }

    pub fn acceptsTextInput(self: *FileEditor, _: *Window, _: *Context(FileEditor)) bool {
        return !self.core.read_only and self.phase != .loading;
    }

    // ---- find / replace -------------------------------------------------------------------------

    fn inputColors(theme: *const Theme) input.text_input.Colors {
        return .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint };
    }

    fn makeInput(cx: *Context(FileEditor), placeholder: []const u8, theme: *const Theme) !Entity(TextInput) {
        return cx.newWith(TextInput, TextInput.init, .{input.Options{
            .placeholder = placeholder,
            .key_context = "PaletteSearch",
            .single_line = true,
            .text_size = 12,
            .line_height = 16,
            .colors = inputColors(theme),
            .edge_fade = false,
        }});
    }

    pub fn openFind(self: *FileEditor, replace: bool, window: *Window, cx: *Context(FileEditor)) void {
        const theme = ui.theme.get(cx);
        if (self.find_input == null) {
            const fi = makeInput(cx, "Find", theme) catch return;
            const ri = makeInput(cx, "Replace", theme) catch return;
            self.find_input = fi;
            self.replace_input = ri;
            self.find_subs.add(self.gpa, cx.subscribe(fi, onFindInput) catch return) catch {};
        }
        self.find_open = true;
        if (replace and !self.core.read_only) self.replace_open = true;
        // Seed with the selection (single line), like gpui-component.
        const sel = self.core.sel.range();
        if (!sel.isEmpty() and sel.len() < 256) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.gpa);
            self.core.buffer.appendRange(sel.start, sel.end, &out, self.gpa) catch {};
            if (std.mem.indexOfScalar(u8, out.items, '\n') == null) {
                self.find_input.?.update(cx, TextInput.setText, .{out.items});
            }
        }
        self.find_input.?.update(cx, TextInput.selectAllText, .{});
        const target = if (replace and self.replace_open) self.replace_input.? else self.find_input.?;
        window.focus(target.read(cx).focusHandle());
        self.syncSearchQuery(cx);
        cx.notify();
    }

    /// Open the find bar with `query` (host / demo entry point).
    pub fn findText(self: *FileEditor, query: []const u8, window: *Window, cx: *Context(FileEditor)) void {
        self.openFind(false, window, cx);
        self.find_input.?.update(cx, TextInput.setText, .{query});
        self.syncSearchQuery(cx);
    }

    fn closeFind(self: *FileEditor, cx: *Context(FileEditor)) void {
        self.find_open = false;
        self.replace_open = false;
        self.core.setSearchQuery("");
        if (cx.app.windowById(self.window_id)) |w| w.focus(self.focus);
        cx.notify();
    }

    fn onFindInput(self: *FileEditor, _: Entity(TextInput), ev: *const input.TextInputEvent, cx: *Context(FileEditor)) void {
        if (ev.* != .edited) return;
        self.syncSearchQuery(cx);
    }

    fn syncSearchQuery(self: *FileEditor, cx: *Context(FileEditor)) void {
        const fi = self.find_input orelse return;
        self.core.setSearchQuery(fi.read(cx).text());
        self.core.refreshSearch();
        // Live: select the first match at or after the caret.
        if (self.core.search.active) |ix| {
            const m = self.core.search.matches.items[ix];
            self.core.sel = .{ .anchor = m.start, .head = m.end };
            self.center_cursor = true;
        }
        self.reveal_cursor = true;
        cx.notify();
    }

    fn findStep(self: *FileEditor, forward: bool, cx: *Context(FileEditor)) void {
        if (self.find_input) |fi| self.core.setSearchQuery(fi.read(cx).text());
        if (self.core.findNext(forward) != null) {
            self.center_cursor = true;
            self.afterMove(cx);
        }
    }

    fn aSearch(self: *FileEditor, _: *const A.Search, w: *Window, cx: *Context(FileEditor)) void {
        self.openFind(false, w, cx);
    }
    fn aReplace(self: *FileEditor, _: *const A.Replace, w: *Window, cx: *Context(FileEditor)) void {
        self.openFind(true, w, cx);
    }
    fn aFindNext(self: *FileEditor, _: *const A.FindNext, _: *Window, cx: *Context(FileEditor)) void {
        self.findStep(true, cx);
    }
    fn aFindPrevious(self: *FileEditor, _: *const A.FindPrevious, _: *Window, cx: *Context(FileEditor)) void {
        self.findStep(false, cx);
    }
    fn aCloseFind(self: *FileEditor, _: *const A.CloseFind, _: *Window, cx: *Context(FileEditor)) void {
        self.closeFind(cx);
    }
    fn aToggleCase(self: *FileEditor, _: *const A.ToggleCaseSensitive, _: *Window, cx: *Context(FileEditor)) void {
        self.core.setSearchOptions(!self.core.search.case_sensitive, self.core.search.whole_word);
        self.syncSearchQuery(cx);
    }
    fn aToggleWord(self: *FileEditor, _: *const A.ToggleWholeWord, _: *Window, cx: *Context(FileEditor)) void {
        self.core.setSearchOptions(self.core.search.case_sensitive, !self.core.search.whole_word);
        self.syncSearchQuery(cx);
    }
    fn aReplaceNext(self: *FileEditor, _: *const A.ReplaceNext, _: *Window, cx: *Context(FileEditor)) void {
        self.replaceStep(false, cx);
    }
    fn aReplaceAll(self: *FileEditor, _: *const A.ReplaceAll, _: *Window, cx: *Context(FileEditor)) void {
        self.replaceStep(true, cx);
    }

    fn replaceStep(self: *FileEditor, all: bool, cx: *Context(FileEditor)) void {
        const ri = self.replace_input orelse return;
        const fi = self.find_input orelse return;
        self.core.setSearchQuery(fi.read(cx).text());
        const repl = self.gpa.dupe(u8, ri.read(cx).text()) catch return;
        defer self.gpa.free(repl);
        if (all) {
            const n = self.core.replaceAll(repl, self.now(cx)) catch return;
            if (n > 0) self.afterEdit(cx);
        } else {
            self.edit(self.core.replaceCurrent(repl, self.now(cx)), cx);
            self.center_cursor = true;
        }
    }

    fn onFindNextClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.findStep(true, cx);
    }
    fn onFindPrevClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.findStep(false, cx);
    }
    fn onFindCloseClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.closeFind(cx);
    }
    fn onCaseClick(self: *FileEditor, _: *const zpui.ClickEvent, w: *Window, cx: *Context(FileEditor)) void {
        self.aToggleCase(&.{}, w, cx);
    }
    fn onWordClick(self: *FileEditor, _: *const zpui.ClickEvent, w: *Window, cx: *Context(FileEditor)) void {
        self.aToggleWord(&.{}, w, cx);
    }
    fn onReplaceToggle(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        if (self.core.read_only) return;
        self.replace_open = !self.replace_open;
        cx.notify();
    }
    fn onReplaceOneClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.replaceStep(false, cx);
    }
    fn onReplaceAllClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.replaceStep(true, cx);
    }

    // ---- go to line ----------------------------------------------------------------------------

    pub fn openGoToLine(self: *FileEditor, window: *Window, cx: *Context(FileEditor)) void {
        const theme = ui.theme.get(cx);
        if (self.goto_input == null) {
            const gi = makeInput(cx, "", theme) catch return;
            self.goto_input = gi;
        }
        const placeholder = std.fmt.allocPrint(self.gpa, "Go to line (1\u{2013}{d})", .{self.core.buffer.lineCount()}) catch return;
        defer self.gpa.free(placeholder);
        self.goto_input.?.update(cx, TextInput.setPlaceholder, .{placeholder});
        self.goto_input.?.update(cx, TextInput.setText, .{""});
        self.goto_open = true;
        window.focus(self.goto_input.?.read(cx).focusHandle());
        cx.notify();
    }

    fn aGoToLine(self: *FileEditor, _: *const A.GoToLine, w: *Window, cx: *Context(FileEditor)) void {
        self.openGoToLine(w, cx);
    }

    fn aConfirmGoToLine(self: *FileEditor, _: *const A.ConfirmGoToLine, w: *Window, cx: *Context(FileEditor)) void {
        const gi = self.goto_input orelse return;
        const t = std.mem.trim(u8, gi.read(cx).text(), " ");
        var it = std.mem.splitAny(u8, t, ":,");
        const line = std.fmt.parseInt(usize, it.next() orelse "", 10) catch 0;
        const col: ?usize = if (it.next()) |c| std.fmt.parseInt(usize, c, 10) catch null else null;
        self.goto_open = false;
        w.focus(self.focus);
        if (line > 0) self.goToLine(line, col, cx) else cx.notify();
    }

    fn aCloseGoToLine(self: *FileEditor, _: *const A.CloseGoToLine, w: *Window, cx: *Context(FileEditor)) void {
        self.goto_open = false;
        w.focus(self.focus);
        cx.notify();
    }

    // ---- toolbar / banner clicks -------------------------------------------------------------

    fn onRevealClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        cx.emit(RevealFile{ .path = self.path });
    }
    fn onMarkdownToggleClick(self: *FileEditor, _: *const zpui.ClickEvent, window: *Window, cx: *Context(FileEditor)) void {
        self.show_markdown = !self.show_markdown;
        if (!self.show_markdown) window.focus(self.focus);
        cx.notify();
    }
    fn onPreviewOpenPath(self: *FileEditor, _: Entity(markdown_preview.MarkdownPreview), ev: *const markdown_preview.OpenPath, cx: *Context(FileEditor)) void {
        self.open_path_buf.clearRetainingCapacity();
        self.open_path_buf.appendSlice(self.gpa, ev.path) catch return;
        cx.emit(OpenPath{ .path = self.open_path_buf.items });
    }
    fn onWrapClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.setSoftWrap(!self.opts.soft_wrap, cx);
    }
    fn onSaveStatusClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.startSave(cx);
    }
    fn onKeepEditingClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.keepEditing(cx);
    }
    fn onReloadClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.requestReload(cx);
    }
    fn onCancelReloadClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.reload_confirmation = false;
        cx.notify();
    }
    fn onConfirmReloadClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.confirmReload(cx);
    }
    fn onRetryReadClick(self: *FileEditor, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.phase = .loading;
        self.startRead(cx);
        cx.notify();
    }

    fn onContextRow(self: *FileEditor, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(FileEditor)) void {
        self.closeContextMenu(cx);
        window.focus(self.focus);
        switch (ix) {
            0 => self.copySelection(cx, true),
            1 => self.copySelection(cx, false),
            2 => self.paste(cx),
            3 => {
                self.core.selectAll();
                self.afterMove(cx);
            },
            else => {},
        }
        cx.notify();
    }

    /// The context menu's rows (`renderContextMenu`) as a native menu; tags are the row
    /// indices `onContextRow` takes.
    fn showNativeContextMenu(self: *FileEditor, position: Point, window: *Window, cx: *Context(FileEditor)) bool {
        const has_sel = !self.core.sel.isEmpty();
        const editable = !self.core.read_only;
        const cmd: zpui.input.Modifiers = .{ .platform = true };
        const items = [_]ui.native_menu.Item{
            .{ .label = "Cut", .tag = 0, .disabled = !(editable and has_sel), .shortcut = .{ .key = "x", .modifiers = cmd } },
            .{ .label = "Copy", .tag = 1, .disabled = !has_sel, .shortcut = .{ .key = "c", .modifiers = cmd } },
            .{ .label = "Paste", .tag = 2, .disabled = !editable, .shortcut = .{ .key = "v", .modifiers = cmd } },
            .separator,
            .{ .label = "Select All", .tag = 3, .shortcut = .{ .key = "a", .modifiers = cmd } },
        };
        return ui.native_menu.popUpAt(window, cx, position, &items, cx.listener(onNativeContext));
    }

    fn onNativeContext(self: *FileEditor, sel: *const ui.native_menu.Selection, window: *Window, cx: *Context(FileEditor)) void {
        const tag = sel.tag orelse return;
        self.onContextRow(tag, &.{ .keyboard = .{} }, window, cx);
    }

    fn onContextOutside(self: *FileEditor, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(FileEditor)) void {
        self.closeContextMenu(cx);
        cx.notify();
    }

    fn preventDefault(_: *const zpui.input.MouseDownEvent, window: *Window, _: *App) void {
        window.preventDefault();
    }

    // ---- render -------------------------------------------------------------------------------

    pub fn render(self: *FileEditor, window: *Window, cx: *Context(FileEditor)) AnyElement {
        const theme = zpui.window.arena_mod.current().create(Theme, ui.theme.get(cx).*);
        self.window_id = window.id;
        self.ensureMetrics(window, theme);
        self.syncWrapWidth(cx);
        if (self.reveal_cursor or self.center_cursor) {
            const row = self.rowOfOffset(self.core.sel.head);
            if (self.center_cursor) self.scroll.scrollToItemStrict(row, .center) else self.scroll.scrollToItem(row, .nearest);
            self.center_cursor = false;
        }
        if (self.find_open) self.core.refreshSearch();
        if (self.pending_focus and self.phase != .loading) {
            self.pending_focus = false;
            window.focus(self.focus);
        }

        var root = div().id("file-editor").sizeFull().flex().flexCol().fontFamily(theme.font_sans_fixed).textColor(theme.text)
            .keyContext(A.find_context ++ "Host")
            .onAction(A.Search, cx.listener(aSearch))
            .onAction(A.Replace, cx.listener(aReplace));
        if (self.opts.show_header) root = root.child(self.renderHeader(theme, cx));
        if (self.renderBanner(theme, cx)) |b| root = root.child(b);
        root = root.child(self.renderBody(theme, window, cx));
        return zpui.intoAnyElement(root);
    }

    /// `toggle_markdown_task`: a preview checkbox flips its `[ ]` / `[x]`
    /// marker in the buffer (undoable), only while the buffer is editable and
    /// still exactly what the preview parsed; selection and scroll stay.
    pub fn toggleMarkdownTask(self: *FileEditor, source_hash: u64, start: usize, end: usize, checked: bool, cx: *Context(FileEditor)) void {
        if (!review.enabled(self)) return;
        const source = self.text(self.gpa) catch return;
        defer self.gpa.free(source);
        if (std.hash.Wyhash.hash(0, source) != source_hash) return;
        if (end > source.len or start >= end) return;
        const marker = source[start..end];
        const ok = if (checked) std.mem.eql(u8, marker, "[x]") or std.mem.eql(u8, marker, "[X]") else std.mem.eql(u8, marker, "[ ]");
        if (!ok) return;
        const changed = self.core.replaceKeepingSelection(.{ .start = start + 1, .end = start + 2 }, if (checked) " " else "x", self.now(cx)) catch return;
        if (!changed) return;
        self.afterEdit(cx);
        self.reveal_cursor = false;
    }

    /// The Markdown preview, synced to the current buffer (`prepare_markdown_preview`).
    fn markdownView(self: *FileEditor, cx: *Context(FileEditor)) ?Entity(markdown_preview.MarkdownPreview) {
        if (self.markdown == null) {
            const v = cx.newWith(markdown_preview.MarkdownPreview, markdown_preview.MarkdownPreview.init, .{ self.files, self.path }) catch return null;
            self.markdown = v;
            self.markdown_sub = cx.subscribe(v, onPreviewOpenPath) catch null;
            self.markdown_version = null;
        }
        const v = self.markdown.?;
        const version = self.core.currentVersion() ^ (self.read_generation << 40);
        if (self.markdown_version != version) {
            self.markdown_version = version;
            const source = self.text(self.gpa) catch return v;
            defer self.gpa.free(source);
            v.update(cx, markdown_preview.MarkdownPreview.setSource, .{ source, self.truncated });
        }
        // Staged comments on this file render as cards between the preview's
        // blocks (`set_comments`).
        {
            review.attach(self, cx);
            var scratch = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch.deinit();
            const list = review.fileComments(self, scratch.allocator(), cx.app);
            const draft: ?markdown_preview.CommentDraft = if (review.previewDraft(self)) |d| .{ .line = d.line, .input = d.input, .editing = d.editing } else null;
            v.update(cx, markdown_preview.MarkdownPreview.setComments, .{ cx.weakEntity(), list, draft, review.enabled(self) });
            v.update(cx, markdown_preview.MarkdownPreview.setCheckout, .{self.checkout_id});
        }
        return v;
    }

    /// Recompute wrap columns from the last body width; rebuild the row map on change.
    fn syncWrapWidth(self: *FileEditor, cx: *Context(FileEditor)) void {
        const b = self.body_bounds orelse return;
        const cols: ?usize = if (self.opts.soft_wrap) blk: {
            const w = b.size.width - self.gutterWidth() - right_margin;
            break :blk @max(@as(usize, @intFromFloat(@max(@floor(w / self.char_width), 1))), 8);
        } else null;
        if (std.meta.eql(cols, self.display.wrap_cols) and (cols == null or self.display.counts.items.len == self.core.buffer.lineCount())) return;
        self.wrap_cols = cols;
        self.rebuildDisplay();
        _ = cx;
    }

    fn toolbarButton(id: []const u8, active: bool, theme: *const Theme) zpui.StatefulDiv {
        var b = div().id(id).role(.button).size(px(control_size)).flexNone().rounded(px(control_radius)).flex().itemsCenter().justifyCenter()
            .cursorPointer().occlude().onMouseDown(.left, preventDefault)
            .hover(sb.bg(theme.wash(0.14)));
        if (active) b = b.bg(theme.wash(0.1));
        return b;
    }

    fn renderHeader(self: *FileEditor, theme: *const Theme, cx: *Context(FileEditor)) zpui.Div {
        var crumbs = div().minW0().flex1().flex().itemsCenter().overflowHidden();
        var it = std.mem.tokenizeScalar(u8, self.path, '/');
        var parts: [64][]const u8 = undefined;
        var n: usize = 0;
        while (it.next()) |p| {
            if (n < parts.len) parts[n] = p;
            n += 1;
        }
        n = @min(n, parts.len);
        for (parts[0..n], 0..) |part, i| {
            if (i > 0) crumbs = crumbs.child(div().mx(px(4)).textSize(px(11)).textColor(theme.text_faint.opacity(0.65)).child("\u{203A}"));
            crumbs = crumbs.child(div().minW0().truncate().whitespaceNowrap().fontFamily(theme.font_sans).textSize(px(11))
                .textColor(if (i + 1 == n) theme.text_muted else theme.text_faint).child(part));
        }
        var bar = toolbarDiv(theme).pr(px(control_gap))
            .child(md.file_icons.icon(self.path, theme, 14))
            .child(crumbs);
        if (markdown_preview.isMarkdown(self.path)) {
            const on = self.show_markdown;
            bar = bar.child(toolbarButton("files-toggle-markdown", on, theme).ariaLabel(if (on) "Show Markdown code" else "Preview Markdown")
                .tooltipWith(@as([]const u8, if (on) "Show Markdown code" else "Preview Markdown"), ui.tooltip.build)
                .onClick(cx.listener(onMarkdownToggleClick))
                .child(ui.icon.of(if (on) .file_code else .eye, icon_size, theme.text_muted)));
        }
        if (self.saveStatus(theme)) |st| {
            var chip = div().id("files-save-status").h(px(control_size)).px(px(6)).rounded(px(control_radius)).flex().itemsCenter().flexNone()
                .fontFamily(theme.font_sans).textSize(px(11)).textColor(st.color);
            if (st.retry) chip = chip.role(.button).cursorPointer().hover(sb.bg(theme.wash(0.14))).onMouseDown(.left, preventDefault).onClick(cx.listener(onSaveStatusClick));
            if (st.detail) |d| chip = chip.tooltipWith(d, ui.tooltip.build);
            bar = bar.child(chip.child(st.label));
        }
        const wrap_on = self.opts.soft_wrap;
        bar = bar
            .child(toolbarButton("files-reveal-active", false, theme).ariaLabel("Reveal file in tree").tooltipWith(@as([]const u8, "Reveal file in tree"), ui.tooltip.build)
                .onClick(cx.listener(onRevealClick))
                .child(ui.icon.of(.folder, icon_size, theme.text_muted)))
            .child(toolbarButton("files-toggle-word-wrap", wrap_on, theme).ariaLabel(if (wrap_on) "Disable word wrap" else "Enable word wrap")
                .tooltipWith(@as([]const u8, if (wrap_on) "Disable word wrap" else "Enable word wrap"), ui.tooltip.build)
                .onClick(cx.listener(onWrapClick))
                .child(ui.icon.of(.list, icon_size, if (wrap_on) theme.text else theme.text_muted)));
        return bar;
    }

    pub fn toolbarDiv(theme: *const Theme) zpui.Div {
        return div().h(px(header_height)).wFull().flexNone().px(px(edge_inset)).flex().itemsCenter().gap(px(control_gap))
            .borderT1().borderB1().borderColor(theme.border)
            .bg(if (theme.isGlass()) theme.surface.opacity(0.26) else theme.surface);
    }

    const SaveStatus = struct { label: []const u8, color: Hsla, retry: bool, detail: ?[]const u8 };

    fn saveStatus(self: *FileEditor, theme: *const Theme) ?SaveStatus {
        return switch (self.phase) {
            .save_failed => .{ .label = "Save failed", .color = theme.danger_muted, .retry = true, .detail = self.message },
            .conflict => .{ .label = "Save conflict", .color = theme.warning_muted, .retry = false, .detail = "The file changed on disk. Your editor buffer was preserved." },
            .deleted_on_disk => .{ .label = "Deleted on disk", .color = theme.warning_muted, .retry = false, .detail = "The file was removed on disk. Your editor buffer was preserved." },
            .externally_modified => .{ .label = "Changed on disk", .color = theme.warning_muted, .retry = false, .detail = "The file changed on disk. Review it before saving." },
            else => null,
        };
    }

    fn bannerFrame(theme: *const Theme) zpui.Div {
        return div().minH(px(32)).py(px(6)).flexNone().px(px(10)).flex().flexWrap().itemsCenter().gap(px(8))
            .borderB1().borderColor(theme.warning.opacity(0.25)).bg(theme.warning.opacity(0.055))
            .fontFamily(theme.font_sans).textSize(px(11)).textColor(theme.warning_muted);
    }

    fn bannerAction(id: []const u8, label: []const u8, color: Hsla) zpui.StatefulDiv {
        return div().id(id).cursorPointer().textColor(color).child(label);
    }

    fn renderBanner(self: *FileEditor, theme: *const Theme, cx: *Context(FileEditor)) ?zpui.Div {
        const external = self.phase == .externally_modified or self.phase == .conflict;
        if (external or self.reload_confirmation) {
            var actions = div().mlAuto().flex().flexWrap().itemsCenter().gap(px(8));
            if (self.reload_confirmation) {
                actions = actions
                    .child(bannerAction("files-cancel-reload", "Cancel", theme.text_muted).onClick(cx.listener(onCancelReloadClick)))
                    .child(bannerAction("files-confirm-reload", "Discard & Reload", theme.text).onClick(cx.listener(onConfirmReloadClick)));
            } else {
                actions = actions
                    .child(bannerAction("files-keep-external-edits", "Keep Editing", theme.text_muted).onClick(cx.listener(onKeepEditingClick)))
                    .child(bannerAction("files-reload-external", "Reload from Disk", theme.text).onClick(cx.listener(onReloadClick)));
            }
            return bannerFrame(theme)
                .child(div().minW0().child(if (self.reload_confirmation) "Discard unsaved changes?" else "This file changed outside Zeron."))
                .child(actions);
        }
        if (self.phase == .deleted_on_disk) {
            return bannerFrame(theme).child(div().minW0().child("This file was deleted outside Zeron. Your buffer is kept for recovery."));
        }
        if (self.phase == .read_only and (self.truncated or self.read_only_reason != null)) {
            const msg = if (self.truncated) "Large file preview is truncated and read-only." else readOnlyMessage(self.read_only_reason);
            return div().h(px(28)).flexNone().px(px(10)).borderB1().borderColor(theme.border)
                .bg(theme.wash(0.03)).flex().itemsCenter().fontFamily(theme.font_sans).textSize(px(10)).textColor(theme.text_muted)
                .child(msg);
        }
        return null;
    }

    fn centered(theme: *const Theme, msg: []const u8, color: Hsla) zpui.Div {
        _ = theme;
        return div().flex1().flex().itemsCenter().justifyCenter().px(px(24)).textCenter().textSize(px(11.5)).textColor(color).child(msg);
    }

    fn renderBody(self: *FileEditor, theme: *const Theme, window: *Window, cx: *Context(FileEditor)) AnyElement {
        switch (self.phase) {
            .loading => return zpui.intoAnyElement(centered(theme, "Loading file\u{2026}", theme.text_faint)),
            .failed => return zpui.intoAnyElement(div().flex1().flex().flexCol().itemsCenter().justifyCenter().gap(px(10))
                .child(centered(theme, self.message orelse "Could not read file.", theme.danger_muted).flexNone())
                .child(div().id("files-retry-read").role(.button).h(px(28)).px(px(12)).rounded(px(7)).border1().borderColor(theme.border)
                .bg(theme.wash(0.04)).hover(sb.bg(theme.wash(0.09))).cursorPointer().flex().itemsCenter()
                .textSize(px(11.5)).textColor(theme.text).child("Retry").onClick(cx.listener(onRetryReadClick)))),
            else => {},
        }
        // Workspace images render (`ImagePreview`), whatever the text read said.
        if (image_preview.isImage(self.path)) {
            if (self.image_view == null) self.image_view = cx.newWith(image_preview.ImagePreview, image_preview.ImagePreview.init, .{ self.files, self.path, self.checkout_id }) catch null;
            if (self.image_view) |v| return zpui.intoAnyElement(div().flex1().minH0().minW0().child(v));
        }
        if (self.phase == .unavailable) return zpui.intoAnyElement(centered(theme, self.message orelse "This file cannot be previewed.", theme.text_muted));
        if (self.show_markdown and markdown_preview.isMarkdown(self.path)) {
            if (self.markdownView(cx)) |v| return zpui.intoAnyElement(div().flex1().minH0().minW0().child(v));
        }
        const caret_on = self.caretShown(window, cx);
        const total_rows = self.rowCount() + bottom_margin_rows;
        var list = zpui.uniformList("file-editor-rows", total_rows, cx, renderRows).trackScroll(self.scroll).sizeFull();
        list.style().restrict_scroll_to_axis = true;
        var body = div().id("file-editor-body").relative().flex1().minH0().minW0().overflowHidden()
            .trackFocus(self.focus).keyContext(A.context)
            .fontFamily(theme.font_mono).textSize(px(self.font_size)).lineHeight(px(self.line_height))
            .cursorText()
            .onAction(A.Left, cx.listener(aLeft))
            .onAction(A.Right, cx.listener(aRight))
            .onAction(A.Up, cx.listener(aUp))
            .onAction(A.Down, cx.listener(aDown))
            .onAction(A.SelectLeft, cx.listener(aSelectLeft))
            .onAction(A.SelectRight, cx.listener(aSelectRight))
            .onAction(A.SelectUp, cx.listener(aSelectUp))
            .onAction(A.SelectDown, cx.listener(aSelectDown))
            .onAction(A.PageUp, cx.listener(aPageUp))
            .onAction(A.PageDown, cx.listener(aPageDown))
            .onAction(A.SelectPageUp, cx.listener(aSelectPageUp))
            .onAction(A.SelectPageDown, cx.listener(aSelectPageDown))
            .onAction(A.WordLeft, cx.listener(aWordLeft))
            .onAction(A.WordRight, cx.listener(aWordRight))
            .onAction(A.SelectWordLeft, cx.listener(aSelectWordLeft))
            .onAction(A.SelectWordRight, cx.listener(aSelectWordRight))
            .onAction(A.Home, cx.listener(aHome))
            .onAction(A.End, cx.listener(aEnd))
            .onAction(A.SelectHome, cx.listener(aSelectHome))
            .onAction(A.SelectEnd, cx.listener(aSelectEnd))
            .onAction(A.DocStart, cx.listener(aDocStart))
            .onAction(A.DocEnd, cx.listener(aDocEnd))
            .onAction(A.SelectDocStart, cx.listener(aSelectDocStart))
            .onAction(A.SelectDocEnd, cx.listener(aSelectDocEnd))
            .onAction(A.SelectAll, cx.listener(aSelectAll))
            .onAction(A.Backspace, cx.listener(aBackspace))
            .onAction(A.Delete, cx.listener(aDelete))
            .onAction(A.DeleteWordLeft, cx.listener(aDeleteWordLeft))
            .onAction(A.DeleteWordRight, cx.listener(aDeleteWordRight))
            .onAction(A.DeleteToLineStart, cx.listener(aDeleteToLineStart))
            .onAction(A.DeleteToLineEnd, cx.listener(aDeleteToLineEnd))
            .onAction(A.Enter, cx.listener(aEnter))
            .onAction(A.IndentInline, cx.listener(aIndentInline))
            .onAction(A.OutdentInline, cx.listener(aOutdentInline))
            .onAction(A.Indent, cx.listener(aIndent))
            .onAction(A.Outdent, cx.listener(aOutdent))
            .onAction(A.Undo, cx.listener(aUndo))
            .onAction(A.Redo, cx.listener(aRedo))
            .onAction(A.Copy, cx.listener(aCopy))
            .onAction(A.Cut, cx.listener(aCut))
            .onAction(A.Paste, cx.listener(aPaste))
            // The Edit menu items (app_menus: composer::* with the native selectors) work
            // in the editor too.
            .onAction(zeron_actions.composer.Undo, cx.listener(editMenuVerb(zeron_actions.composer.Undo, A.Undo, aUndo)))
            .onAction(zeron_actions.composer.Redo, cx.listener(editMenuVerb(zeron_actions.composer.Redo, A.Redo, aRedo)))
            .onAction(zeron_actions.composer.Cut, cx.listener(editMenuVerb(zeron_actions.composer.Cut, A.Cut, aCut)))
            .onAction(zeron_actions.composer.Copy, cx.listener(editMenuVerb(zeron_actions.composer.Copy, A.Copy, aCopy)))
            .onAction(zeron_actions.composer.Paste, cx.listener(editMenuVerb(zeron_actions.composer.Paste, A.Paste, aPaste)))
            .onAction(zeron_actions.composer.SelectAll, cx.listener(editMenuVerb(zeron_actions.composer.SelectAll, A.SelectAll, aSelectAll)))
            .onAction(A.Save, cx.listener(aSave))
            .onAction(A.Escape, cx.listener(aEscape))
            .onAction(A.FindNext, cx.listener(aFindNext))
            .onAction(A.FindPrevious, cx.listener(aFindPrevious))
            .onAction(A.GoToLine, cx.listener(aGoToLine))
            .onAction(A.ToggleSoftWrap, cx.listener(aToggleWrap))
            .onMouseDown(.left, cx.listener(onMouseDown))
            .onMouseDown(.right, cx.listener(onRightDown))
            .onMouseUp(.left, cx.listener(onMouseUp))
            .onMouseUpOut(.left, cx.listener(onMouseUp))
            .onScrollWheel(cx.listener(onScrollWheel))
            .child(list)
            .child(zpui.canvas(Overlay{ .id = cx.entityId(), .focus = self.focus, .caret_on = caret_on }, Overlay.paint)
            .withPrepaint(Overlay, Overlay.prepaint).absolute().inset0())
            .child(zpui.scrollbar(self.scroll).id("file-editor-vbar").withStyle(scrollbarStyle(theme)));
        if (!self.opts.soft_wrap and self.maxScrollX() > 0) {
            body = body.child(zpui.scrollbar(self.hscroll).id("file-editor-hbar").axis(.horizontal).withStyle(scrollbarStyle(theme)));
        }
        for (review.overlays(self, theme, cx)) |o| body = body.child(o);
        if (self.find_open) body = body.child(self.renderFindBar(theme, cx));
        if (self.goto_open) body = body.child(self.renderGoTo(theme, cx));
        if (self.context_exit.done(cx.app.executor.now())) {
            self.context_exit.clear();
            self.context_menu = null;
        }
        if (self.context_menu) |m| body = body.child(self.renderContextMenu(m, theme, cx));
        return zpui.intoAnyElement(body);
    }

    fn scrollbarStyle(theme: *const Theme) zpui.ScrollbarStyle {
        const t = theme.scrollbarThumbColors();
        return .{ .thumb = t[0], .thumb_hover = t[1], .thumb_active = t[2] };
    }

    fn renderRows(self: *FileEditor, range: zpui.Range, _: *Window, cx: *Context(FileEditor)) []AnyElement {
        const a = zpui.window.arena_mod.frameAllocator();
        const out = a.alloc(AnyElement, range.end - range.start) catch return &.{};
        for (out, range.start..) |*e, row| e.* = zpui.intoAnyElement(RowElement{ .editor = cx.entityId(), .row = row, .height = self.line_height });
        return out;
    }

    fn findToggle(id: []const u8, label: []const u8, active: bool, theme: *const Theme) zpui.StatefulDiv {
        var b = div().id(id).role(.toggle_button).ariaToggled(active).h(px(22)).minW(px(22)).px(px(4)).rounded(px(5)).flexNone().flex().itemsCenter().justifyCenter()
            .cursorPointer().onMouseDown(.left, preventDefault).fontFamily(theme.font_mono).textSize(px(11))
            .textColor(if (active) theme.text else theme.text_muted).hover(sb.bg(theme.wash(0.12)));
        if (active) b = b.bg(theme.accent.opacity(0.22));
        return b.child(label);
    }

    fn findIconButton(id: []const u8, i: ui.icon.Icon, enabled: bool, theme: *const Theme) zpui.StatefulDiv {
        var b = div().id(id).role(.button).ariaDisabled(!enabled).size(px(22)).rounded(px(5)).flexNone().flex().itemsCenter().justifyCenter()
            .onMouseDown(.left, preventDefault)
            .child(ui.icon.of(i, 13, theme.text_muted));
        b = if (enabled) b.cursorPointer().hover(sb.bg(theme.wash(0.12))) else b.opacity(0.4);
        return b;
    }

    fn findField(theme: *const Theme, content: anytype) zpui.Div {
        return div().h(px(24)).minW0().flex1().px(px(8)).rounded(px(6)).bg(theme.ink(0.05)).flex().itemsCenter()
            .border1().borderColor(theme.border).overflowHidden().child(content);
    }

    fn renderFindBar(self: *FileEditor, theme_in: *const Theme, cx: *Context(FileEditor)) zpui.Div {
        const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
        const s = &self.core.search;
        const count = s.matches.items.len;
        const label = if (s.query.items.len == 0)
            ""
        else if (count == 0)
            "No results"
        else if (s.active) |ix|
            zpui.fmt("{d}{s} of {d}{s}", .{ ix + 1, "", count, if (s.capped) "+" else "" })
        else
            zpui.fmt("{d}{s} results", .{ count, if (s.capped) "+" else "" });
        const can_replace = !self.core.read_only;
        var top = div().flex().flexRow().itemsCenter().gap(px(4))
            .child(findIconButton("find-toggle-replace", if (self.replace_open) .alt_arrow_down else .alt_arrow_right, can_replace, theme).ariaLabel("Toggle replace").ariaExpanded(self.replace_open)
                .onClick(cx.listener(onReplaceToggle)))
            .child(findField(theme, self.find_input.?))
            .child(findToggle("find-case", "Aa", s.case_sensitive, theme).ariaLabel("Match case").onClick(cx.listener(onCaseClick)).tooltipWith(@as([]const u8, "Match case"), ui.tooltip.build))
            .child(findToggle("find-word", "ab", s.whole_word, theme).ariaLabel("Match whole word").onClick(cx.listener(onWordClick)).tooltipWith(@as([]const u8, "Match whole word"), ui.tooltip.build))
            .child(div().w(px(70)).flexNone().textSize(px(11)).textColor(if (count == 0 and s.query.items.len > 0) theme.danger_muted else theme.text_muted).whitespaceNowrap().truncate().child(label))
            .child(findIconButton("find-prev", .arrow_up, count > 0, theme).ariaLabel("Previous match").onClick(cx.listener(onFindPrevClick)).tooltipWith(@as([]const u8, "Previous match (Shift+Enter)"), ui.tooltip.build))
            .child(findIconButton("find-next", .arrow_down, count > 0, theme).ariaLabel("Next match").onClick(cx.listener(onFindNextClick)).tooltipWith(@as([]const u8, "Next match (Enter)"), ui.tooltip.build))
            .child(findIconButton("find-close", .close, true, theme).ariaLabel("Close find").onClick(cx.listener(onFindCloseClick)).tooltipWith(@as([]const u8, "Close (Escape)"), ui.tooltip.build));
        var card = ui.popover.card(theme).w(px(400)).p(px(4)).gap(px(4)).textSize(px(12)).keyContext(A.find_context)
            .onAction(A.FindNext, cx.listener(aFindNext))
            .onAction(A.FindPrevious, cx.listener(aFindPrevious))
            .onAction(A.CloseFind, cx.listener(aCloseFind))
            .onAction(A.ToggleCaseSensitive, cx.listener(aToggleCase))
            .onAction(A.ToggleWholeWord, cx.listener(aToggleWord))
            .onAction(A.Search, cx.listener(aSearch))
            .onAction(A.Replace, cx.listener(aReplace))
            .child(top);
        top = undefined;
        if (self.replace_open) {
            card = card.child(div().flex().flexRow().itemsCenter().gap(px(4))
                .child(div().w(px(22)).flexNone())
                .child(findField(theme, div().sizeFull().flex().itemsCenter().keyContext("replace_input")
                .onAction(A.ReplaceNext, cx.listener(aReplaceNext))
                .onAction(A.ReplaceAll, cx.listener(aReplaceAll))
                .child(self.replace_input.?)))
                .child(findTextButton("find-replace-one", "Replace", count > 0, theme).onClick(cx.listener(onReplaceOneClick)))
                .child(findTextButton("find-replace-all", "All", count > 0, theme).onClick(cx.listener(onReplaceAllClick))));
        }
        return div().absolute().top(px(8)).right(px(16)).occlude()
            .onMouseDown(.left, stopMouse)
            .child(ui.popover.frostedCard(card));
    }

    fn stopMouse(_: *const zpui.input.MouseDownEvent, _: *Window, app: *App) void {
        app.propagate_event = false;
    }

    fn findTextButton(id: []const u8, label: []const u8, enabled: bool, theme: *const Theme) zpui.StatefulDiv {
        var b = div().id(id).role(.button).ariaDisabled(!enabled).h(px(24)).px(px(8)).rounded(px(6)).flexNone().flex().itemsCenter()
            .textSize(px(11.5)).textColor(theme.text).border1().borderColor(theme.border).bg(theme.wash(0.04))
            .onMouseDown(.left, preventDefault).child(label);
        b = if (enabled) b.cursorPointer().hover(sb.bg(theme.wash(0.09))) else b.opacity(0.4);
        return b;
    }

    fn renderGoTo(self: *FileEditor, theme_in: *const Theme, cx: *Context(FileEditor)) zpui.Div {
        const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
        const cur = self.core.buffer.pointOf(self.core.cursor());
        const card = ui.popover.card(theme).w(px(280)).p(px(6)).gap(px(4)).keyContext(A.goto_context)
            .onAction(A.ConfirmGoToLine, cx.listener(aConfirmGoToLine))
            .onAction(A.CloseGoToLine, cx.listener(aCloseGoToLine))
            .child(findField(theme, self.goto_input.?))
            .child(div().px(px(4)).textSize(px(10.5)).textColor(theme.text_faint)
            .child(zpui.fmt("Current line {d}, column {d} \u{00B7} line:column", .{ cur.line + 1, cur.col + 1 })));
        return div().absolute().top(px(8)).left(px(0)).right(px(0)).flex().justifyCenter()
            .child(div().occlude().onMouseDown(.left, stopMouse).child(ui.popover.frostedCard(card)));
    }

    fn renderContextMenu(self: *FileEditor, m: ContextMenu, theme_in: *const Theme, cx: *Context(FileEditor)) AnyElement {
        const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
        const has_sel = !self.core.sel.isEmpty();
        const editable = !self.core.read_only;
        const rows = [_]struct { []const u8, bool }{ .{ "Cut", editable and has_sel }, .{ "Copy", has_sel }, .{ "Paste", editable }, .{ "Select All", true } };
        var card = ui.popover.card(theme).w(px(170)).onMouseDownOut(cx.listener(onContextOutside));
        for (rows, 0..) |r, i| {
            if (i == 3) card = card.child(ui.popover.separator(theme));
            var row = ui.popover.menuRow(theme, false).id(.{ "files-editor-context", i }).role(.menu_item).child(r[0]);
            row = if (r[1]) row.onClick(cx.listenerWith(i, onContextRow)) else row.opacity(0.38);
            card = card.child(row);
        }
        return ui.popover.anchoredAtExit(m.position, card, self.context_exit.progress(cx.app.executor.now()));
    }

    /// `begin_close`: the context menu plays MENU_OUT before it is dropped.
    fn closeContextMenu(self: *FileEditor, cx: *Context(FileEditor)) void {
        if (self.context_menu == null or self.context_exit.isClosing()) return;
        if (ui.popover.appReduced(cx.app)) {
            self.context_menu = null;
            return;
        }
        if (self.context_exit.begin(cx.app.executor.now())) ui.popover.reap(FileEditor, cx);
    }
};

fn buffer_utf16Byte(s: []const u8, u: usize) usize {
    return @import("buffer.zig").byteForUtf16(s, u);
}

pub fn readOnlyMessage(reason: ?proto.ReadOnlyReason) []const u8 {
    return switch (reason orelse return "This file cannot be previewed.") {
        .binary => "Binary files cannot be previewed.",
        .unsupportedEncoding => "This file encoding is not supported.",
        .symlink => "Symlink targets are read-only.",
        .permissionDenied => "Permission denied.",
        .tooLarge => "This file is too large to edit; it opens read-only.",
        .mixedLineEndings => "Files with mixed line endings are read-only.",
        .outsideWorkspace => "Read-only: outside this chat's folder.",
        .notRegularFile => "This file cannot be previewed.",
    };
}

// ---------------------------------------------------------------------------
// overlay: bounds, IME registration, drag tracking, horizontal reveal
// ---------------------------------------------------------------------------

const Overlay = struct {
    id: zpui.EntityId,
    focus: zpui.FocusHandle,
    caret_on: bool,

    const W = zpui.WeakEntity(FileEditor);

    fn prepaint(self: Overlay, bounds: Bounds, window: *Window, app: *App) void {
        const w: W = .{ .id = self.id };
        _ = w.update(app, prepaintEditor, .{ bounds, window });
    }

    fn prepaintEditor(ed: *FileEditor, bounds: Bounds, window: *Window, cx: *Context(FileEditor)) void {
        const changed = if (ed.body_bounds) |b| b.size.width != bounds.size.width or b.size.height != bounds.size.height else true;
        ed.body_bounds = bounds;
        if (changed and ed.opts.soft_wrap) {
            const before = ed.display.wrap_cols;
            ed.syncWrapWidth(cx);
            if (!std.meta.eql(before, ed.display.wrap_cols)) {
                ed.reveal_cursor = true;
                cx.notify();
            }
        }
        // Horizontal: follow the caret after keyboard moves / edits.
        if (!ed.opts.soft_wrap) {
            const max = ed.maxScrollX();
            const hs = ed.hscroll;
            // A scrollbar drag moved the handle: adopt it.
            const from_bar = -hs.offset().x;
            if (@abs(from_bar - ed.bar_x) > 0.5 and hs.state.max_offset.x > 0 and !ed.reveal_cursor) ed.scroll_x = from_bar;
            if (ed.reveal_cursor) {
                const x = ed.caretX(ed.core.sel.head, window);
                const view_w = bounds.size.width - ed.gutterWidth() - right_margin;
                if (x < ed.scroll_x) ed.scroll_x = @max(x - 4 * ed.char_width, 0);
                if (x + caret_width > ed.scroll_x + view_w) ed.scroll_x = x + caret_width - view_w + 4 * ed.char_width;
            }
            ed.scroll_x = std.math.clamp(ed.scroll_x, 0, max);
            hs.state.bounds = bounds;
            hs.state.max_offset = .{ .x = max, .y = 0 };
            hs.state.offset = .{ .x = -ed.scroll_x, .y = 0 };
            ed.bar_x = ed.scroll_x;
            hs.state.overflow.x = .scroll;
        } else ed.scroll_x = 0;
        ed.reveal_cursor = false;
    }

    const MoveCtx = struct { id: zpui.EntityId };

    fn onMove(ctx: *MoveCtx, ev: *const zpui.input.MouseMoveEvent, phase: zpui.DispatchPhase, window: *Window, app: *App) void {
        if (phase != .bubble) return;
        const w: W = .{ .id = ctx.id };
        _ = w.update(app, FileEditor.onWindowMouseMove, .{ ev, window });
    }

    fn paint(self: Overlay, bounds: Bounds, window: *Window, _: *App) void {
        window.handleInput(self.focus, .init(Entity(FileEditor){ .id = self.id }, bounds));
        window.onMouseEvent(zpui.input.MouseMoveEvent, MoveCtx{ .id = self.id }, onMove);
    }
};

// ---------------------------------------------------------------------------
// one display row: gutter number, guides, selection, matches, text, caret
// ---------------------------------------------------------------------------

const RowElement = struct {
    editor: zpui.EntityId,
    row: usize,
    height: f32,

    const W = zpui.WeakEntity(FileEditor);

    pub fn requestLayout(self: *RowElement, _: ?zpui.GlobalElementId, _: *void, window: *Window, _: *App) zpui.LayoutId {
        var style: zpui.Style = .{};
        style.size.width = .{ .definite = .{ .fraction = 1.0 } };
        style.size.height = .{ .definite = .{ .absolute = .{ .pixels = self.height } } };
        return window.requestLayout(style, &.{});
    }

    pub fn prepaint(_: *RowElement, _: ?zpui.GlobalElementId, _: Bounds, _: *void, _: *void, _: *Window, _: *App) void {}

    pub fn paint(self: *RowElement, _: ?zpui.GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, app: *App) void {
        const w: W = .{ .id = self.editor };
        _ = w.update(app, paintRow, .{ self.row, bounds, window });
    }
};

fn paintRow(ed: *FileEditor, row: usize, bounds: Bounds, window: *Window, cx: *Context(FileEditor)) void {
    const theme = ui.theme.get(cx);
    const a = zpui.window.arena_mod.frameAllocator();
    const lh = ed.line_height;
    const focused = ed.focus.isFocused(window);
    const body = ed.body_bounds orelse bounds;
    const left = body.origin.x;
    const right = body.right();
    const gutter = ed.gutterWidth();
    const info = ed.rowInfo(row, a) orelse {
        return;
    };
    const head = ed.core.sel.head;
    const head_line = ed.core.buffer.lineOf(head);
    const active_line = info.line == head_line;
    const active_color = theme.wash(0.025);
    const fg = theme.text.opacity(0.93);

    // Active line (gutter + text), only while focused.
    if (active_line and focused and ed.core.sel.isEmpty()) {
        window.paintQuad(zpui.fill(.{ .origin = .{ .x = left, .y = bounds.origin.y }, .size = .{ .width = right - left, .height = lh } }, active_color));
    }

    const font = ed.font(window, theme);
    const painter = window.glyphPainter();
    // Gutter: right-aligned number on the line's first row.
    if (info.sub == 0) {
        const width = ed.lineNumberLen();
        const label = std.fmt.allocPrint(a, "{d}", .{info.line + 1}) catch "";
        const pad = width -| label.len;
        const padded = a.alloc(u8, pad + label.len) catch return;
        @memset(padded[0..pad], ' ');
        @memcpy(padded[pad..], label);
        const color = if (active_line) fg else theme.text_faint;
        const run: zpui.text.TextRun = .{ .len = padded.len, .font = font, .color = color };
        if (window.text_system.shapeLine(padded, ed.font_size, &.{run}, null)) |shaped| {
            defer shaped.deinit(ed.gpa);
            shaped.paint(painter, .{ .x = left, .y = bounds.origin.y }, lh, .left, null) catch {};
        } else |_| {}
    }

    // Text area clip.
    const clip: Bounds = .{ .origin = .{ .x = left + gutter, .y = bounds.origin.y }, .size = .{ .width = @max(right - left - gutter, 0), .height = lh } };
    window.pushContentMask(.{ .bounds = clip });
    defer window.popContentMask(.{ .bounds = clip });
    const ox = left + gutter - ed.scroll_x;
    const cw = ed.char_width;

    // Indent guides (gpui-component: every tab_size columns below the indent;
    // blank lines take the previous non-blank line's guides).
    {
        const indent_cols = guideIndent(ed, info.line);
        const step = ed.core.tab_size;
        var col: usize = 0;
        const guide = theme.border.opacity(0.85);
        while (col < indent_cols) : (col += step) {
            const x = ox + @as(f32, @floatFromInt(col)) * cw;
            window.paintQuad(zpui.fill(.{ .origin = .{ .x = @round(x), .y = bounds.origin.y }, .size = .{ .width = 1, .height = lh } }, guide));
        }
    }

    // Shape the row with syntax runs.
    var runs: std.ArrayList(zpui.text.TextRun) = .empty;
    buildRuns(ed, info, font, fg, theme, &runs, a);
    const shaped_opt: ?zpui.text.ShapedLine = window.text_system.shapeLine(info.text, ed.font_size, runs.items, null) catch null;
    defer if (shaped_opt) |s| s.deinit(ed.gpa);
    const xFor = struct {
        fn f(s: ?zpui.text.ShapedLine, i: usize, cwv: f32) f32 {
            if (s) |sh| return sh.xForIndex(i);
            return @as(f32, @floatFromInt(i)) * cwv;
        }
    }.f;
    const row_end_x = xFor(shaped_opt, info.text.len, cw);

    // Search matches (secondary selection color; the active one full selection).
    if (ed.find_open and ed.core.search.matches.items.len > 0) {
        const ms = ed.core.search.matches.items;
        const secondary = Hsla{ .h = theme.accent.h, .s = 0.1, .l = theme.accent.l, .a = 0.22 };
        // Binary search the first match ending after the row start.
        var lo: usize = 0;
        var hi: usize = ms.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (ms[mid].end <= info.start) lo = mid + 1 else hi = mid;
        }
        var i = lo;
        while (i < ms.len and ms[i].start < info.end + 1) : (i += 1) {
            const m = ms[i];
            const s0 = @max(m.start, info.start);
            const s1 = @min(m.end, info.end);
            if (s1 < s0 or (s1 == s0 and m.start != m.end)) continue;
            const x0 = xFor(shaped_opt, info.toDisplay(s0 - info.start), cw);
            const x1 = xFor(shaped_opt, info.toDisplay(s1 - info.start), cw);
            window.paintQuad(zpui.fill(.{ .origin = .{ .x = ox + x0, .y = bounds.origin.y }, .size = .{ .width = @max(x1 - x0, 1), .height = lh } }, secondary));
            if (ed.core.search.active != null and ed.core.search.active.? == i)
                window.paintQuad(zpui.fill(.{ .origin = .{ .x = ox + x0, .y = bounds.origin.y }, .size = .{ .width = @max(x1 - x0, 1), .height = lh } }, theme.accent.opacity(0.22)));
        }
    }

    // Selection.
    const sel = ed.core.sel.range();
    if (!sel.isEmpty() and sel.start <= info.end and sel.end >= info.start) {
        const s0 = @max(sel.start, info.start);
        const s1 = @min(sel.end, info.end);
        const x0 = xFor(shaped_opt, info.toDisplay(s0 - info.start), cw);
        var x1 = xFor(shaped_opt, info.toDisplay(s1 - info.start), cw);
        // The newline (or wrap continuation) is selected: extend one column.
        if (sel.end > info.end and info.last_sub) x1 += cw * 0.5;
        if (sel.end > info.end and !info.last_sub) x1 = @max(x1, row_end_x);
        if (x1 > x0) {
            const color = if (window.isWindowActive()) theme.accent.opacity(0.22) else theme.accent.opacity(0.14);
            window.paintQuad(zpui.fill(.{ .origin = .{ .x = ox + x0, .y = bounds.origin.y }, .size = .{ .width = x1 - x0, .height = lh } }, color));
        }
    }

    if (shaped_opt) |shaped| shaped.paint(painter, .{ .x = ox, .y = bounds.origin.y }, lh, .left, null) catch {};

    // Caret.
    const caret_on = blk: {
        if (!focused or !window.isWindowActive()) break :blk false;
        if (window.prefersReducedMotion()) break :blk true;
        const elapsed_ms = (cx.app.executor.now() -| ed.blink_anchor) / std.time.ns_per_ms;
        break :blk (elapsed_ms / caret_blink_ms) % 2 == 0;
    };
    if (caret_on and head >= info.start and head <= info.end) {
        // At a soft-wrap boundary the caret draws at the next row's start.
        const at_wrap_end = head == info.end and !info.last_sub;
        if (!at_wrap_end) {
            const x = xFor(shaped_opt, info.toDisplay(head - info.start), cw);
            window.paintQuad(zpui.fill(.{ .origin = .{ .x = ox + x, .y = bounds.origin.y }, .size = .{ .width = caret_width, .height = lh } }, theme.caret));
        }
    }
}

/// Indent (in columns) whose guides row `line` shows.
fn guideIndent(ed: *FileEditor, line: usize) usize {
    var l = line;
    var steps: usize = 0;
    while (true) {
        const r = ed.core.buffer.lineRange(l);
        if (r.end > r.start) {
            const t = ed.core.buffer.slice(r.start, @min(r.end, r.start + 512), &ed.wrap_scratch, ed.gpa);
            var cols: usize = 0;
            for (t) |ch| {
                if (ch == ' ') cols += 1 else if (ch == '\t') cols += ed.core.tab_size else break;
            }
            return cols;
        }
        if (l == 0 or steps > 64) return 0;
        l -= 1;
        steps += 1;
    }
}

fn buildRuns(ed: *FileEditor, info: FileEditor.RowInfo, font: zpui.text.Font, fg: Hsla, theme: *const Theme, out: *std.ArrayList(zpui.text.TextRun), a: Allocator) void {
    if (info.text.len == 0) return;
    const line_start = ed.core.buffer.lineStart(info.line);
    const seg0 = info.start - line_start;
    const seg1 = info.end - line_start;
    const spans = ed.highlights.spans(info.line);
    const marked = ed.core.marked;
    var cursor: usize = 0; // display index
    const push = struct {
        fn f(list: *std.ArrayList(zpui.text.TextRun), al: Allocator, len: usize, fnt: zpui.text.Font, color: Hsla) void {
            if (len == 0) return;
            list.append(al, .{ .len = len, .font = fnt, .color = color }) catch {};
        }
    }.f;
    for (spans) |sp| {
        if (sp.end <= seg0 or sp.start >= seg1) continue;
        const s = info.toDisplay(@max(sp.start, seg0) - seg0);
        const e = info.toDisplay(@min(sp.end, seg1) - seg0);
        if (s < cursor or e <= s) continue;
        push(out, a, s - cursor, font, fg);
        push(out, a, e - s, font, theme.syntax.color(sp.kind.themeKey(zt.theme.HighlightKind)));
        cursor = e;
    }
    push(out, a, info.text.len - cursor, font, fg);
    // IME composition: underline the marked range.
    if (marked) |m| if (m.start < info.end and m.end > info.start) {
        const ms = info.toDisplay(@max(m.start, info.start) - info.start);
        const me = info.toDisplay(@min(m.end, info.end) - info.start);
        var pos: usize = 0;
        var split: std.ArrayList(zpui.text.TextRun) = .empty;
        for (out.items) |r| {
            const r0 = pos;
            const r1 = pos + r.len;
            pos = r1;
            const cuts = [_]usize{ r0, @max(r0, @min(ms, r1)), @max(r0, @min(me, r1)), r1 };
            for (0..3) |k| {
                const len = cuts[k + 1] - cuts[k];
                if (len == 0) continue;
                var nr = r;
                nr.len = len;
                if (k == 1) nr.underline = .{ .color = r.color, .thickness = 1, .wavy = false };
                split.append(a, nr) catch {};
            }
        }
        out.* = split;
    };
}
