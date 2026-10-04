//! `TextInput`: zeron's hand-written text editor view — a port of Rust
//! `ComposerInput` + `ComposerTextElement` (`crates/ui/src/composer.rs`
//! :1826–4850). Multiline soft-wrapped (auto-grow up to a viewport cap, then
//! internal scrolling with caret follow and 12px edge fades) or single-line
//! (horizontal caret reveal), with:
//!
//! - every `composer::*` editing action (`zeron_actions.composer`), bound by
//!   `zeron_actions.keymap` in the `Composer` / `MessageComposer` /
//!   `PaletteSearch` key contexts exactly like Rust;
//! - mouse: click to place (soft-wrap affinity aware), shift-click extends,
//!   double-click selects a word, triple-click a line, drag selection keeps
//!   the multi-click unit and autoscrolls past the edges (16 ms ticks, at most
//!   one row per tick);
//! - clipboard copy/cut/paste (pastes are their own undo steps; pasted file
//!   URI lists surface as `pasted_paths` for the attachment hook);
//! - IME: the zpui `ElementInputHandler` protocol with UTF-16 ranges, marked
//!   text underlined, candidate window placed via `boundsForRange`;
//! - placeholder, inline completion ghost, caret blink (500 ms half-period,
//!   solid while typing; steady under reduced motion), wheel scrolling with
//!   overscroll containment.
//!
//! Not ported here (they live in the composer layer or are later work): file
//! mention chips and their projection, Markdown faces / list indentation,
//! dictation capture (the action only emits `toggle_dictation`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const actions = @import("zeron_actions");
const editor_mod = @import("editor.zig");
const seg = @import("segment.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Hsla = zpui.Hsla;
const Pixels = zpui.Pixels;
const Point = zpui.Point(Pixels);
const Size = zpui.Size(Pixels);
const Bounds = zpui.Bounds(Pixels);
const WrappedLine = zpui.text.WrappedLine;
const input = zpui.input;
const div = zpui.div;
const px = zpui.px;
const A = actions.composer;

pub const EditorState = editor_mod.EditorState;
pub const Range = editor_mod.Range;
pub const CaretAffinity = editor_mod.CaretAffinity;

/// Caret blink half-period (`CARET_BLINK_MS`).
pub const caret_blink_ms: u64 = 500;
/// Drag-selection autoscroll cadence (`DRAG_SCROLL_FRAME_MS`).
pub const drag_scroll_frame_ms: u64 = 16;
/// Composer input metrics: `text-[14px] leading-relaxed` (14 × 1.625).
pub const default_text_size: f32 = 14;
pub const default_line_height: f32 = 22.75;
/// Scroll fade band at the top / bottom of an overflowing input.
pub const fade_band: f32 = 12;
/// Default content cap: `TEXTAREA_MAX - TEXTAREA_PAD_V`.
pub const default_max_content_height: f32 = 240;

/// Caret blink phase for the time since the last keystroke / caret move:
/// solid through the first half-period, then alternating (`caret_visible`).
pub fn caretVisible(ms_since_activity: u64) bool {
    return (ms_since_activity / caret_blink_ms) % 2 == 0;
}

pub fn inputMaxScroll(content_height: f32, viewport_height: f32) f32 {
    return @max(content_height - viewport_height, 0);
}

/// Only settled overflow gets a scroll fade (`input_overflow_edges`).
pub fn inputOverflowEdges(content_height: f32, settled_height: f32, visible_height: f32, scroll_top: f32) struct { bool, bool } {
    if (inputMaxScroll(content_height, settled_height) <= 1.0) return .{ false, false };
    const max_scroll = inputMaxScroll(content_height, visible_height);
    return .{ scroll_top > 1.0, scroll_top < max_scroll - 1.0 };
}

/// During a height reveal, stop at a complete row boundary (`input_reveal_height`).
pub fn inputRevealHeight(visible: f32, scroll: f32, line_height: f32, resizing: bool) f32 {
    if (!resizing) return visible;
    const row_end = @floor((scroll + visible + 0.001) / line_height) * line_height;
    return std.math.clamp(row_end - scroll, 0, visible);
}

/// Apply a wheel delta to a top-origin offset (`input_scroll_offset`).
pub fn inputScrollOffset(current: f32, delta_y: f32, content_height: f32, viewport_height: f32) f32 {
    return std.math.clamp(current - delta_y, 0, inputMaxScroll(content_height, viewport_height));
}

/// Minimally adjust the viewport so the caret row is fully visible
/// (`input_scroll_offset_for_cursor`).
pub fn inputScrollOffsetForCursor(current: f32, cursor_top: f32, cursor_height: f32, content_height: f32, viewport_height: f32, settled_height: ?f32) f32 {
    const vh = settled_height orelse viewport_height;
    var next = current;
    if (cursor_top < next) {
        next = cursor_top;
    } else if (cursor_top + cursor_height > next + vh) {
        next = cursor_top + cursor_height - vh;
    }
    return std.math.clamp(next, 0, inputMaxScroll(content_height, vh));
}

/// Per-frame drag-selection scroll: distance increases speed, capped at one
/// text row per frame (`input_drag_scroll_delta`).
pub fn inputDragScrollDelta(pointer_y: f32, viewport_top: f32, viewport_bottom: f32, line_height: f32) f32 {
    const distance = if (pointer_y < viewport_top)
        pointer_y - viewport_top
    else if (pointer_y > viewport_bottom)
        pointer_y - viewport_bottom
    else
        return 0;
    return std.math.sign(distance) * std.math.clamp(@abs(distance) * 0.2, 1.0, line_height);
}

pub const PressIntent = enum { word, line, extend_selection, place_caret };

pub fn pressIntent(click_count: u32, shift: bool) PressIntent {
    if (click_count >= 3) return .line;
    if (click_count == 2) return .word;
    if (shift) return .extend_selection;
    return .place_caret;
}

pub const Colors = struct {
    text: Hsla,
    placeholder: Hsla,
    caret: Hsla,
    selection: Hsla,
    ghost: Hsla,

    pub fn fromTheme(theme: *const zt.Theme) Colors {
        return .{
            .text = theme.text,
            .placeholder = theme.text_faint,
            .caret = theme.caret,
            .selection = theme.selection,
            .ghost = theme.text_faint,
        };
    }
};

pub const Options = struct {
    placeholder: []const u8 = "",
    /// Key context for the binding map: "Composer", "MessageComposer" or
    /// "PaletteSearch" (static string).
    key_context: []const u8 = "Composer",
    single_line: bool = false,
    /// Text metrics in UI pixels at the default 16px rem (scaled with rem).
    text_size: f32 = default_text_size,
    line_height: f32 = default_line_height,
    /// Content height cap before internal scrolling (multiline).
    max_content_height: f32 = default_max_content_height,
    font_family: []const u8 = zt.typography.font_sans,
    colors: ?Colors = null,
    /// Fade the top/bottom edges when the content overflows.
    edge_fade: bool = true,
    /// Clipboard images beat text on paste (`pasted_image`; the composer).
    paste_images: bool = false,
};

pub const TextInputEvent = union(enum) {
    edited,
    cursor_moved,
    viewport_changed,
    /// Enter (or the configured send chord) with no completion open.
    submitted,
    modified_submitted,
    /// Up/Down/Enter/Tab/Escape while the owner's completion list is open.
    mention_navigate: i8,
    mention_accept,
    mention_dismiss,
    /// File paths were pasted (read them with `pastedPaths()`).
    pasted_paths,
    /// Image data was pasted (take it with `takePastedImage()`).
    pasted_image,
    /// Plain text was pasted into `[start, end)` at `revision`.
    pasted_text: struct { start: usize, end: usize, revision: u64 },
    toggle_dictation,
    /// Tab / Shift-Tab with nothing for the editor to do (owners may move focus).
    tab: struct { shift: bool },
    escape,
};

pub const TextInput = struct {
    gpa: Allocator,
    state: EditorState,
    focus: zpui.FocusHandle,
    key_context: []const u8,
    placeholder: std.ArrayList(u8) = .empty,
    colors: Colors,
    font_family: []const u8,
    text_size: f32,
    configured_line_height: f32,
    max_content_height: f32,
    edge_fade: bool,

    // ---- measured layout (written during layout / prepaint) ----
    lines: []WrappedLine = &.{},
    line_starts: std.ArrayList(usize) = .empty,
    line_height: f32,
    font_size: f32 = default_text_size,
    content_height: f32,
    max_line_width: f32 = 0,
    last_width: f32 = 0,
    display_is_placeholder: bool = true,
    needs_measure: bool = true,
    layout_key: ?LayoutKey = null,
    /// Bumped once per layout pass (owners apply at most one flip per pass).
    layout_epoch: u64 = 0,
    last_bounds: ?Bounds = null,
    last_notified_layout: ?[2]f32 = null,

    // ---- viewport ----
    scroll_top: f32 = 0,
    scroll_left: f32 = 0,
    follow_cursor: bool = true,
    /// Visible content budget supplied by an animating owner (composer).
    viewport_height: ?f32 = null,
    /// Final content budget, excluding temporary overflow during a resize.
    settled_viewport_height: ?f32 = null,
    resizing: bool = false,
    overflow_top_padding: f32 = 0,

    // ---- pointer ----
    is_selecting: bool = false,
    drag_position: ?Point = null,
    drag_unit: ?struct { line: bool, range: Range } = null,
    drag_generation: u64 = 0,
    drag_task: zpui.Task(void) = .none,

    // ---- caret blink ----
    blink_anchor: u64 = 0,
    blink_task: zpui.Task(void) = .none,
    blink_generation: u64 = 0,

    /// Inline completion preview painted after the text (owned).
    ghost: std.ArrayList(u8) = .empty,
    /// The owner's completion list state (redirects Up/Down/Enter/Tab).
    mention_open: bool = false,
    mention_has_selection: bool = false,
    pasted_paths: std.ArrayList([]u8) = .empty,
    paste_images: bool = false,
    pasted_image: ?zpui.platform.ClipboardImage = null,

    pub const Events = .{TextInputEvent};

    const LayoutKey = struct {
        width: f32,
        font_size: f32,
        line_height: f32,
        revision: u64,
        marked: ?Range,
        placeholder_len: usize,
        placeholder_ptr: usize,
        color: [4]f32,
        single_line: bool,
    };

    pub fn init(opts: Options, cx: *Context(TextInput)) !TextInput {
        const gpa = cx.gpa();
        var self: TextInput = .{
            .gpa = gpa,
            .state = .init(gpa),
            .focus = cx.focusHandle().tabStop(true),
            .key_context = opts.key_context,
            .colors = opts.colors orelse Colors.fromTheme(&zt.Theme.forSelection(&zt.registry.builtin, .{ .appearance = .dark, .variant_id = "zeron-dark" })),
            .font_family = opts.font_family,
            .text_size = opts.text_size,
            .configured_line_height = opts.line_height,
            .max_content_height = opts.max_content_height,
            .edge_fade = opts.edge_fade,
            .paste_images = opts.paste_images,
            .line_height = opts.line_height,
            .content_height = opts.line_height,
        };
        self.state.single_line = opts.single_line;
        try self.placeholder.appendSlice(gpa, opts.placeholder);
        self.blink_anchor = cx.app.executor.now();
        return self;
    }

    pub fn deinit(self: *TextInput, cx: *App) void {
        self.blink_task.cancel();
        self.drag_task.cancel();
        self.focus.release(cx);
        self.state.deinit();
        zpui.text.freeLines(self.gpa, self.lines);
        self.line_starts.deinit(self.gpa);
        self.placeholder.deinit(self.gpa);
        self.ghost.deinit(self.gpa);
        self.clearPastedPaths();
        self.pasted_paths.deinit(self.gpa);
        if (self.pasted_image) |img| self.gpa.free(img.bytes);
    }

    /// The image of the last `pasted_image` event (caller owns `bytes`).
    pub fn takePastedImage(self: *TextInput) ?zpui.platform.ClipboardImage {
        defer self.pasted_image = null;
        return self.pasted_image;
    }

    fn clearPastedPaths(self: *TextInput) void {
        for (self.pasted_paths.items) |p| self.gpa.free(p);
        self.pasted_paths.clearRetainingCapacity();
    }

    // ---- public API ---------------------------------------------------------------------

    pub fn text(self: *const TextInput) []const u8 {
        return self.state.text();
    }

    pub fn isEmpty(self: *const TextInput) bool {
        return self.state.isEmpty();
    }

    pub fn hasNewline(self: *const TextInput) bool {
        return self.state.hasNewline();
    }

    pub fn isSingleLine(self: *const TextInput) bool {
        return self.state.single_line;
    }

    /// Unwrapped width of the widest line (feeds the composer's compact /
    /// expanded flip).
    pub fn measuredTextWidth(self: *const TextInput) f32 {
        return self.max_line_width;
    }

    pub fn measuredContentHeight(self: *const TextInput) f32 {
        return self.content_height;
    }

    pub fn pastedPaths(self: *const TextInput) []const []const u8 {
        return @ptrCast(self.pasted_paths.items);
    }

    pub fn cursorOffset(self: *const TextInput) usize {
        return self.state.cursor();
    }

    pub fn focusHandle(self: *const TextInput) zpui.FocusHandle {
        return self.focus;
    }

    pub fn isFocused(self: *const TextInput, window: *const Window) bool {
        return self.focus.isFocused(window);
    }

    /// Replace the document (draft load, clear-on-submit): history resets.
    pub fn setText(self: *TextInput, new_text: []const u8, cx: *Context(TextInput)) void {
        self.state.setText(new_text) catch @panic("OOM");
        self.scroll_top = 0;
        self.scroll_left = 0;
        self.afterEdit(cx);
    }

    pub fn setPlaceholder(self: *TextInput, placeholder: []const u8, cx: *Context(TextInput)) void {
        if (std.mem.eql(u8, placeholder, self.placeholder.items)) return;
        self.placeholder.clearRetainingCapacity();
        self.placeholder.appendSlice(self.gpa, placeholder) catch @panic("OOM");
        self.needs_measure = true;
        self.layout_key = null;
        cx.notify();
    }

    pub fn setColors(self: *TextInput, colors: Colors, cx: *Context(TextInput)) void {
        self.colors = colors;
        self.needs_measure = true;
        cx.notify();
    }

    pub fn setKeyContext(self: *TextInput, key_context: []const u8, cx: *Context(TextInput)) void {
        if (std.mem.eql(u8, self.key_context, key_context)) return;
        self.key_context = key_context;
        cx.notify();
    }

    pub fn setReadOnly(self: *TextInput, read_only: bool, cx: *Context(TextInput)) void {
        self.state.read_only = read_only;
        cx.notify();
    }

    /// Set (or clear) the inline completion preview; it only paints while the
    /// caret sits at the end of a non-empty draft.
    pub fn setGhost(self: *TextInput, ghost: ?[]const u8, cx: *Context(TextInput)) void {
        const g = ghost orelse "";
        if (std.mem.eql(u8, g, self.ghost.items)) return;
        self.ghost.clearRetainingCapacity();
        self.ghost.appendSlice(self.gpa, g) catch @panic("OOM");
        cx.notify();
    }

    pub fn setMentionControls(self: *TextInput, open: bool, has_selection: bool, cx: *Context(TextInput)) void {
        if (self.mention_open == open and self.mention_has_selection == has_selection) return;
        self.mention_open = open;
        self.mention_has_selection = has_selection;
        cx.notify();
    }

    /// Viewport supplied by an animating owner (the composer's morph).
    pub fn setViewport(self: *TextInput, height: ?f32, settled: ?f32, resizing: bool, top_padding: f32, cx: *Context(TextInput)) void {
        if (std.meta.eql(self.viewport_height, height) and std.meta.eql(self.settled_viewport_height, settled) and
            self.resizing == resizing and self.overflow_top_padding == top_padding) return;
        self.viewport_height = height;
        self.settled_viewport_height = settled;
        self.resizing = resizing;
        self.overflow_top_padding = top_padding;
        cx.notify();
    }

    pub fn selectAllText(self: *TextInput, cx: *Context(TextInput)) void {
        self.state.selectAll();
        self.afterMove(cx);
    }

    /// Replace `[start, end)` (UTF-8) with `replacement` as one undo step and
    /// put the caret after it (completion acceptance).
    pub fn replaceRange(self: *TextInput, start: usize, stop: usize, replacement: []const u8, cx: *Context(TextInput)) void {
        self.state.breakUndoRun();
        _ = self.state.replace(.{ .start = start, .end = stop }, replacement, self.now(cx)) catch @panic("OOM");
        self.state.breakUndoRun();
        self.afterEdit(cx);
    }

    /// Insert text at the selection as one undo step (drops, dictation).
    pub fn insertText(self: *TextInput, s: []const u8, cx: *Context(TextInput)) void {
        if (!(self.state.insertAsStep(s, self.now(cx)) catch @panic("OOM"))) return;
        self.afterEdit(cx);
    }

    pub fn focusIn(self: *TextInput, window: *Window) void {
        window.focus(self.focus);
    }

    // ---- bookkeeping -------------------------------------------------------------------

    fn now(_: *const TextInput, cx: anytype) u64 {
        return cx.app.executor.now();
    }

    fn resetBlink(self: *TextInput, cx: anytype) void {
        self.blink_anchor = self.now(cx);
    }

    fn afterEdit(self: *TextInput, cx: *Context(TextInput)) void {
        self.follow_cursor = true;
        self.needs_measure = true;
        self.resetBlink(cx);
        cx.emit(TextInputEvent{ .edited = {} });
        cx.notify();
    }

    fn afterMove(self: *TextInput, cx: *Context(TextInput)) void {
        self.follow_cursor = true;
        self.resetBlink(cx);
        cx.emit(TextInputEvent{ .cursor_moved = {} });
        cx.notify();
    }

    fn edit(self: *TextInput, changed: Allocator.Error!bool, cx: *Context(TextInput)) void {
        if (changed catch @panic("OOM")) self.afterEdit(cx);
    }

    // ---- actions -----------------------------------------------------------------------

    fn backspace(self: *TextInput, _: *const A.Backspace, _: *Window, cx: *Context(TextInput)) void {
        self.edit(self.state.backspace(self.now(cx)), cx);
    }
    fn delete(self: *TextInput, _: *const A.Delete, _: *Window, cx: *Context(TextInput)) void {
        self.edit(self.state.delete(self.now(cx)), cx);
    }
    fn left(self: *TextInput, _: *const A.Left, _: *Window, cx: *Context(TextInput)) void {
        self.state.left();
        self.afterMove(cx);
    }
    fn right(self: *TextInput, _: *const A.Right, _: *Window, cx: *Context(TextInput)) void {
        self.state.right();
        self.afterMove(cx);
    }
    fn up(self: *TextInput, _: *const A.Up, _: *Window, cx: *Context(TextInput)) void {
        if (self.mention_has_selection) return cx.emit(TextInputEvent{ .mention_navigate = -1 });
        self.vertical(-1, false, cx);
    }
    fn down(self: *TextInput, _: *const A.Down, _: *Window, cx: *Context(TextInput)) void {
        if (self.mention_has_selection) return cx.emit(TextInputEvent{ .mention_navigate = 1 });
        self.vertical(1, false, cx);
    }
    fn selectUp(self: *TextInput, _: *const A.SelectUp, _: *Window, cx: *Context(TextInput)) void {
        self.vertical(-1, true, cx);
    }
    fn selectDown(self: *TextInput, _: *const A.SelectDown, _: *Window, cx: *Context(TextInput)) void {
        self.vertical(1, true, cx);
    }
    fn vertical(self: *TextInput, dir: f32, select: bool, cx: *Context(TextInput)) void {
        const t = self.verticalTarget(dir) orelse return;
        if (select) self.state.selectTo(t.index) else self.state.moveTo(t.index);
        self.state.affinity = t.affinity;
        self.state.preferred_column = t.column;
        self.afterMove(cx);
    }
    fn selectLeft(self: *TextInput, _: *const A.SelectLeft, _: *Window, cx: *Context(TextInput)) void {
        self.state.selectLeft();
        self.afterMove(cx);
    }
    fn selectRight(self: *TextInput, _: *const A.SelectRight, _: *Window, cx: *Context(TextInput)) void {
        self.state.selectRight();
        self.afterMove(cx);
    }
    fn selectAll(self: *TextInput, _: *const A.SelectAll, _: *Window, cx: *Context(TextInput)) void {
        self.selectAllText(cx);
    }
    fn home(self: *TextInput, _: *const A.Home, _: *Window, cx: *Context(TextInput)) void {
        self.state.home();
        self.afterMove(cx);
    }
    fn end(self: *TextInput, _: *const A.End, _: *Window, cx: *Context(TextInput)) void {
        self.state.end();
        self.afterMove(cx);
    }
    fn selectHome(self: *TextInput, _: *const A.SelectHome, _: *Window, cx: *Context(TextInput)) void {
        self.state.selectHome();
        self.afterMove(cx);
    }
    fn selectEnd(self: *TextInput, _: *const A.SelectEnd, _: *Window, cx: *Context(TextInput)) void {
        self.state.selectEnd();
        self.afterMove(cx);
    }
    fn docStart(self: *TextInput, _: *const A.DocStart, _: *Window, cx: *Context(TextInput)) void {
        self.state.docStart();
        self.afterMove(cx);
    }
    fn docEnd(self: *TextInput, _: *const A.DocEnd, _: *Window, cx: *Context(TextInput)) void {
        self.state.docEnd();
        self.afterMove(cx);
    }
    fn selectDocStart(self: *TextInput, _: *const A.SelectDocStart, _: *Window, cx: *Context(TextInput)) void {
        self.state.selectDocStart();
        self.afterMove(cx);
    }
    fn selectDocEnd(self: *TextInput, _: *const A.SelectDocEnd, _: *Window, cx: *Context(TextInput)) void {
        self.state.selectDocEnd();
        self.afterMove(cx);
    }
    fn wordLeft(self: *TextInput, _: *const A.WordLeft, _: *Window, cx: *Context(TextInput)) void {
        self.state.wordLeft();
        self.afterMove(cx);
    }
    fn wordRight(self: *TextInput, _: *const A.WordRight, _: *Window, cx: *Context(TextInput)) void {
        self.state.wordRight();
        self.afterMove(cx);
    }
    fn selectWordLeft(self: *TextInput, _: *const A.SelectWordLeft, _: *Window, cx: *Context(TextInput)) void {
        self.state.selectWordLeft();
        self.afterMove(cx);
    }
    fn selectWordRight(self: *TextInput, _: *const A.SelectWordRight, _: *Window, cx: *Context(TextInput)) void {
        self.state.selectWordRight();
        self.afterMove(cx);
    }
    fn deleteWordLeft(self: *TextInput, _: *const A.DeleteWordLeft, _: *Window, cx: *Context(TextInput)) void {
        self.edit(self.state.deleteWordLeft(self.now(cx)), cx);
    }
    fn deleteWordRight(self: *TextInput, _: *const A.DeleteWordRight, _: *Window, cx: *Context(TextInput)) void {
        self.edit(self.state.deleteWordRight(self.now(cx)), cx);
    }
    fn deleteToLineStart(self: *TextInput, _: *const A.DeleteToLineStart, _: *Window, cx: *Context(TextInput)) void {
        self.edit(self.state.deleteToLineStart(self.now(cx)), cx);
    }
    fn deleteToLineEnd(self: *TextInput, _: *const A.DeleteToLineEnd, _: *Window, cx: *Context(TextInput)) void {
        self.edit(self.state.deleteToLineEnd(self.now(cx)), cx);
    }

    fn copy(self: *TextInput, _: *const A.Copy, _: *Window, cx: *Context(TextInput)) void {
        if (self.state.selected.isEmpty()) return;
        writeClipboard(cx.app, self.state.selectedText());
    }

    fn cut(self: *TextInput, _: *const A.Cut, _: *Window, cx: *Context(TextInput)) void {
        if (self.state.read_only or self.state.selected.isEmpty()) return;
        writeClipboard(cx.app, self.state.selectedText());
        self.state.breakUndoRun();
        self.edit(self.state.replace(null, "", self.now(cx)), cx);
        self.state.breakUndoRun();
    }

    fn paste(self: *TextInput, _: *const A.Paste, _: *Window, cx: *Context(TextInput)) void {
        if (self.state.read_only) return;
        // Image data beats text (the original composer's onPaste stages the
        // images and skips the text insert).
        if (self.paste_images) if (cx.app.platform.readClipboardImage(self.gpa)) |img| {
            if (self.pasted_image) |old| self.gpa.free(old.bytes);
            self.pasted_image = img;
            cx.emit(TextInputEvent{ .pasted_image = {} });
            return;
        };
        const clip = readClipboard(cx.app, self.gpa) orelse return;
        defer self.gpa.free(clip);
        self.pasteText(clip, cx);
    }

    /// Paste `clip` as the clipboard would deliver it: a `file://` URI list
    /// (a file manager "Copy") becomes `pasted_paths`; text inserts as its
    /// own undo step and reports `pasted_text`.
    pub fn pasteText(self: *TextInput, clip: []const u8, cx: *Context(TextInput)) void {
        if (self.collectFileUris(clip)) {
            cx.emit(TextInputEvent{ .pasted_paths = {} });
            return;
        }
        if (clip.len == 0) return;
        if (!(self.state.insertAsStep(clip, self.now(cx)) catch @panic("OOM"))) return;
        self.afterEdit(cx);
        if (!self.state.single_line) {
            const e = self.state.cursor();
            cx.emit(TextInputEvent{ .pasted_text = .{ .start = e -| clip.len, .end = e, .revision = self.state.revision } });
        }
    }

    fn collectFileUris(self: *TextInput, clip: []const u8) bool {
        var it = std.mem.tokenizeAny(u8, clip, "\r\n");
        var any = false;
        while (it.next()) |line| {
            if (line[0] == '#') continue; // text/uri-list comments
            if (!std.mem.startsWith(u8, line, "file://")) return false;
            any = true;
        }
        if (!any) return false;
        self.clearPastedPaths();
        it.reset();
        while (it.next()) |line| {
            if (line[0] == '#') continue;
            var rest = line["file://".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[slash..]; // drop the host
            const decoded = percentDecode(self.gpa, rest) catch @panic("OOM");
            self.pasted_paths.append(self.gpa, decoded) catch @panic("OOM");
        }
        return true;
    }

    fn newline(self: *TextInput, _: *const A.Newline, _: *Window, cx: *Context(TextInput)) void {
        self.insertNewline(cx);
    }

    fn insertNewline(self: *TextInput, cx: *Context(TextInput)) void {
        if (self.state.single_line) return;
        const nl = self.state.newlineText();
        self.edit(self.state.replace(null, nl, self.now(cx)), cx);
    }

    fn messageNewlineOrAccept(self: *TextInput, _: *const A.MessageNewlineOrAccept, _: *Window, cx: *Context(TextInput)) void {
        if (self.mention_has_selection) return cx.emit(TextInputEvent{ .mention_accept = {} });
        self.insertNewline(cx);
    }

    fn submit(self: *TextInput, _: *const A.Submit, _: *Window, cx: *Context(TextInput)) void {
        if (self.mention_has_selection) return cx.emit(TextInputEvent{ .mention_accept = {} });
        cx.emit(TextInputEvent{ .submitted = {} });
    }

    fn modifiedSubmit(self: *TextInput, _: *const A.ModifiedSubmit, _: *Window, cx: *Context(TextInput)) void {
        if (self.mention_has_selection) return cx.emit(TextInputEvent{ .mention_accept = {} });
        cx.emit(TextInputEvent{ .modified_submitted = {} });
    }

    fn mentionTab(self: *TextInput, _: *const A.MentionTab, _: *Window, cx: *Context(TextInput)) void {
        if (self.mention_has_selection) return cx.emit(TextInputEvent{ .mention_accept = {} });
        cx.emit(TextInputEvent{ .tab = .{ .shift = false } });
        cx.propagate();
    }

    fn outdentList(_: *TextInput, _: *const A.OutdentList, _: *Window, cx: *Context(TextInput)) void {
        cx.emit(TextInputEvent{ .tab = .{ .shift = true } });
        cx.propagate();
    }

    fn toggleDictation(_: *TextInput, _: *const A.ToggleDictation, _: *Window, cx: *Context(TextInput)) void {
        cx.emit(TextInputEvent{ .toggle_dictation = {} });
    }

    fn undoAction(self: *TextInput, _: *const A.Undo, _: *Window, cx: *Context(TextInput)) void {
        self.edit(self.state.undo(), cx);
    }

    fn redoAction(self: *TextInput, _: *const A.Redo, _: *Window, cx: *Context(TextInput)) void {
        self.edit(self.state.redo(), cx);
    }

    fn onKeyDown(self: *TextInput, ev: *const input.KeyDownEvent, _: *Window, cx: *Context(TextInput)) void {
        if (std.mem.eql(u8, ev.keystroke.key, "escape")) {
            if (self.mention_open) {
                cx.emit(TextInputEvent{ .mention_dismiss = {} });
                cx.stopPropagation();
            } else cx.emit(TextInputEvent{ .escape = {} });
        }
    }

    // ---- geometry ----------------------------------------------------------------------

    fn wrapIndex(line: WrappedLine, b: zpui.text.WrapBoundary) usize {
        return zpui.text.line_layout.glyphAt(line.layout.layout(), b).index;
    }

    /// Content-local caret position for byte `index` with soft-wrap affinity.
    pub fn pointForIndex(self: *const TextInput, index: usize, affinity: CaretAffinity) ?Point {
        var y_offset: f32 = 0;
        for (self.lines, 0..) |line, line_ix| {
            const line_start = self.line_starts.items[line_ix];
            const line_len = line.len();
            if (index < line_start) return null;
            if (index <= line_start + line_len) {
                const rel = index - line_start;
                var local: ?Point = null;
                if (affinity == .downstream) {
                    for (line.wrapBoundaries(), 0..) |b, row| {
                        if (wrapIndex(line, b) == rel) {
                            local = .{ .x = 0, .y = self.line_height * @as(f32, @floatFromInt(row + 1)) };
                            break;
                        }
                    }
                }
                const p = local orelse line.positionForIndex(rel, self.line_height) orelse return null;
                return .{ .x = p.x, .y = p.y + y_offset };
            }
            y_offset += line.size(self.line_height).height;
        }
        return null;
    }

    pub fn cursorPoint(self: *const TextInput) ?Point {
        return self.pointForIndex(self.state.cursor(), self.state.affinity);
    }

    pub const Caret = struct { index: usize, affinity: CaretAffinity };

    /// Byte index and visual side closest to a content-local point.
    pub fn caretForPoint(self: *const TextInput, position: Point) Caret {
        if (self.display_is_placeholder) return .{ .index = 0, .affinity = .downstream };
        var y = position.y;
        if (y < 0) return .{ .index = 0, .affinity = .downstream };
        for (self.lines, 0..) |line, line_ix| {
            const height = line.size(self.line_height).height;
            const line_start = self.line_starts.items[line_ix];
            if (y < height or line_ix + 1 == self.lines.len) {
                const local: Point = .{ .x = position.x, .y = @max(@min(y, height - 1), 0) };
                const ix = switch (line.closestIndexForPosition(local, self.line_height)) {
                    .inside, .outside => |i| i,
                };
                var affinity: CaretAffinity = .downstream;
                for (line.wrapBoundaries(), 0..) |b, row| {
                    if (wrapIndex(line, b) == ix and local.y < self.line_height * @as(f32, @floatFromInt(row + 1))) {
                        affinity = .upstream;
                        break;
                    }
                }
                var raw = @min(line_start + ix, self.state.text().len);
                const t = self.state.text();
                // CRLF is one newline grapheme: never land between its bytes.
                if (raw > 0 and raw < t.len and t[raw] == '\n' and t[raw - 1] == '\r') raw -= 1;
                return .{ .index = raw, .affinity = affinity };
            }
            y -= height;
        }
        return .{ .index = self.state.text().len, .affinity = .upstream };
    }

    fn caretForMousePosition(self: *const TextInput, position: Point) Caret {
        const b = self.last_bounds orelse return .{ .index = 0, .affinity = .downstream };
        return self.caretForPoint(.{
            .x = position.x - b.origin.x + self.scroll_left,
            .y = position.y - b.origin.y + self.scroll_top,
        });
    }

    const VerticalTarget = struct { index: usize, affinity: CaretAffinity, column: f32 };

    /// Offset one wrapped row above / below the caret, keeping its x column.
    fn verticalTarget(self: *const TextInput, dir: f32) ?VerticalTarget {
        const current = self.cursorPoint() orelse return null;
        const column = self.state.preferred_column orelse current.x;
        const target_y = current.y + dir * self.line_height;
        if (target_y < 0) return .{ .index = 0, .affinity = .downstream, .column = column };
        if (target_y >= self.content_height) return .{ .index = self.state.text().len, .affinity = .upstream, .column = column };
        const c = self.caretForPoint(.{ .x = column, .y = target_y });
        return .{ .index = c.index, .affinity = c.affinity, .column = column };
    }

    // ---- layout ------------------------------------------------------------------------

    fn remScale(window: *const Window) f32 {
        return window.remSize() / 16.0;
    }

    /// Shape the text at `width`; store the measured layout; return the
    /// content height (`layout_text`).
    pub fn layoutText(self: *TextInput, width: f32, window: *Window, cx: *Context(TextInput)) f32 {
        _ = cx;
        const scale = remScale(window);
        const font_size = self.text_size * scale;
        const line_height = self.configured_line_height * scale;
        const is_placeholder = self.state.isEmpty();
        const color = if (is_placeholder) self.colors.placeholder else self.colors.text;
        const key: LayoutKey = .{
            .width = width,
            .font_size = font_size,
            .line_height = line_height,
            .revision = self.state.revision,
            .marked = self.state.marked,
            .placeholder_len = self.placeholder.items.len,
            .placeholder_ptr = @intFromPtr(self.placeholder.items.ptr),
            .color = .{ color.h, color.s, color.l, color.a },
            .single_line = self.state.single_line,
        };
        if (!self.needs_measure) if (self.layout_key) |k| if (std.meta.eql(k, key)) {
            self.layout_epoch += 1;
            return self.content_height;
        };
        const display = if (is_placeholder) self.placeholder.items else self.state.text();
        var base_font = window.textStyle().font();
        base_font.family = self.font_family;
        base_font.weight = zpui.text.weight.normal;
        base_font.style = .normal;
        const base: zpui.text.TextRun = .{ .len = 0, .font = base_font, .color = color };
        var runs: [3]zpui.text.TextRun = undefined;
        var n_runs: usize = 0;
        if (!is_placeholder and self.state.marked != null) {
            const m = self.state.marked.?;
            const ms = @min(m.start, display.len);
            const me = @min(m.end, display.len);
            if (ms > 0) {
                runs[n_runs] = base;
                runs[n_runs].len = ms;
                n_runs += 1;
            }
            if (me > ms) {
                runs[n_runs] = base;
                runs[n_runs].len = me - ms;
                runs[n_runs].underline = .{ .color = color, .thickness = 1, .wavy = false };
                n_runs += 1;
            }
            if (display.len > me) {
                runs[n_runs] = base;
                runs[n_runs].len = display.len - me;
                n_runs += 1;
            }
        } else if (display.len > 0) {
            runs[0] = base;
            runs[0].len = display.len;
            n_runs = 1;
        }
        const wrap: ?f32 = if (self.state.single_line) null else @max(width, 20);
        const lines = window.text_system.shapeText(display, font_size, runs[0..n_runs], .{ .wrap_width = wrap }) catch @panic("OOM");
        zpui.text.freeLines(self.gpa, self.lines);
        self.lines = lines;
        self.line_starts.clearRetainingCapacity();
        var at: usize = 0;
        var content_height: f32 = 0;
        var max_w: f32 = 0;
        for (lines) |l| {
            self.line_starts.append(self.gpa, at) catch @panic("OOM");
            at += l.len() + 1;
            content_height += l.size(line_height).height;
            max_w = @max(max_w, l.layout.layout().width);
        }
        if (self.line_starts.items.len == 0) self.line_starts.append(self.gpa, 0) catch @panic("OOM");
        self.font_size = font_size;
        self.line_height = line_height;
        self.display_is_placeholder = is_placeholder;
        self.content_height = @max(content_height, line_height);
        self.max_line_width = if (is_placeholder) 0 else max_w;
        self.last_width = width;
        self.layout_key = key;
        self.needs_measure = false;
        self.layout_epoch += 1;
        return self.content_height;
    }

    /// The content cap: the owner's animated viewport, else the configured max.
    fn maxContent(self: *const TextInput) f32 {
        if (self.state.single_line) return self.line_height;
        return self.viewport_height orelse self.max_content_height;
    }

    fn paintBounds(self: *const TextInput, bounds: Bounds) Bounds {
        const visible = bounds.size.height;
        const edges = inputOverflowEdges(self.content_height, self.settled_viewport_height orelse visible, visible, self.scroll_top);
        const top_padding: f32 = if (edges[0]) self.overflow_top_padding else 0;
        const height = inputRevealHeight(visible, self.scroll_top, self.line_height, self.resizing);
        return .{
            .origin = .{ .x = bounds.origin.x, .y = bounds.origin.y - top_padding },
            .size = .{ .width = bounds.size.width, .height = height + top_padding },
        };
    }

    /// Keep the caret visible (`clamp_scroll`); returns whether it scrolled.
    fn clampScroll(self: *TextInput, element_height: f32) bool {
        if (self.state.single_line) {
            const prev = self.scroll_left;
            const w = @max(self.last_width - 2, 1);
            if (self.cursorPoint()) |c| self.scroll_left = @max(@max(@min(self.scroll_left, c.x), c.x - w), 0);
            self.scroll_left = @min(self.scroll_left, @max(self.max_line_width - w, 0));
            self.scroll_top = 0;
            return self.scroll_left != prev;
        }
        const prev = self.scroll_top;
        if (self.follow_cursor) if (self.cursorPoint()) |c| {
            self.scroll_top = inputScrollOffsetForCursor(self.scroll_top, c.y, self.line_height, self.content_height, element_height, self.settled_viewport_height);
        };
        self.scroll_top = std.math.clamp(self.scroll_top, 0, inputMaxScroll(self.content_height, self.settled_viewport_height orelse element_height));
        return self.scroll_top != prev;
    }

    fn prepaintLayout(self: *TextInput, bounds: Bounds, window: *Window, cx: *Context(TextInput)) void {
        _ = self.layoutText(bounds.size.width, window, cx);
        const layout: [2]f32 = .{ bounds.size.width, self.content_height };
        const changed = if (self.last_notified_layout) |l| !std.meta.eql(l, layout) else true;
        self.last_notified_layout = layout;
        const scrolled = self.clampScroll(bounds.size.height);
        self.last_bounds = bounds;
        if (scrolled or changed) cx.emit(TextInputEvent{ .viewport_changed = {} });
    }

    /// Caret paint gate: focused input in an active window, in the "on"
    /// blink phase. Arms the half-period repaint while focused.
    fn caretShown(self: *TextInput, window: *Window, cx: *Context(TextInput)) bool {
        if (!self.focus.isFocused(window) or !window.isWindowActive()) {
            self.blink_task.cancel();
            self.blink_task = .none;
            return false;
        }
        if (window.prefersReducedMotion()) return true;
        if (self.blink_task.header == null) {
            self.blink_task = cx.timer(caret_blink_ms * std.time.ns_per_ms, onBlink) catch .none;
        }
        const elapsed_ms = (self.now(cx) -| self.blink_anchor) / std.time.ns_per_ms;
        return caretVisible(elapsed_ms);
    }

    fn onBlink(self: *TextInput, cx: *Context(TextInput)) void {
        self.blink_task.detach();
        self.blink_task = .none;
        cx.notify(); // the next paint re-arms while still focused
    }

    // ---- pointer -----------------------------------------------------------------------

    fn onMouseDown(self: *TextInput, ev: *const input.MouseDownEvent, window: *Window, cx: *Context(TextInput)) void {
        window.focus(self.focus);
        const intent = pressIntent(ev.click_count, ev.modifiers.shift);
        self.is_selecting = true;
        self.drag_position = ev.position;
        self.drag_unit = null;
        self.drag_generation +%= 1;
        self.drag_task.cancel();
        self.drag_task = .none;
        switch (intent) {
            .word, .line => {
                const c = self.caretForMousePosition(ev.position);
                const range = self.state.selectionUnit(intent == .line, c.index);
                self.state.selectRange(range);
                self.drag_unit = .{ .line = intent == .line, .range = range };
            },
            .extend_selection => {
                const c = self.caretForMousePosition(ev.position);
                self.state.selectTo(c.index);
                self.state.affinity = c.affinity;
            },
            .place_caret => {
                const c = self.caretForMousePosition(ev.position);
                self.state.moveTo(c.index);
                self.state.affinity = c.affinity;
            },
        }
        self.afterMove(cx);
    }

    fn dragSelectTo(self: *TextInput, index: usize) void {
        if (self.drag_unit) |u| {
            const range = self.state.selectionUnit(u.line, index);
            if (range.start < u.range.start) {
                self.state.moveTo(u.range.end);
                self.state.selectTo(range.start);
            } else {
                self.state.moveTo(u.range.start);
                self.state.selectTo(@max(range.end, u.range.end));
            }
        } else self.state.selectTo(index);
    }

    fn dragSelectAt(self: *TextInput, position: Point) void {
        const c = self.caretForMousePosition(position);
        self.dragSelectTo(c.index);
        if (self.drag_unit == null) self.state.affinity = c.affinity;
    }

    fn onMouseUp(self: *TextInput, _: *const input.MouseUpEvent, _: *Window, _: *Context(TextInput)) void {
        self.is_selecting = false;
        self.drag_position = null;
        self.drag_generation +%= 1;
        self.drag_task.cancel();
        self.drag_task = .none;
    }

    fn onMouseDownOut(self: *TextInput, ev: *const input.MouseDownEvent, window: *Window, _: *Context(TextInput)) void {
        // Capture runs before the clicked control handles the press, so
        // another input can take focus normally during bubbling.
        if (ev.button == .left and self.focus.isFocused(window)) window.blur();
    }

    fn dragSelectionPosition(self: *const TextInput, position: Point) Point {
        const b = self.last_bounds orelse return position;
        return .{
            .x = std.math.clamp(position.x, b.origin.x, b.right() - 0.5),
            .y = std.math.clamp(position.y, b.origin.y, b.bottom() - 0.5),
        };
    }

    fn dragScrollDelta(self: *const TextInput, position: Point) f32 {
        const b = self.last_bounds orelse return 0;
        return inputDragScrollDelta(position.y, b.origin.y, b.bottom(), self.line_height);
    }

    fn onWindowMouseMove(self: *TextInput, ev: *const input.MouseMoveEvent, cx: *Context(TextInput)) void {
        if (!self.is_selecting) return;
        if (ev.pressed_button != .left) {
            // The button went up outside any listener.
            self.is_selecting = false;
            return;
        }
        self.drag_position = ev.position;
        self.dragSelectAt(self.dragSelectionPosition(ev.position));
        if (self.dragScrollDelta(ev.position) != 0 and self.drag_task.header == null) {
            self.drag_task = cx.timer(drag_scroll_frame_ms * std.time.ns_per_ms, onDragTick) catch .none;
        }
        self.afterMove(cx);
    }

    fn onDragTick(self: *TextInput, cx: *Context(TextInput)) void {
        self.drag_task.detach();
        self.drag_task = .none;
        if (!self.is_selecting) return;
        const pos = self.drag_position orelse return;
        const b = self.last_bounds orelse return;
        const delta = self.dragScrollDelta(pos);
        if (delta == 0) return;
        const next = std.math.clamp(self.scroll_top + delta, 0, inputMaxScroll(self.content_height, self.settled_viewport_height orelse b.size.height));
        if (next == self.scroll_top) return;
        self.scroll_top = next;
        self.dragSelectAt(self.dragSelectionPosition(pos));
        // During an edge drag the autoscroll loop owns the viewport.
        self.follow_cursor = false;
        cx.emit(TextInputEvent{ .viewport_changed = {} });
        cx.notify();
        self.drag_task = cx.timer(drag_scroll_frame_ms * std.time.ns_per_ms, onDragTick) catch .none;
    }

    fn onScrollWheel(self: *TextInput, ev: *const input.ScrollWheelEvent, _: *Window, cx: *Context(TextInput)) void {
        const b = self.last_bounds orelse return;
        const vh = self.settled_viewport_height orelse b.size.height;
        const delta_y = switch (ev.delta) {
            .pixels => |p| p.y,
            .lines => |l| l.y * self.line_height,
        };
        const next = inputScrollOffset(self.scroll_top, delta_y, self.content_height, vh);
        if (next == self.scroll_top) {
            // Overscroll containment: a scrollable input swallows the wheel
            // even at its boundary so it never chains into the transcript.
            if (delta_y != 0 and inputMaxScroll(self.content_height, vh) > 0) cx.stopPropagation();
            return;
        }
        self.scroll_top = next;
        self.follow_cursor = false;
        cx.stopPropagation();
        cx.emit(TextInputEvent{ .viewport_changed = {} });
        cx.notify();
    }

    // ---- IME (zpui ElementInputHandler protocol; UTF-16 ranges) ------------------------

    const IRange = zpui.window.input_handler.Range;
    const ISelection = zpui.window.input_handler.Selection;

    fn toI(r: Range) IRange {
        return .{ .start = r.start, .end = r.end };
    }
    fn fromI(r: IRange) Range {
        return .{ .start = r.start, .end = r.end };
    }

    pub fn selectedTextRange(self: *TextInput, _: *Window, _: *Context(TextInput)) ?ISelection {
        return .{ .range = toI(self.state.rangeToUtf16(self.state.selected)), .reversed = self.state.reversed };
    }

    pub fn markedTextRange(self: *TextInput, _: *Window, _: *Context(TextInput)) ?IRange {
        const m = self.state.marked orelse return null;
        return toI(self.state.rangeToUtf16(m));
    }

    pub fn textForRange(self: *TextInput, range: IRange, out: *std.ArrayList(u8), _: *Window, _: *Context(TextInput)) ?IRange {
        const r = self.state.rangeFromUtf16(fromI(range));
        out.appendSlice(self.gpa, self.state.text()[r.start..r.end]) catch return null;
        return toI(self.state.rangeToUtf16(r));
    }

    pub fn replaceTextInRange(self: *TextInput, range: ?IRange, new_text: []const u8, _: *Window, cx: *Context(TextInput)) void {
        const r: ?Range = if (range) |x| fromI(x) else null;
        self.edit(self.state.replaceUtf16(r, new_text, self.now(cx)), cx);
    }

    pub fn replaceAndMarkTextInRange(self: *TextInput, range: ?IRange, new_text: []const u8, new_selected: ?IRange, _: *Window, cx: *Context(TextInput)) void {
        const r: ?Range = if (range) |x| fromI(x) else null;
        const s: ?Range = if (new_selected) |x| fromI(x) else null;
        self.edit(self.state.replaceAndMarkUtf16(r, new_text, s), cx);
    }

    pub fn unmarkText(self: *TextInput, _: *Window, cx: *Context(TextInput)) void {
        if (self.state.unmark()) {
            self.needs_measure = true;
            cx.emit(TextInputEvent{ .cursor_moved = {} });
            cx.notify();
        }
    }

    /// Window-space caret box for an IME range: where the candidate window goes.
    pub fn boundsForRange(self: *TextInput, range: IRange, element_bounds: Bounds, _: *Window, _: *Context(TextInput)) ?Bounds {
        const r = self.state.rangeFromUtf16(fromI(range));
        const start = if (r.isEmpty() and r.start == self.state.cursor())
            self.cursorPoint() orelse return null
        else
            self.pointForIndex(r.start, .downstream) orelse return null;
        return .{
            .origin = .{ .x = element_bounds.origin.x + start.x - self.scroll_left, .y = element_bounds.origin.y + start.y - self.scroll_top },
            .size = .{ .width = 2, .height = self.line_height },
        };
    }

    pub fn acceptsTextInput(self: *TextInput, _: *Window, _: *Context(TextInput)) bool {
        return !self.state.read_only;
    }

    // ---- render ------------------------------------------------------------------------

    pub fn render(self: *TextInput, _: *Window, cx: *Context(TextInput)) zpui.StatefulDiv {
        return div().id(.{ "text-input", @intFromEnum(cx.entityId()) })
            .keyContext(self.key_context)
            .trackFocus(self.focus)
            .cursorText()
            .onAction(A.Backspace, cx.listener(TextInput.backspace))
            .onAction(A.Delete, cx.listener(TextInput.delete))
            .onAction(A.Left, cx.listener(TextInput.left))
            .onAction(A.Right, cx.listener(TextInput.right))
            .onAction(A.Up, cx.listener(TextInput.up))
            .onAction(A.Down, cx.listener(TextInput.down))
            .onAction(A.SelectLeft, cx.listener(TextInput.selectLeft))
            .onAction(A.SelectRight, cx.listener(TextInput.selectRight))
            .onAction(A.SelectUp, cx.listener(TextInput.selectUp))
            .onAction(A.SelectDown, cx.listener(TextInput.selectDown))
            .onAction(A.SelectAll, cx.listener(TextInput.selectAll))
            .onAction(A.Home, cx.listener(TextInput.home))
            .onAction(A.End, cx.listener(TextInput.end))
            .onAction(A.SelectHome, cx.listener(TextInput.selectHome))
            .onAction(A.SelectEnd, cx.listener(TextInput.selectEnd))
            .onAction(A.DocStart, cx.listener(TextInput.docStart))
            .onAction(A.DocEnd, cx.listener(TextInput.docEnd))
            .onAction(A.SelectDocStart, cx.listener(TextInput.selectDocStart))
            .onAction(A.SelectDocEnd, cx.listener(TextInput.selectDocEnd))
            .onAction(A.WordLeft, cx.listener(TextInput.wordLeft))
            .onAction(A.WordRight, cx.listener(TextInput.wordRight))
            .onAction(A.MentionTab, cx.listener(TextInput.mentionTab))
            .onAction(A.OutdentList, cx.listener(TextInput.outdentList))
            .onAction(A.SelectWordLeft, cx.listener(TextInput.selectWordLeft))
            .onAction(A.SelectWordRight, cx.listener(TextInput.selectWordRight))
            .onAction(A.DeleteWordLeft, cx.listener(TextInput.deleteWordLeft))
            .onAction(A.DeleteWordRight, cx.listener(TextInput.deleteWordRight))
            .onAction(A.DeleteToLineStart, cx.listener(TextInput.deleteToLineStart))
            .onAction(A.DeleteToLineEnd, cx.listener(TextInput.deleteToLineEnd))
            .onAction(A.Copy, cx.listener(TextInput.copy))
            .onAction(A.Cut, cx.listener(TextInput.cut))
            .onAction(A.Paste, cx.listener(TextInput.paste))
            .onAction(A.Newline, cx.listener(TextInput.newline))
            .onAction(A.MessageNewlineOrAccept, cx.listener(TextInput.messageNewlineOrAccept))
            .onAction(A.ModifiedSubmit, cx.listener(TextInput.modifiedSubmit))
            .onAction(A.Submit, cx.listener(TextInput.submit))
            .onAction(A.ToggleDictation, cx.listener(TextInput.toggleDictation))
            .onAction(A.Undo, cx.listener(TextInput.undoAction))
            .onAction(A.Redo, cx.listener(TextInput.redoAction))
            .onKeyDown(cx.listener(TextInput.onKeyDown))
            .onMouseDown(.left, cx.listener(TextInput.onMouseDown))
            .onMouseDownOut(cx.listener(TextInput.onMouseDownOut))
            .onMouseUp(.left, cx.listener(TextInput.onMouseUp))
            .onMouseUpOut(.left, cx.listener(TextInput.onMouseUp))
            .onScrollWheel(cx.listener(TextInput.onScrollWheel))
            .wFull()
            .child(TextInputElement{ .input = cx.entityId(), .focus = self.focus });
    }
};

// ---------------------------------------------------------------------------
// The custom element: measured auto-grow layout + shaped-line painting
// ---------------------------------------------------------------------------

const TextInputElement = struct {
    input: zpui.EntityId,
    focus: zpui.FocusHandle,

    const W = zpui.WeakEntity(TextInput);

    fn weak(self: *const TextInputElement) W {
        return .{ .id = self.input };
    }

    const Measure = struct { input: zpui.EntityId };

    fn measure(ctx: Measure, known: zpui.layout.Dims(?Pixels), avail: zpui.layout.Dims(zpui.AvailableSpace), window: *Window, app: *App) Size {
        const width: f32 = known.width orelse switch (avail.width) {
            .definite => |w| w,
            else => 320,
        };
        const w: W = .{ .id = ctx.input };
        const h = w.update(app, measureInput, .{ width, window }) orelse 0;
        return .{ .width = width, .height = h };
    }

    fn measureInput(self: *TextInput, width: f32, window: *Window, cx: *Context(TextInput)) f32 {
        const h = self.layoutText(width, window, cx);
        return @min(h, self.maxContent());
    }

    pub fn requestLayout(self: *TextInputElement, _: ?zpui.GlobalElementId, _: *void, window: *Window, _: *App) zpui.LayoutId {
        var style: zpui.Style = .{};
        style.size.width = .{ .definite = .{ .fraction = 1.0 } };
        return window.requestMeasuredLayout(style, Measure{ .input = self.input }, measure);
    }

    pub fn prepaint(self: *TextInputElement, _: ?zpui.GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, app: *App) void {
        _ = self.weak().update(app, TextInput.prepaintLayout, .{ bounds, window });
    }

    const MoveCtx = struct { input: zpui.EntityId };

    fn onMove(ctx: *MoveCtx, ev: *const input.MouseMoveEvent, phase: zpui.DispatchPhase, _: *Window, app: *App) void {
        if (phase != .bubble) return;
        const w: W = .{ .id = ctx.input };
        _ = w.update(app, TextInput.onWindowMouseMove, .{ev});
    }

    pub fn paint(self: *TextInputElement, _: ?zpui.GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, app: *App) void {
        window.handleInput(self.focus, .init(Entity(TextInput){ .id = self.input }, bounds));
        window.onMouseEvent(input.MouseMoveEvent, MoveCtx{ .input = self.input }, onMove);
        const caret_on = self.weak().update(app, TextInput.caretShown, .{window}) orelse false;
        const in = self.weak().read(app) orelse return;

        const paint_bounds = in.paintBounds(bounds);
        const origin: Point = .{ .x = bounds.origin.x - in.scroll_left, .y = bounds.origin.y - in.scroll_top };
        const lh = in.line_height;
        window.pushContentMask(.{ .bounds = paint_bounds });
        defer window.popContentMask(.{ .bounds = paint_bounds });
        const edges = inputOverflowEdges(in.content_height, in.settled_viewport_height orelse in.maxContent(), bounds.size.height, in.scroll_top);
        const fading = in.edge_fade and !in.state.single_line;
        const prev_fade = window.pushEdgeFade(.{ .bounds = paint_bounds, .band = fade_band, .top = fading and edges[0], .bottom = fading and edges[1] });
        defer window.popEdgeFade(prev_fade);

        // Selection: first visual row, full middle rows, last visual row.
        const sel = in.state.selected;
        if (!sel.isEmpty() and !in.display_is_placeholder) {
            if (in.pointForIndex(sel.start, .downstream)) |start| if (in.pointForIndex(sel.end, .upstream)) |stop| {
                const color = in.colors.selection;
                if (start.y == stop.y) {
                    window.paintQuad(zpui.fill(Bounds.fromCorners(
                        .{ .x = origin.x + start.x, .y = origin.y + start.y },
                        .{ .x = origin.x + stop.x, .y = origin.y + start.y + lh },
                    ), color));
                } else {
                    window.paintQuad(zpui.fill(Bounds.fromCorners(
                        .{ .x = origin.x + start.x, .y = origin.y + start.y },
                        .{ .x = bounds.right(), .y = origin.y + start.y + lh },
                    ), color));
                    if (stop.y > start.y + lh) window.paintQuad(zpui.fill(Bounds.fromCorners(
                        .{ .x = origin.x, .y = origin.y + start.y + lh },
                        .{ .x = bounds.right(), .y = origin.y + stop.y },
                    ), color));
                    window.paintQuad(zpui.fill(Bounds.fromCorners(
                        .{ .x = origin.x, .y = origin.y + stop.y },
                        .{ .x = origin.x + stop.x, .y = origin.y + stop.y + lh },
                    ), color));
                }
            };
        }

        // Text.
        const painter = window.glyphPainter();
        var y = origin.y;
        for (in.lines) |line| {
            const h = line.size(lh).height;
            if (y + h >= paint_bounds.origin.y and y <= paint_bounds.bottom()) {
                line.paint(painter, .{ .x = origin.x, .y = y }, lh, .left, null) catch {};
            }
            y += h;
        }

        // Inline completion ghost at the end-of-text caret.
        if (in.ghost.items.len > 0 and !in.display_is_placeholder and in.state.marked == null and
            sel.isEmpty() and in.state.cursor() == in.state.text().len)
        {
            if (in.pointForIndex(in.state.text().len, .upstream)) |p| {
                var font = window.textStyle().font();
                font.family = in.font_family;
                const run: zpui.text.TextRun = .{ .len = in.ghost.items.len, .font = font, .color = in.colors.ghost };
                if (window.text_system.shapeLine(in.ghost.items, in.font_size, &.{run}, null)) |shaped| {
                    defer shaped.deinit(in.gpa);
                    shaped.paint(painter, .{ .x = origin.x + p.x, .y = origin.y + p.y }, lh, .left, null) catch {};
                } else |_| {}
            }
        }

        // Caret: only when focused in an active window, in the "on" phase.
        if (caret_on and (sel.isEmpty() or in.display_is_placeholder)) {
            const p = in.cursorPoint() orelse Point{ .x = 0, .y = 0 };
            window.paintQuad(zpui.fill(Bounds{
                .origin = .{ .x = origin.x + p.x, .y = origin.y + p.y },
                .size = .{ .width = 2, .height = lh },
            }, in.colors.caret));
        }
    }
};

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

pub fn writeClipboard(app: *App, s: []const u8) void {
    app.platform.vtable.writeClipboard(app.platform.ptr, s);
}

pub fn readClipboard(app: *App, gpa: Allocator) ?[]u8 {
    return app.platform.vtable.readClipboard(app.platform.ptr, gpa);
}

fn percentDecode(gpa: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
                try out.append(gpa, s[i]);
                continue;
            };
            try out.append(gpa, v);
            i += 2;
        } else try out.append(gpa, s[i]);
    }
    return out.toOwnedSlice(gpa);
}
