//! The terminal emulator core: Ghostty's terminal (vendored libghostty-vt,
//! `vendor/ghostty-vt`) wrapped as a pure state machine, mirroring zeron's
//! `crates/ui/src/terminal/emulator.rs` (which wraps alacritty_terminal).
//!
//! Bytes in (`feed`, the decoded `SubscribeTerminal` data frames), render
//! snapshots out (`snapshot`, `rowText`, `cursor`). No I/O, no timers, no UI:
//! the panel owns RPC and scheduling, the view owns paint. Query responses
//! (DSR/DA/DECRQM/...) are returned from `feed` so the caller can write them
//! back to the PTY.
//!
//! Selection lives here too (`startSelection`/`updateSelection`), because the
//! terminal is what keeps anchors on their text (tracked pins) as output
//! scrolls the grid underneath them.
//!
//! The emulator must not move after `create` (the Ghostty stream handler
//! keeps a pointer to the terminal), so it is always heap allocated.
const Emulator = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const vt = @import("ghostty-vt");
const snap = @import("snapshot.zig");

/// Scrollback history kept client-side (lines), same as zeron's
/// `SCROLLBACK_LINES`. The engine's replay window is bounded separately.
pub const scrollback_lines: usize = 10_000;

gpa: Allocator,
terminal: vt.Terminal,
stream: vt.TerminalStream,
render: vt.RenderState = .empty,

/// Bytes the terminal wants written back to the PTY, accumulated during
/// one `feed` (query responses). Cleared at the start of each feed.
responses: std.ArrayList(u8) = .empty,

/// Set when BEL arrives; `takeBell` reads and clears it.
bell_pending: bool = false,

/// Optional embedder callbacks (title/bell/clipboard/pwd). Polling via
/// `title()`/`takeBell()` works without them.
callbacks: Callbacks = .{},

/// Selection gesture state (anchor kept as a tracked pin).
sel: SelectionState = .{},

/// Render snapshot storage, reused across frames.
snapshot_state: snap.Storage = .{},

/// Last cell reported for mouse motion (deduplication).
mouse_last_cell: ?vt.Coordinate = null,

pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    /// OSC 0/2 (and resets). `title` is null when cleared.
    title: ?*const fn (ctx: ?*anyopaque, title: ?[]const u8) void = null,
    bell: ?*const fn (ctx: ?*anyopaque) void = null,
    /// OSC 52 (and kitty OSC 5522) clipboard writes, text/plain only.
    clipboard_write: ?*const fn (ctx: ?*anyopaque, location: ClipboardLocation, text: []const u8) void = null,
    /// OSC 7 working directory.
    pwd: ?*const fn (ctx: ?*anyopaque, pwd: []const u8) void = null,
};

pub const ClipboardLocation = enum { standard, selection, primary };

pub const Options = struct {
    cols: u16,
    rows: u16,
    /// Used by Ghostty for features that touch the filesystem (Kitty
    /// graphics file transmission, disabled in this build). Any `std.Io`.
    io: std.Io,
    scrollback_lines: usize = scrollback_lines,
};

/// Clamp like zeron's `GridSize::new`: at least 2 cols and 1 row.
pub fn clampSize(c: u16, r: u16) struct { u16, u16 } {
    return .{ @max(c, 2), @max(r, 1) };
}

pub fn create(gpa: Allocator, opts: Options) !*Emulator {
    const ncols, const nrows = clampSize(opts.cols, opts.rows);
    const self = try gpa.create(Emulator);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .terminal = try .init(opts.io, gpa, .{
            .cols = ncols,
            .rows = nrows,
            .max_scrollback_bytes = null,
            .max_scrollback_lines = opts.scrollback_lines,
            // Unicode grapheme clustering (mode 2027) on by default, like
            // Ghostty's own `grapheme-width-method = unicode`: ZWJ emoji
            // sequences, flags and skin tones occupy one (wide) cell.
            .default_modes = .{ .grapheme_cluster = true },
        }),
        .stream = undefined,
    };
    errdefer self.terminal.deinit(gpa);

    var handler = self.terminal.vtHandler();
    handler.effects = .readonly;
    handler.effects.write_pty = &effectWritePty;
    handler.effects.bell = &effectBell;
    handler.effects.title_changed = &effectTitle;
    handler.effects.pwd_changed = &effectPwd;
    handler.effects.clipboard_write = &effectClipboardWrite;
    handler.effects.device_attributes = &effectDeviceAttributes;
    handler.effects.xtversion = &effectXtversion;
    handler.effects.size = &effectSize;
    handler.effects.reset = &effectReset;
    self.stream = .init(.{ .allocator = gpa, .handler = handler });
    return self;
}

pub fn destroy(self: *Emulator) void {
    const gpa = self.gpa;
    self.clearSelection();
    self.stream.deinit();
    self.render.deinit(gpa);
    self.snapshot_state.deinit(gpa);
    self.responses.deinit(gpa);
    self.terminal.deinit(gpa);
    gpa.destroy(self);
}

// ---------------------------------------------------------------------------
// Bytes in
// ---------------------------------------------------------------------------

/// Advance the state machine over decoded PTY output. Returns bytes the
/// terminal wants written back to the PTY (DSR/DA query responses etc.);
/// valid until the next `feed`.
pub fn feed(self: *Emulator, bytes: []const u8) []const u8 {
    self.responses.clearRetainingCapacity();
    self.stream.nextSlice(bytes);
    return self.responses.items;
}

/// Resize the grid (reflowing soft-wrapped lines on the primary screen).
pub fn resize(self: *Emulator, cols_req: u16, rows_req: u16) !void {
    const ncols, const nrows = clampSize(cols_req, rows_req);
    if (ncols == self.terminal.cols and nrows == self.terminal.rows) return;
    try self.stream.handler.resize(.{ .cols = ncols, .rows = nrows });
}

pub fn cols(self: *const Emulator) u16 {
    return self.terminal.cols;
}

pub fn rows(self: *const Emulator) u16 {
    return self.terminal.rows;
}

/// Tell the terminal the theme colors, so OSC 4/10/11/12 color queries
/// (used by vim, neovim, fzf... to pick light/dark defaults) report what
/// the view actually paints. Rendering still resolves through the palette
/// in the view (`palette.zig`); this only feeds query responses.
pub fn setPalette(self: *Emulator, pal: *const @import("palette.zig").Palette) !void {
    const pm = @import("palette.zig");
    const rgb = struct {
        fn f(c: snap.Rgb) vt.color.RGB {
            return .{ .r = c.r, .g = c.g, .b = c.b };
        }
    }.f;
    var def: vt.color.Palette = undefined;
    for (&def, 0..) |*d, i| {
        const ix: u8 = @intCast(i);
        d.* = rgb(if (ix < 16) pal.ansi[ix] else pm.extendedIndexed(pal.appearance, ix));
    }
    try self.terminal.colors.palette.changeDefault(self.gpa, def);
    self.terminal.colors.foreground.default = rgb(pal.foreground);
    self.terminal.colors.background.default = rgb(pal.background);
    self.terminal.colors.cursor.default = rgb(pal.cursor orelse pal.foreground);
    self.terminal.flags.dirty.palette = true;
}

// ---------------------------------------------------------------------------
// Terminal state queries
// ---------------------------------------------------------------------------

/// OSC 0/2 title, if the running program set one.
pub fn title(self: *const Emulator) ?[]const u8 {
    const t = self.terminal.getTitle() orelse return null;
    if (t.len == 0) return null;
    return t;
}

/// OSC 7 working directory, if reported.
pub fn pwd(self: *const Emulator) ?[]const u8 {
    return self.terminal.getPwd();
}

/// True once a BEL arrived; reading clears it.
pub fn takeBell(self: *Emulator) bool {
    defer self.bell_pending = false;
    return self.bell_pending;
}

pub fn mode(self: *const Emulator, comptime m: vt.Mode) bool {
    return self.terminal.modes.get(m);
}

/// Arrow keys should send SS3 (`ESC O A`) instead of CSI (DECCKM).
pub fn appCursorMode(self: *const Emulator) bool {
    return self.mode(.cursor_keys);
}

/// Keypad application mode (DECKPAM / mode 66).
pub fn appKeypadMode(self: *const Emulator) bool {
    return self.mode(.keypad_keys);
}

/// Pastes should be wrapped in `ESC [200~` / `ESC [201~`.
pub fn bracketedPasteMode(self: *const Emulator) bool {
    return self.mode(.bracketed_paste);
}

/// The alternate screen (1047/1049/47) is active.
pub fn altScreen(self: *const Emulator) bool {
    return self.terminal.screens.active_key == .alternate;
}

/// Focus reporting (mode 1004) is on.
pub fn focusReporting(self: *const Emulator) bool {
    return self.mode(.focus_event);
}

/// The running program asked for mouse events (any of 9/1000/1002/1003).
pub fn mouseReporting(self: *const Emulator) bool {
    return self.terminal.flags.mouse_event != .none;
}

pub fn mouseEvent(self: *const Emulator) vt.MouseEvent {
    return self.terminal.flags.mouse_event;
}

pub fn mouseFormat(self: *const Emulator) vt.MouseFormat {
    return self.terminal.flags.mouse_format;
}

/// Synchronized output (mode 2026) is holding renders.
pub fn renderHeld(self: *const Emulator) bool {
    return self.mode(.synchronized_output);
}

// ---------------------------------------------------------------------------
// Scrollback viewport
// ---------------------------------------------------------------------------

fn scrollbar(self: *Emulator) vt.PageList.Scrollbar {
    return self.terminal.screens.active.pages.scrollbar();
}

/// Lines scrolled back into history (0 = pinned to the live bottom).
pub fn displayOffset(self: *Emulator) usize {
    const sb = self.scrollbar();
    return sb.total - sb.offset - sb.len;
}

/// Lines available above the viewport.
pub fn historyLines(self: *Emulator) usize {
    const sb = self.scrollbar();
    return sb.total - sb.len;
}

/// Scroll the view: positive = up into history, negative = toward live.
pub fn scroll(self: *Emulator, delta: i32) void {
    self.terminal.scrollViewport(.{ .delta = -@as(isize, delta) });
}

pub fn scrollToBottom(self: *Emulator) void {
    self.terminal.scrollViewport(.bottom);
}

pub fn scrollToTop(self: *Emulator) void {
    self.terminal.scrollViewport(.top);
}

/// Set the scrollback offset directly (0 = live bottom).
pub fn scrollToOffset(self: *Emulator, offset: usize) void {
    const history = self.historyLines();
    const target = @min(offset, history);
    self.terminal.scrollViewport(.{ .row = history - target });
}

// ---------------------------------------------------------------------------
// Viewport points
// ---------------------------------------------------------------------------

/// A position in the visible grid (row 0 = top of the viewport).
pub const ViewportPoint = struct {
    row: usize,
    col: usize,
};

/// Which edge of a cell a selection anchors to: pressing on the left half
/// of a glyph includes it, the right half excludes it (alacritty/zeron).
pub const Side = enum { left, right };

fn viewportPin(self: *Emulator, p: ViewportPoint) ?vt.Pin {
    const screen = self.terminal.screens.active;
    const col = @min(p.col, @as(usize, self.cols()) - 1);
    const row = @min(p.row, @as(usize, self.rows()) - 1);
    return screen.pages.pin(.{ .viewport = .{
        .x = @intCast(col),
        .y = @intCast(row),
    } });
}

/// Hyperlink URI (OSC 8) of the cell under a viewport point, if any.
/// Borrowed from terminal memory: valid until the next feed/resize.
pub fn hyperlinkAt(self: *Emulator, p: ViewportPoint) ?[]const u8 {
    const pin = self.viewportPin(p) orelse return null;
    const page = pin.node.page();
    const rac = page.getRowAndCell(pin.x, pin.y);
    if (!rac.cell.hyperlink) return null;
    const id = page.lookupHyperlink(rac.cell) orelse return null;
    const entry = page.hyperlink_set.get(page.memory, id);
    return entry.uri.slice(page.memory);
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

/// Selection granularity, named after alacritty's `SelectionType` that the
/// zeron panel speaks: drag (`simple`), double-click word (`semantic`),
/// triple-click row (`lines`), alt-drag rectangle (`block`).
pub const SelectionKind = enum { simple, semantic, lines, block };

pub const SelectionState = struct {
    kind: SelectionKind = .simple,
    /// Tracked anchor pin on `screen` (null = no selection gesture).
    anchor: ?*vt.Pin = null,
    anchor_side: Side = .left,
    screen: vt.ScreenSet.Key = .primary,
};

/// Word boundaries for semantic selection (Ghostty's defaults).
pub const word_boundaries = [_]u21{
    0,   ' ', '\t', '\'', '"',
    '│',
    '`', '|', ':',  ';',  ',',
    '(', ')', '[',  ']',  '{',
    '}', '<', '>',  '$',
};

/// Begin a selection at a viewport point.
pub fn startSelection(self: *Emulator, kind: SelectionKind, p: ViewportPoint, side: Side) !void {
    self.clearSelection();
    const pin = self.viewportPin(p) orelse return;
    const screen = self.terminal.screens.active;
    self.sel = .{
        .kind = kind,
        .anchor = try screen.pages.trackPin(pin),
        .anchor_side = side,
        .screen = self.terminal.screens.active_key,
    };
    try self.applySelection(pin, side);
}

/// Extend the in-progress selection to a viewport point. No-op without one.
pub fn updateSelection(self: *Emulator, p: ViewportPoint, side: Side) !void {
    if (self.sel.anchor == null) return;
    if (self.sel.screen != self.terminal.screens.active_key) {
        self.clearSelection();
        return;
    }
    const pin = self.viewportPin(p) orelse return;
    try self.applySelection(pin, side);
}

pub fn clearSelection(self: *Emulator) void {
    if (self.sel.anchor) |a| {
        if (self.terminal.screens.get(self.sel.screen)) |screen| {
            screen.pages.untrackPin(a);
        }
    }
    self.sel = .{};
    // Clear on every screen: the selection belongs to the screen it was made on.
    if (self.terminal.screens.get(.primary)) |s| s.clearSelection();
    if (self.terminal.screens.get(.alternate)) |s| s.clearSelection();
}

/// Select everything (primary scrollback + active area).
pub fn selectAll(self: *Emulator) !void {
    self.clearSelection();
    const screen = self.terminal.screens.active;
    try screen.select(screen.selectAll());
}

fn applySelection(self: *Emulator, head: vt.Pin, head_side: Side) !void {
    const screen = self.terminal.screens.active;
    const anchor = self.sel.anchor.?.*;
    const anchor_side = self.sel.anchor_side;
    const new: ?vt.Selection = switch (self.sel.kind) {
        .simple, .block => simple: {
            // Order the two edges, then convert cell edges to inclusive cells.
            const head_first = head.before(anchor) or
                (head.eql(anchor) and head_side == .left and anchor_side == .right);
            var start, var start_side, var end, var end_side = if (head_first)
                .{ head, head_side, anchor, anchor_side }
            else
                .{ anchor, anchor_side, head, head_side };
            if (self.sel.kind == .block) {
                // Rectangle: sides only matter for the columns.
                break :simple vt.Selection.init(start, end, true);
            }
            if (start_side == .right) {
                start = start.rightWrap(1) orelse break :simple null;
                start_side = .left;
            }
            if (end_side == .left) {
                end = end.leftWrap(1) orelse break :simple null;
                end_side = .right;
            }
            // Empty (a click without a drag, or a drag within one half-cell).
            if (end.before(start)) break :simple null;
            break :simple vt.Selection.init(start, end, false);
        },
        .semantic => sem: {
            const a = screen.selectWord(anchor, &word_boundaries) orelse break :sem null;
            const h = screen.selectWord(head, &word_boundaries) orelse a;
            break :sem union2(screen, a, h);
        },
        .lines => lines: {
            const a = screen.selectLine(.{ .pin = anchor, .whitespace = null }) orelse break :lines null;
            const h = screen.selectLine(.{ .pin = head, .whitespace = null }) orelse a;
            break :lines union2(screen, a, h);
        },
    };
    try screen.select(new);
}

fn union2(screen: *vt.Screen, a: vt.Selection, b: vt.Selection) vt.Selection {
    const a_tl = a.topLeft(screen);
    const b_tl = b.topLeft(screen);
    const a_br = a.bottomRight(screen);
    const b_br = b.bottomRight(screen);
    return vt.Selection.init(
        if (b_tl.before(a_tl)) b_tl else a_tl,
        if (a_br.before(b_br)) b_br else a_br,
        false,
    );
}

/// Whether a non-empty selection is active.
pub fn hasSelection(self: *const Emulator) bool {
    return self.terminal.screens.active.selection != null;
}

/// The selected text (caller owns), or null when nothing is selected.
/// Line selections end with a newline, like alacritty/zeron.
pub fn selectionText(self: *Emulator, gpa: Allocator) !?[]u8 {
    const screen = self.terminal.screens.active;
    const sel = screen.selection orelse return null;
    const text = try screen.selectionString(gpa, .{ .sel = sel, .trim = true });
    defer gpa.free(text);
    if (text.len == 0 and self.sel.kind != .lines) return null;
    if (self.sel.kind == .lines and self.sel.anchor != null) {
        const out = try gpa.alloc(u8, text.len + 1);
        @memcpy(out[0..text.len], text);
        out[text.len] = '\n';
        return out;
    }
    return try gpa.dupe(u8, text);
}

// ---------------------------------------------------------------------------
// Render snapshot
// ---------------------------------------------------------------------------

/// Update and return the render snapshot (rows of cells with codepoints,
/// colors, attributes, selection overlay, per-row damage, cursor). The
/// returned value borrows emulator storage and is valid until the next
/// call that mutates the emulator.
pub fn snapshot(self: *Emulator) !*const snap.Snapshot {
    try self.render.update(self.gpa, &self.terminal);
    try self.snapshot_state.fill(self.gpa, &self.render, self.displayOffset(), self.historyLines());
    // The renderer consumed the damage; reset Ghostty's flags.
    self.render.dirty = .false;
    for (self.render.row_data.items(.dirty)) |*d| d.* = false;
    return &self.snapshot_state.snapshot;
}

/// Cursor in viewport coordinates; null when hidden or scrolled out.
pub fn cursor(self: *Emulator) ?ViewportPoint {
    if (!self.mode(.cursor_visible)) return null;
    const screen = self.terminal.screens.active;
    const pin = screen.pages.pin(.{ .active = .{
        .x = screen.cursor.x,
        .y = screen.cursor.y,
    } }) orelse return null;
    const vp = screen.pages.pointFromPin(.viewport, pin) orelse return null;
    const c = vp.coord();
    if (c.y >= self.rows() or c.x >= self.cols()) return null;
    return .{ .row = c.y, .col = c.x };
}

/// Current cursor shape (DECSCUSR).
pub fn cursorStyle(self: *const Emulator) vt.CursorStyle {
    return self.terminal.screens.active.cursor.cursor_style;
}

/// Test/diagnostic helper: a viewport row as trimmed text (wide-char
/// spacers skipped, graphemes included). Caller owns the result.
pub fn rowText(self: *Emulator, gpa: Allocator, viewport_row: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const pin = self.viewportPin(.{ .row = viewport_row, .col = 0 }) orelse return out.toOwnedSlice(gpa);
    const cells = pin.cells(.all);
    for (cells) |*cell| {
        if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;
        const cp: u21 = switch (cell.content_tag) {
            .codepoint, .codepoint_grapheme => cell.content.codepoint.data,
            else => 0,
        };
        try appendCodepoint(&out, gpa, if (cp == 0) ' ' else cp);
        if (cell.content_tag == .codepoint_grapheme) {
            if (pin.grapheme(cell)) |extra| for (extra) |g| try appendCodepoint(&out, gpa, g);
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

fn appendCodepoint(out: *std.ArrayList(u8), gpa: Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try out.appendSlice(gpa, buf[0..n]);
}

/// The whole screen (history + active) as plain text. Caller owns.
pub fn plainText(self: *Emulator, gpa: Allocator) ![]const u8 {
    return self.terminal.plainString(gpa);
}

// ---------------------------------------------------------------------------
// Ghostty stream effects
// ---------------------------------------------------------------------------

fn fromHandler(h: *vt.TerminalStream.Handler) *Emulator {
    const stream: *vt.TerminalStream = @fieldParentPtr("handler", h);
    return @fieldParentPtr("stream", stream);
}

fn effectWritePty(h: *vt.TerminalStream.Handler, data: []const u8) void {
    const self = fromHandler(h);
    self.responses.appendSlice(self.gpa, data) catch {};
}

fn effectBell(h: *vt.TerminalStream.Handler) void {
    const self = fromHandler(h);
    self.bell_pending = true;
    if (self.callbacks.bell) |cb| cb(self.callbacks.ctx);
}

fn effectTitle(h: *vt.TerminalStream.Handler) void {
    const self = fromHandler(h);
    if (self.callbacks.title) |cb| cb(self.callbacks.ctx, self.title());
}

fn effectPwd(h: *vt.TerminalStream.Handler) void {
    const self = fromHandler(h);
    if (self.callbacks.pwd) |cb| if (self.pwd()) |p| cb(self.callbacks.ctx, p);
}

fn effectReset(h: *vt.TerminalStream.Handler) void {
    const self = fromHandler(h);
    if (self.callbacks.title) |cb| cb(self.callbacks.ctx, null);
}

fn effectClipboardWrite(h: *vt.TerminalStream.Handler, w: vt.clipboard.Write) void {
    const self = fromHandler(h);
    const cb = self.callbacks.clipboard_write orelse return;
    const loc: ClipboardLocation = switch (w.location) {
        .standard => .standard,
        .selection => .selection,
        .primary => .primary,
        _ => return,
    };
    for (w.contents) |c| {
        if (vt.clipboard.isTextMime(c.mime)) {
            cb(self.callbacks.ctx, loc, c.data);
            return;
        }
    }
}

fn effectDeviceAttributes(_: *vt.TerminalStream.Handler) vt.device_attributes.Attributes {
    return .{};
}

fn effectXtversion(_: *vt.TerminalStream.Handler) []const u8 {
    return "zeron (ghostty-vt)";
}

fn effectSize(h: *vt.TerminalStream.Handler) ?vt.size_report.Size {
    const self = fromHandler(h);
    return .{
        .rows = self.terminal.rows,
        .columns = self.terminal.cols,
        .cell_width = self.terminal.width_px / @max(1, self.terminal.cols),
        .cell_height = self.terminal.height_px / @max(1, self.terminal.rows),
    };
}
