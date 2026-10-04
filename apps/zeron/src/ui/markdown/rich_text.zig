//! `RichText`: a `StyledText` plus the markdown renderer's paint-only extras —
//! rounded inline-code washes painted UNDER the glyphs (a `TextRun`
//! background can only paint square boxes), clickable link ranges (pointer
//! cursor, click opens the URL through the platform or an owner hook) and a
//! drag selection wash (copied by the owning view via `registry`).
//! Port of zeron `flat_text_element` + `LinkRanges` + `selection.rs`.

const std = @import("std");
const zpui = @import("zpui");

const App = zpui.App;
const Window = zpui.Window;
const Hsla = zpui.Hsla;
const Bounds = zpui.Bounds(f32);
const Point = zpui.Point(f32);
const GlobalElementId = zpui.GlobalElementId;
const ElementId = zpui.ElementId;
const LayoutId = zpui.LayoutId;
const Hitbox = zpui.Hitbox;
const HitboxId = zpui.window.HitboxId;
const DispatchPhase = zpui.DispatchPhase;
const input = zpui.input;
pub const TextLayout = @typeInfo(@typeInfo(@TypeOf(zpui.StyledText.textLayout)).@"fn".return_type.?).pointer.child;

pub const Range = struct { start: usize, end: usize };

/// Opens a link; `url` is borrowed for the call. Return true when handled
/// (otherwise the platform opener runs).
pub const LinkHandler = *const fn (url: []const u8, window: *Window, app: *App) bool;

/// Process-wide link + selection bookkeeping (main thread only).
pub const registry = struct {
    const gpa: std.mem.Allocator = std.heap.smp_allocator;
    /// key → owned URL list for a text element's link ranges.
    var links: std.AutoHashMapUnmanaged(u64, [][]u8) = .empty;
    /// Optional owner hook consulted before the platform opener.
    pub var handler: ?LinkHandler = null;

    /// The current selection: element key + byte range, plus a copy of
    /// that element's text (for copy after the frame is gone).
    pub var sel_key: u64 = 0;
    pub var sel_anchor: usize = 0;
    pub var sel_head: usize = 0;
    pub var sel_text: []u8 = &.{};
    pub var dragging: bool = false;

    pub fn putLinks(key: u64, urls: []const []const u8) void {
        if (links.contains(key)) return;
        if (links.count() > 8192) clearLinks();
        const owned = gpa.alloc([]u8, urls.len) catch return;
        for (urls, owned) |u, *o| o.* = gpa.dupe(u8, u) catch &.{};
        links.put(gpa, key, owned) catch gpa.free(owned);
    }

    fn clearLinks() void {
        var it = links.valueIterator();
        while (it.next()) |v| {
            for (v.*) |u| gpa.free(u);
            gpa.free(v.*);
        }
        links.clearRetainingCapacity();
    }

    pub fn url(key: u64, ix: usize) ?[]const u8 {
        const list = links.get(key) orelse return null;
        return if (ix < list.len) list[ix] else null;
    }

    pub fn selectedText() ?[]const u8 {
        if (sel_key == 0 or sel_anchor == sel_head) return null;
        const a = @min(sel_anchor, sel_head, sel_text.len);
        const b = @min(@max(sel_anchor, sel_head), sel_text.len);
        if (a >= b) return null;
        return sel_text[a..b];
    }

    pub fn hasSelection() bool {
        return selectedText() != null;
    }

    pub fn clearSelection() void {
        sel_key = 0;
        sel_anchor = 0;
        sel_head = 0;
        dragging = false;
    }

    fn setSelText(text: []const u8) void {
        if (std.mem.eql(u8, sel_text, text)) return;
        gpa.free(sel_text);
        sel_text = gpa.dupe(u8, text) catch &.{};
    }
};

/// Open `url` via the owner hook or the platform.
pub fn openLink(url: []const u8, window: *Window, app: *App) void {
    if (registry.handler) |h| if (h(url, window, app)) return;
    app.platform.vtable.openUrl(app.platform.ptr, url);
}

pub const RichText = struct {
    id: ElementId,
    text: zpui.StyledText,
    /// Stable key (selection / link registry identity).
    key: u64,
    code_ranges: []const Range = &.{},
    code_wash: Hsla = zpui.color.transparent_black,
    code_radius: f32 = 4.5,
    code_pad_x: f32 = 2,
    code_inset_y: f32 = 2,
    links: []const Range = &.{},
    selection_wash: Hsla = zpui.color.transparent_black,
    selectable: bool = true,
    /// File-link glyph slots: an `arrow-up-right` icon painted 4px in.
    glyphs: []const Range = &.{},
    glyph_color: Hsla = zpui.color.transparent_black,

    pub const PrepaintState = Hitbox;

    pub const State = struct {
        layout: TextLayout,
        links: std.ArrayList(Range) = .empty,
        text: std.ArrayList(u8) = .empty,
        down_link: ?usize = null,

        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            self.layout.deinit();
            self.links.deinit(gpa);
            self.text.deinit(gpa);
        }
    };

    pub fn intoAnyElement(self: RichText) zpui.AnyElement {
        return zpui.AnyElement.new(self);
    }

    pub fn elementId(self: *RichText) ?ElementId {
        return self.id;
    }

    pub fn deinit(self: *RichText) void {
        self.text.deinit();
    }

    fn stateFor(window: *Window, gid: GlobalElementId, app: *App) *State {
        return window.elementStateInit(State, gid, .{ .layout = .{ .gpa = app.gpa } });
    }

    pub fn requestLayout(self: *RichText, gid: ?GlobalElementId, rl: *void, window: *Window, app: *App) LayoutId {
        const st = stateFor(window, gid.?, app);
        if (self.text.owns_layout) self.text.layout_ptr.deinit();
        self.text.layout_ptr = &st.layout;
        self.text.owns_layout = false;
        st.links.clearRetainingCapacity();
        st.links.appendSlice(app.gpa, self.links) catch @panic("OOM");
        if (self.selectable and !std.mem.eql(u8, st.text.items, self.text.text)) {
            st.text.clearRetainingCapacity();
            st.text.appendSlice(app.gpa, self.text.text) catch @panic("OOM");
        }
        return self.text.requestLayout(null, rl, window, app);
    }

    pub fn prepaint(self: *RichText, _: ?GlobalElementId, bounds: Bounds, rl: *void, hitbox: *Hitbox, window: *Window, app: *App) void {
        self.text.prepaint(null, bounds, rl, rl, window, app);
        hitbox.* = window.insertHitbox(bounds, .normal);
    }

    pub fn paint(self: *RichText, gid: ?GlobalElementId, bounds: Bounds, rl: *void, hitbox: *Hitbox, window: *Window, app: *App) void {
        const st = stateFor(window, gid.?, app);
        const tl = &st.layout;
        const text = self.text.text;
        for (self.code_ranges) |r| paintRangeRects(window, tl, text, r, self.code_pad_x, self.code_inset_y, self.code_radius, self.code_wash);
        if (registry.sel_key == self.key and registry.sel_anchor != registry.sel_head) {
            const a = @min(registry.sel_anchor, registry.sel_head);
            const b = @max(registry.sel_anchor, registry.sel_head);
            paintRangeRects(window, tl, text, .{ .start = a, .end = @min(b, text.len) }, 0, 0, 0, self.selection_wash);
        }
        if (self.links.len > 0) switch (tl.indexForPosition(window.mouse_position)) {
            .inside => |ix| if (inRanges(self.links, ix) != null) window.setCursorStyle(.pointing_hand, hitbox.*),
            .outside => {},
        };
        const Ctx = struct { state: *State, hitbox: HitboxId, key: u64, selectable: bool };
        const ctx: Ctx = .{ .state = st, .hitbox = hitbox.id, .key = self.key, .selectable = self.selectable };
        window.onMouseEvent(input.MouseDownEvent, ctx, struct {
            fn f(c: *Ctx, ev: *const input.MouseDownEvent, phase: DispatchPhase, w: *Window, _: *App) void {
                if (phase != .bubble or !c.hitbox.isHovered(w) or ev.button != .left) return;
                const ix = indexAt(&c.state.layout, ev.position);
                if (inRanges(c.state.links.items, ix)) |li| {
                    c.state.down_link = li;
                    return;
                }
                c.state.down_link = null;
                if (!c.selectable) return;
                registry.setSelText(c.state.text.items);
                registry.sel_key = c.key;
                if (ev.click_count >= 2) {
                    const word = wordAt(c.state.text.items, ix);
                    registry.sel_anchor = word.start;
                    registry.sel_head = word.end;
                } else {
                    registry.sel_anchor = ix;
                    registry.sel_head = ix;
                    registry.dragging = true;
                }
                w.refresh();
            }
        }.f);
        window.onMouseEvent(input.MouseMoveEvent, ctx, struct {
            fn f(c: *Ctx, ev: *const input.MouseMoveEvent, phase: DispatchPhase, w: *Window, _: *App) void {
                if (phase != .bubble or !registry.dragging or registry.sel_key != c.key) return;
                const ix = indexAt(&c.state.layout, ev.position);
                if (ix != registry.sel_head) {
                    registry.sel_head = ix;
                    w.refresh();
                }
            }
        }.f);
        window.onMouseEvent(input.MouseUpEvent, ctx, struct {
            fn f(c: *Ctx, ev: *const input.MouseUpEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                if (phase != .bubble) return;
                if (registry.sel_key == c.key) registry.dragging = false;
                const down = c.state.down_link orelse return;
                c.state.down_link = null;
                if (!c.hitbox.isHovered(w)) return;
                const ix = indexAt(&c.state.layout, ev.position);
                if (inRanges(c.state.links.items, ix) == down) {
                    if (registry.url(c.key, down)) |u| openLink(u, w, a);
                }
            }
        }.f);
        self.text.paint(null, bounds, rl, rl, window, app);
        for (self.glyphs) |g| {
            const p = tl.positionForIndex(g.start) orelse continue;
            const size: f32 = 12;
            const b: Bounds = .{ .origin = .{ .x = p.x + 4, .y = p.y + (tl.line_height - size) / 2 }, .size = .{ .width = size, .height = size } };
            window.paintSvg(b, glyph_icon.path(), glyph_icon.svg(), .unit, self.glyph_color);
        }
    }
};

const glyph_icon = @import("zeron_assets").Icon.arrow_up_right;

fn indexAt(tl: *const TextLayout, p: Point) usize {
    return switch (tl.indexForPosition(p)) {
        .inside => |i| i,
        .outside => |i| i,
    };
}

fn inRanges(ranges: []const Range, ix: usize) ?usize {
    for (ranges, 0..) |r, i| if (ix >= r.start and ix < r.end) return i;
    return null;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn wordAt(text: []const u8, ix: usize) Range {
    var a = @min(ix, text.len);
    var b = a;
    while (a > 0 and isWordByte(text[a - 1])) a -= 1;
    while (b < text.len and isWordByte(text[b])) b += 1;
    return .{ .start = a, .end = b };
}

/// Paint rounded rects covering byte range `r` of a laid-out text, one per
/// visual (soft-wrapped) line segment, from the shaped glyph geometry.
pub fn paintRangeRects(window: *Window, tl: *const TextLayout, text: []const u8, r: Range, pad_x: f32, inset_y: f32, radius: f32, color: Hsla) void {
    _ = text;
    if (r.end <= r.start or color.a <= 0) return;
    const b = tl.bounds orelse return;
    const lh = tl.line_height;
    var y = b.origin.y;
    var line_start: usize = 0;
    for (tl.lines) |line| {
        const layout = line.layout.layout();
        const len = layout.len;
        defer {
            y += line.size(lh).height;
            line_start += len + 1;
        }
        if (r.end <= line_start or r.start > line_start + len) continue;
        const bounds_list = line.wrapBoundaries();
        // Visual line v spans glyphs from boundary v-1 to boundary v.
        var v: usize = 0;
        var v_start_x: f32 = 0;
        var seg_min: f32 = std.math.inf(f32);
        var seg_max: f32 = -std.math.inf(f32);
        var seg_v: usize = 0;
        for (layout.runs, 0..) |run, ri| {
            for (run.glyphs, 0..) |g, gi| {
                if (v < bounds_list.len and bounds_list[v].run_ix == ri and bounds_list[v].glyph_ix == gi) {
                    if (seg_max > seg_min) paintSeg(window, .{ .x = b.origin.x + seg_min, .y = y + @as(f32, @floatFromInt(seg_v)) * lh }, seg_max - seg_min, lh, pad_x, inset_y, radius, color);
                    seg_min = std.math.inf(f32);
                    seg_max = -std.math.inf(f32);
                    v += 1;
                    v_start_x = g.position.x;
                }
                const abs = line_start + g.index;
                if (abs < r.start or abs >= r.end) continue;
                const x0 = g.position.x - v_start_x;
                const x1 = nextX(layout, ri, gi) - v_start_x;
                seg_min = @min(seg_min, x0);
                seg_max = @max(seg_max, x1);
                seg_v = v;
            }
        }
        if (seg_max > seg_min) paintSeg(window, .{ .x = b.origin.x + seg_min, .y = y + @as(f32, @floatFromInt(seg_v)) * lh }, seg_max - seg_min, lh, pad_x, inset_y, radius, color);
    }
}

fn nextX(layout: anytype, ri: usize, gi: usize) f32 {
    if (gi + 1 < layout.runs[ri].glyphs.len) return layout.runs[ri].glyphs[gi + 1].position.x;
    var k = ri + 1;
    while (k < layout.runs.len) : (k += 1) if (layout.runs[k].glyphs.len > 0) return layout.runs[k].glyphs[0].position.x;
    return layout.width;
}

fn paintSeg(window: *Window, origin: Point, width: f32, lh: f32, pad_x: f32, inset_y: f32, radius: f32, color: Hsla) void {
    if (width <= 0) return;
    const b: Bounds = .{
        .origin = .{ .x = origin.x - pad_x, .y = origin.y + inset_y },
        .size = .{ .width = width + 2 * pad_x, .height = lh - 2 * inset_y },
    };
    window.paintQuad(zpui.fill(b, color).cornerRadii(radius));
}
