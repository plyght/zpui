//! Text elements (gpui `elements/text.rs`): plain strings, `StyledText` (highlights / runs)
//! and `InteractiveText` (clickable ranges, hover, tooltips).
//!
//! Text is measured through the layout engine: the width a parent offers becomes the wrap
//! width (`white_space: normal`), and the current text style's `text_overflow` /
//! `line_clamp` truncate with an ellipsis. Text inherits the text style of its ancestors
//! (`div().textSm().textColor(c).child("label")`).
//!
//! Strings must outlive the frame: literals, `zpui.fmt(...)` (frame arena) or data owned
//! by your view.

const std = @import("std");
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const text_mod = @import("../text/text.zig");
const layout = @import("../layout/layout.zig");
const input = @import("../input.zig");
const App = @import("../app/app.zig").App;
const EntityId = @import("../app/entity.zig").EntityId;
const Listener = @import("../app/context.zig").Listener;
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const Hitbox = window_mod.Hitbox;
const HitboxId = window_mod.HitboxId;
const DispatchPhase = window_mod.DispatchPhase;
const element = @import("../window/element.zig");
const AnyElement = element.AnyElement;
const ElementId = element.ElementId;
const GlobalElementId = element.GlobalElementId;
const LayoutId = element.LayoutId;
const arena_mod = @import("../window/arena.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point(Pixels);
const Size = geometry.Size(Pixels);
const Bounds = geometry.Bounds(Pixels);
const TextRun = text_mod.TextRun;
const WrappedLine = text_mod.WrappedLine;
const HighlightStyle = style_mod.HighlightStyle;

/// A styled byte range of a `StyledText`.
pub const Highlight = struct {
    start: usize,
    end: usize,
    style: HighlightStyle,
};

/// Shaped lines of a text element plus where they were placed (gpui `TextLayout`).
/// Valid for the frame after layout (lines) and prepaint (bounds).
pub const TextLayout = struct {
    gpa: std.mem.Allocator,
    lines: []WrappedLine = &.{},
    len: usize = 0,
    line_height: Pixels = 0,
    wrap_width: ?Pixels = null,
    truncate_width: ?Pixels = null,
    size: ?Size = null,
    bounds: ?Bounds = null,

    pub fn deinit(self: *TextLayout) void {
        self.clearLines();
    }

    fn clearLines(self: *TextLayout) void {
        if (self.lines.len > 0) text_mod.freeLines(self.gpa, self.lines);
        self.lines = &.{};
    }

    /// Byte index at `position` (window coordinates): `.inside` a glyph or the nearest
    /// `.outside` index (gpui `index_for_position` Ok/Err).
    pub fn indexForPosition(self: *const TextLayout, position: Point) text_mod.SharedWrappedLayout.PositionIndex {
        const b = self.bounds orelse return .{ .outside = 0 };
        if (position.y < b.origin.y) return .{ .outside = 0 };
        var origin = b.origin;
        var line_start: usize = 0;
        for (self.lines) |line| {
            const bottom = origin.y + line.size(self.line_height).height;
            if (position.y > bottom) {
                origin.y = bottom;
                line_start += line.len() + 1;
                continue;
            }
            return switch (line.indexForPosition(position.sub(origin), self.line_height)) {
                .inside => |i| .{ .inside = line_start + i },
                .outside => |i| .{ .outside = line_start + i },
            };
        }
        return .{ .outside = line_start -| 1 };
    }

    /// Window position of the caret before byte `index`.
    pub fn positionForIndex(self: *const TextLayout, index: usize) ?Point {
        const b = self.bounds orelse return null;
        var origin = b.origin;
        var line_start: usize = 0;
        for (self.lines) |line| {
            const line_end = line_start + line.len();
            if (index < line_start) break;
            if (index > line_end) {
                origin.y += line.size(self.line_height).height;
                line_start = line_end + 1;
                continue;
            }
            const p = line.positionForIndex(index - line_start, self.line_height) orelse return null;
            return origin.add(p);
        }
        return null;
    }

    pub fn lineHeight(self: *const TextLayout) Pixels {
        return self.line_height;
    }
};

const MeasureCtx = struct {
    layout: *TextLayout,
    text: []const u8,
    runs: []const TextRun,
    text_style: style_mod.TextStyle,
    font_size: Pixels,
};

fn measure(c: *MeasureCtx, known: layout.Dims(?Pixels), avail: layout.Dims(layout.AvailableSpace), window: *Window, _: *App) Size {
    const ts = c.text_style;
    const tl = c.layout;
    const avail_w: ?Pixels = switch (avail.width) {
        .definite => |w| w,
        else => null,
    };
    const wrap_width: ?Pixels = if (ts.white_space == .normal) known.width orelse avail_w else null;
    var truncate: ?text_mod.Truncation = null;
    if (ts.text_overflow) |ov| {
        const width: ?Pixels = known.width orelse if (avail_w) |w| (if (ts.line_clamp) |n| w * @as(f32, @floatFromInt(n)) else w) else null;
        if (width) |w| truncate = .{
            .width = w,
            .affix = switch (ov) {
                inline else => |s| s,
            },
            .from = switch (ov) {
                .truncate => .end,
                .truncate_start => .start,
                .truncate_middle => .middle,
            },
            .line_height = tl.line_height,
        };
    }
    if (tl.size) |s| {
        const same_wrap = wrap_width == null or wrap_width == tl.wrap_width;
        if (same_wrap and truncate == null and tl.truncate_width == null) return s;
    }
    tl.clearLines();
    const lines = window.text_system.shapeText(c.text, c.font_size, c.runs, .{
        .wrap_width = wrap_width,
        .line_clamp = ts.line_clamp,
        .truncate = truncate,
    }) catch |err| {
        std.log.warn("text shaping failed: {t}", .{err});
        tl.* = .{ .gpa = tl.gpa, .line_height = tl.line_height, .wrap_width = wrap_width, .size = .zero };
        return .zero;
    };
    var size: Size = .zero;
    var len: usize = 0;
    for (lines, 0..) |line, i| {
        const ls = line.size(tl.line_height);
        size.height += ls.height;
        size.width = @ceil(@max(size.width, ls.width));
        len += line.len() + @intFromBool(i > 0);
    }
    tl.lines = lines;
    tl.len = len;
    tl.wrap_width = wrap_width;
    tl.truncate_width = if (truncate) |t| t.width else null;
    tl.size = size;
    return size;
}

fn toLineAlign(a: style_mod.TextAlign) text_mod.TextAlign {
    return switch (a) {
        .left => .left,
        .center => .center,
        .right => .right,
    };
}

/// Text with optional highlights or explicit runs (gpui `StyledText`).
pub const StyledText = struct {
    text: []const u8,
    runs: ?[]const TextRun = null,
    highlights: ?[]const Highlight = null,
    layout_ptr: *TextLayout,
    /// The layout lives in the arena and is freed with it (vs. element state).
    owns_layout: bool = true,

    pub fn init(text: []const u8) StyledText {
        const a = arena_mod.current();
        const tl = a.allocator().create(TextLayout) catch @panic("OOM");
        tl.* = .{ .gpa = a.gpa };
        return .{ .text = text, .layout_ptr = tl };
    }

    /// Style byte ranges on top of the inherited text style (sorted, non-overlapping).
    /// The slice is copied into the frame arena.
    pub fn withHighlights(self: StyledText, highlights: []const Highlight) StyledText {
        var s = self;
        s.highlights = arena_mod.frameAllocator().dupe(Highlight, highlights) catch @panic("OOM");
        return s;
    }

    /// Fully explicit runs covering the whole text (copied into the frame arena; the fonts'
    /// strings must outlive the frame).
    pub fn withRuns(self: StyledText, runs: []const TextRun) StyledText {
        var total: usize = 0;
        for (runs) |r| total += r.len;
        std.debug.assert(total == self.text.len);
        var s = self;
        s.runs = arena_mod.frameAllocator().dupe(TextRun, runs) catch @panic("OOM");
        return s;
    }

    /// The layout handle (positions ↔ indices) for use during prepaint/paint.
    pub fn textLayout(self: StyledText) *TextLayout {
        return self.layout_ptr;
    }

    pub fn intoAnyElement(self: StyledText) AnyElement {
        return AnyElement.new(self);
    }

    pub fn deinit(self: *StyledText) void {
        if (self.owns_layout) self.layout_ptr.deinit();
    }

    fn computeRuns(text: []const u8, base: style_mod.TextStyle, highlights: []const Highlight) []TextRun {
        var runs: std.ArrayList(TextRun) = .empty;
        const a = arena_mod.frameAllocator();
        var ix: usize = 0;
        for (highlights) |h| {
            if (ix < h.start) runs.append(a, base.toRun(h.start - ix)) catch @panic("OOM");
            if (h.end > h.start) runs.append(a, base.highlight(h.style).toRun(h.end - h.start)) catch @panic("OOM");
            ix = h.end;
        }
        if (ix < text.len) runs.append(a, base.toRun(text.len - ix)) catch @panic("OOM");
        return runs.items;
    }

    pub fn requestLayout(self: *StyledText, _: ?GlobalElementId, _: *void, window: *Window, _: *App) LayoutId {
        const ts = window.textStyle();
        const rem = window.remSize();
        const font_size = ts.font_size.toPixels(rem);
        self.layout_ptr.line_height = window.pixelSnap(ts.line_height.toPixels(.{ .pixels = font_size }, rem));
        self.layout_ptr.size = null;
        self.layout_ptr.bounds = null;
        const runs: []const TextRun = self.runs orelse if (self.highlights) |h| computeRuns(self.text, ts, h) else blk: {
            const r = arena_mod.frameAllocator().alloc(TextRun, 1) catch @panic("OOM");
            r[0] = ts.toRun(self.text.len);
            break :blk r;
        };
        const ctx = arena_mod.current().create(MeasureCtx, .{
            .layout = self.layout_ptr,
            .text = self.text,
            .runs = runs,
            .text_style = ts,
            .font_size = font_size,
        });
        return window.requestMeasuredLayout(.{}, ctx, measure);
    }

    pub fn prepaint(self: *StyledText, _: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, _: *App) void {
        self.layout_ptr.bounds = bounds;
        // Accessibility: the text names / fills the enclosing node (src/a11y.zig).
        window.a11yAppendText(self.text, bounds);
    }

    pub fn paint(self: *StyledText, _: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, _: *App) void {
        const tl = self.layout_ptr;
        const painter = window.glyphPainter();
        const alignment = toLineAlign(window.textStyle().text_align);
        var origin = bounds.origin;
        for (tl.lines) |line| {
            line.paintBackground(painter, origin, tl.line_height, alignment, bounds) catch {};
            line.paint(painter, origin, tl.line_height, alignment, bounds) catch {};
            origin.y += line.size(tl.line_height).height;
        }
    }
};

/// Plain text elements are `StyledText` without highlights.
pub const Text = struct {
    pub fn element(s: []const u8) AnyElement {
        return AnyElement.new(StyledText.init(s));
    }
};

/// `StyledText` constructor shorthand: `styledText("x").withHighlights(...)`.
pub fn styledText(s: []const u8) StyledText {
    return StyledText.init(s);
}

// ---------------------------------------------------------------------------------------
// InteractiveText
// ---------------------------------------------------------------------------------------

pub const InteractiveTextState = struct {
    layout: TextLayout,
    mouse_down_index: ?usize = null,
    hovered_index: ?usize = null,
    clickable_ranges: std.ArrayList([2]usize) = .empty,
    click_listener: ?Listener(usize) = null,
    hover_listener: ?Listener(?usize) = null,

    pub fn deinit(self: *InteractiveTextState, gpa: std.mem.Allocator) void {
        self.layout.deinit();
        self.clickable_ranges.deinit(gpa);
    }
};

/// Text with clickable ranges and hover tracking (gpui `InteractiveText`).
pub const InteractiveText = struct {
    element_id: ElementId,
    text: StyledText,
    clickable_ranges: []const [2]usize = &.{},
    click_listener: ?Listener(usize) = null,
    hover_listener: ?Listener(?usize) = null,

    pub fn init(id: anytype, text: StyledText) InteractiveText {
        return .{ .element_id = ElementId.from(id), .text = text };
    }

    /// `l` receives the index of the clicked range in `ranges` (byte ranges `[start, end)`).
    pub fn onClick(self: InteractiveText, ranges: []const [2]usize, l: anytype) InteractiveText {
        var s = self;
        s.clickable_ranges = arena_mod.frameAllocator().dupe([2]usize, ranges) catch @panic("OOM");
        s.click_listener = Listener(usize).init(l);
        return s;
    }

    /// `l` receives the hovered byte index (or null) when it changes.
    pub fn onHover(self: InteractiveText, l: anytype) InteractiveText {
        var s = self;
        s.hover_listener = Listener(?usize).init(l);
        return s;
    }

    pub fn intoAnyElement(self: InteractiveText) AnyElement {
        return AnyElement.new(self);
    }

    pub const PrepaintState = Hitbox;

    pub fn elementId(self: *InteractiveText) ?ElementId {
        return self.element_id;
    }

    pub fn deinit(self: *InteractiveText) void {
        self.text.deinit();
    }

    pub fn requestLayout(self: *InteractiveText, gid: ?GlobalElementId, rl: *void, window: *Window, cx: *App) LayoutId {
        const st = window.elementStateInit(InteractiveTextState, gid.?, .{ .layout = .{ .gpa = cx.gpa } });
        // Keep the layout in element state: listeners use it after the frame arena is gone.
        if (self.text.owns_layout) self.text.layout_ptr.deinit();
        self.text.layout_ptr = &st.layout;
        self.text.owns_layout = false;
        st.clickable_ranges.clearRetainingCapacity();
        st.clickable_ranges.appendSlice(cx.gpa, self.clickable_ranges) catch @panic("OOM");
        st.click_listener = self.click_listener;
        st.hover_listener = self.hover_listener;
        return self.text.requestLayout(null, rl, window, cx);
    }

    pub fn prepaint(self: *InteractiveText, _: ?GlobalElementId, bounds: Bounds, rl: *void, hitbox: *Hitbox, window: *Window, cx: *App) void {
        self.text.prepaint(null, bounds, rl, rl, window, cx);
        hitbox.* = window.insertHitbox(bounds, .normal);
    }

    pub fn paint(self: *InteractiveText, gid: ?GlobalElementId, bounds: Bounds, rl: *void, hitbox: *Hitbox, window: *Window, cx: *App) void {
        const st = window.elementStateInit(InteractiveTextState, gid.?, .{ .layout = .{ .gpa = cx.gpa } });
        const Ctx = struct { state: *InteractiveTextState, hitbox: HitboxId, view: EntityId };
        const ctx: Ctx = .{ .state = st, .hitbox = hitbox.id, .view = window.currentView() };
        if (st.click_listener != null) {
            switch (st.layout.indexForPosition(window.mouse_position)) {
                .inside => |ix| if (inRanges(st.clickable_ranges.items, ix) != null) window.setCursorStyle(.pointing_hand, hitbox.*),
                .outside => {},
            }
            window.onMouseEvent(input.MouseDownEvent, ctx, struct {
                fn f(c: *Ctx, ev: *const input.MouseDownEvent, phase: DispatchPhase, w: *Window, _: *App) void {
                    if (phase != .bubble or !c.hitbox.isHovered(w)) return;
                    switch (c.state.layout.indexForPosition(ev.position)) {
                        .inside => |ix| {
                            c.state.mouse_down_index = ix;
                            w.refresh();
                        },
                        .outside => {},
                    }
                }
            }.f);
            window.onMouseEvent(input.MouseUpEvent, ctx, struct {
                fn f(c: *Ctx, ev: *const input.MouseUpEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                    if (phase != .bubble or !c.hitbox.isHovered(w)) return;
                    const down = c.state.mouse_down_index orelse return;
                    c.state.mouse_down_index = null;
                    switch (c.state.layout.indexForPosition(ev.position)) {
                        .inside => |up| for (c.state.clickable_ranges.items, 0..) |r, i| {
                            if (down >= r[0] and down < r[1] and up >= r[0] and up < r[1]) {
                                if (c.state.click_listener) |l| l.callIn(&i, w, a);
                            }
                        },
                        .outside => {},
                    }
                    w.refresh();
                }
            }.f);
        }
        window.onMouseEvent(input.MouseMoveEvent, ctx, struct {
            fn f(c: *Ctx, ev: *const input.MouseMoveEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                if (phase != .bubble or !c.hitbox.isHovered(w)) return;
                const updated: ?usize = switch (c.state.layout.indexForPosition(ev.position)) {
                    .inside => |i| i,
                    .outside => null,
                };
                if (updated != c.state.hovered_index) {
                    c.state.hovered_index = updated;
                    if (c.state.hover_listener) |l| l.callIn(&updated, w, a);
                    a.notify(c.view);
                }
            }
        }.f);
        self.text.paint(null, bounds, rl, rl, window, cx);
    }
};

fn inRanges(ranges: []const [2]usize, ix: usize) ?usize {
    for (ranges, 0..) |r, i| if (ix >= r[0] and ix < r[1]) return i;
    return null;
}
