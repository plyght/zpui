//! `RichText`: a `StyledText` plus the markdown renderer's paint-only extras —
//! rounded inline-code washes painted UNDER the glyphs (a `TextRun`
//! background can only paint square boxes), clickable link ranges (pointer
//! cursor, click opens the URL through the platform or an owner hook) and a
//! drag selection wash (copied by the owning view via `registry`).
//! Port of zeron `flat_text_element` + `LinkRanges` + `selection.rs`, plus
//! `link_presentation.rs` (width-dependent link truncation: a web link wider
//! than the line ends in `…`; selection and copy keep the source text) and
//! `link_destination.rs` (hovering a link discloses its full destination —
//! local text only, never a fetched preview).

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const presentation = @import("link_presentation.zig");

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

pub const Range = presentation.Range;
const TextRun = zpui.text.TextRun;
const AvailableSpace = zpui.AvailableSpace;

/// The theme the destination card is drawn with (set by the renderer each
/// frame; tooltips outlive the frame that built them).
pub var card_theme: ?zt.Theme = null;

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

/// A surface's own link routing (a file preview resolves relative links
/// against its document): `f(owner, url, window, app)`; true = handled.
pub const LinkOwner = struct {
    owner: u64,
    f: *const fn (owner: u64, url: []const u8, window: *Window, app: *App) bool,
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
    /// Web links wider than the line truncate with `…` (`link_presentation`).
    truncate_links: bool = true,
    /// Hovering a link discloses its destination (`link_destination`).
    disclose_links: bool = true,
    /// Consulted before the global handler when a link is activated.
    link_owner: ?LinkOwner = null,

    pub const PrepaintState = struct {
        hitbox: Hitbox,
        /// Invisible hit targets over each link segment carrying the
        /// destination disclosure tooltip.
        overlays: []zpui.AnyElement = &.{},
    };

    pub const State = struct {
        layout: TextLayout,
        /// Link ranges in DISPLAYED coordinates.
        links: std.ArrayList(Range) = .empty,
        /// The source text (selection + copy).
        text: std.ArrayList(u8) = .empty,
        down_link: ?usize = null,
        /// The width-dependent presentation (empty `omissions` = the source
        /// text as is). Ranges are displayed coordinates.
        shown: presentation.Owned = .{},
        presented_width: ?f32 = null,

        pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
            self.layout.deinit();
            self.links.deinit(gpa);
            self.text.deinit(gpa);
            self.shown.deinit(gpa);
        }

        fn truncated(self: *const State) bool {
            return self.shown.omissions.items.len > 0;
        }

        /// Displayed offset → source offset.
        fn original(self: *const State, displayed: usize) usize {
            return presentation.originalOffset(self.shown.omissions.items, displayed);
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
        st.shown.clear();
        st.presented_width = null;
        if (self.selectable and !std.mem.eql(u8, st.text.items, self.text.text)) {
            st.text.clearRetainingCapacity();
            st.text.appendSlice(app.gpa, self.text.text) catch @panic("OOM");
        }
        if (!self.hasTruncatableLink()) return self.text.requestLayout(null, rl, window, app);
        // Width-dependent presentation (`ResponsiveText`): measure decides
        // truncation for the width it is offered.
        const ts = window.textStyle();
        const rem = window.remSize();
        const font_size = ts.font_size.toPixels(rem);
        st.layout.line_height = window.pixelSnap(ts.line_height.toPixels(.{ .pixels = font_size }, rem));
        st.layout.size = null;
        st.layout.bounds = null;
        const runs = self.text.runs orelse blk: {
            const r = zpui.window.arena_mod.frameAllocator().alloc(TextRun, 1) catch @panic("OOM");
            r[0] = ts.toRun(self.text.text.len);
            break :blk r;
        };
        const ctx = zpui.window.arena_mod.current().create(MeasureCtx, .{
            .el = self.*,
            .runs = runs,
            .state = st,
            .font_size = font_size,
            .wrap = ts.white_space == .normal,
        });
        self.text.runs = runs;
        return window.requestMeasuredLayout(.{}, ctx, measure);
    }

    /// Any web link whose label could need truncating.
    fn hasTruncatableLink(self: *const RichText) bool {
        if (!self.truncate_links) return false;
        for (self.links, 0..) |_, i| if (registry.url(self.key, i)) |u| if (presentation.isWebTarget(u)) return true;
        return false;
    }

    const MeasureCtx = struct {
        el: RichText,
        runs: []const TextRun,
        state: *State,
        font_size: f32,
        wrap: bool,
    };

    fn measure(c: *MeasureCtx, known: zpui.layout.Dims(?f32), avail: zpui.layout.Dims(AvailableSpace), window: *Window, _: *App) zpui.Size(f32) {
        const avail_w: ?f32 = switch (avail.width) {
            .definite => |w| w,
            else => null,
        };
        const width = known.width orelse avail_w;
        var size = c.el.present(c.state, c.runs, width, c.font_size, c.wrap, window);
        // Keep the final width equal to the one that decided truncation.
        if (width) |w| size.width = w;
        return size;
    }

    /// Present for `width` (null = unconstrained) and shape into the layout.
    fn present(self: *const RichText, st: *State, runs: []const TextRun, avail_width: ?f32, font_size: f32, wrap: bool, window: *Window) zpui.Size(f32) {
        const gpa = st.layout.gpa;
        st.shown.clear();
        st.presented_width = avail_width;
        var text: []const u8 = self.text.text;
        var shown_runs: []const TextRun = runs;
        if (avail_width) |w| {
            const fa = zpui.window.arena_mod.frameAllocator();
            const urls = fa.alloc([]const u8, self.links.len) catch @panic("OOM");
            for (urls, 0..) |*u, i| u.* = registry.url(self.key, i) orelse "";
            const Measurer = struct {
                window: *Window,
                font_size: f32,
                pub fn width(m: @This(), t: []const u8, r: []const TextRun) f32 { // measured
                    const shaped = m.window.text_system.shapeLine(t, m.font_size, r, null) catch return std.math.inf(f32);
                    defer shaped.deinit(m.window.app.gpa);
                    return shaped.width();
                }
            };
            const p = presentation.truncate(fa, .{
                .text = self.text.text,
                .runs = runs,
                .links = self.links,
                .urls = urls,
                .code_ranges = self.code_ranges,
                .glyphs = self.glyphs,
            }, w, Measurer{ .window = window, .font_size = font_size });
            if (p.omissions.len > 0) {
                st.shown.set(gpa, p) catch {};
                text = st.shown.text.items;
                shown_runs = st.shown.runs.items;
                st.links.clearRetainingCapacity();
                st.links.appendSlice(gpa, p.links) catch {};
            } else {
                st.links.clearRetainingCapacity();
                st.links.appendSlice(gpa, self.links) catch {};
            }
        }
        const tl = &st.layout;
        if (tl.lines.len > 0) zpui.text.freeLines(gpa, tl.lines);
        tl.lines = &.{};
        const wrap_width: ?f32 = if (wrap) avail_width else null;
        const lines = window.text_system.shapeText(text, font_size, shown_runs, .{ .wrap_width = wrap_width }) catch {
            tl.size = .zero;
            return .zero;
        };
        var size: zpui.Size(f32) = .zero;
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
        tl.truncate_width = null;
        tl.size = size;
        return size;
    }

    pub fn prepaint(self: *RichText, gid: ?GlobalElementId, bounds: Bounds, rl: *void, ps: *PrepaintState, window: *Window, app: *App) void {
        const st = stateFor(window, gid.?, app);
        // Layout may have probed other widths last: present for the final one.
        if (self.hasTruncatableLink() and st.presented_width != bounds.size.width) {
            const ts = window.textStyle();
            _ = self.present(st, self.text.runs orelse &.{}, bounds.size.width, ts.font_size.toPixels(window.remSize()), ts.white_space == .normal, window);
        }
        self.text.prepaint(null, bounds, rl, rl, window, app);
        ps.* = .{ .hitbox = window.insertHitbox(bounds, .normal) };
        if (st.links.items.len == 0 or !self.disclose_links) return;
        // Destination disclosure: an invisible hit target per link segment.
        const fa = zpui.window.arena_mod.frameAllocator();
        var overlays: std.ArrayList(zpui.AnyElement) = .empty;
        var rects: std.ArrayList(Bounds) = .empty;
        for (st.links.items, 0..) |r, li| {
            rects.clearRetainingCapacity();
            rangeRects(&st.layout, r, fa, &rects);
            for (rects.items, 0..) |rect, part| {
                if (registry.url(self.key, li) == null) continue;
                var hit = zpui.div().id(.{ "link-tip", mixId(self.key, li * 64 + part) })
                    .w(zpui.px(rect.size.width)).h(zpui.px(rect.size.height));
                // Accessibility (zeron link_interaction.rs: `Role::Link` + the link text as
                // label): the first segment of each link is its node; AT activation opens it.
                if (part == 0 and window.a11yActive()) {
                    const shown = if (st.truncated()) st.shown.text.items else self.text.text;
                    const label = std.mem.trim(u8, shown[@min(r.start, shown.len)..@min(r.end, shown.len)], " \n");
                    hit = hit.role(.link).ariaLabel(label).ariaUrl(registry.url(self.key, li).?)
                        .onA11yAction(.click, linkActivation(self.key, li, self.link_owner));
                }
                hit = hit
                    .tooltipWith(LinkTip{ .key = self.key, .ix = @intCast(li) }, Destination.build);
                const el = zpui.intoAnyElement(hit);
                el.prepaintAsRoot(rect.origin, zpui.window.element.avail.definite(rect.size), window, app);
                overlays.append(fa, el) catch break;
            }
        }
        ps.overlays = overlays.items;
    }

    pub fn paint(self: *RichText, gid: ?GlobalElementId, bounds: Bounds, rl: *void, ps: *PrepaintState, window: *Window, app: *App) void {
        const hitbox = &ps.hitbox;
        const st = stateFor(window, gid.?, app);
        const tl = &st.layout;
        const text = self.text.text;
        const truncated = st.truncated();
        const code_ranges = if (truncated) st.shown.code_ranges.items else self.code_ranges;
        const glyphs = if (truncated) st.shown.glyphs.items else self.glyphs;
        for (code_ranges) |r| paintRangeRects(window, tl, text, r, self.code_pad_x, self.code_inset_y, self.code_radius, self.code_wash);
        if (registry.sel_key == self.key and registry.sel_anchor != registry.sel_head) {
            const a = @min(registry.sel_anchor, registry.sel_head);
            const b = @min(@max(registry.sel_anchor, registry.sel_head), text.len);
            // The selection lives in source offsets; an omitted span it
            // touches paints as its whole `…`.
            const r: Range = if (truncated) presentation.displayedRange(st.shown.omissions.items, .{ .start = a, .end = b }) else .{ .start = a, .end = b };
            paintRangeRects(window, tl, text, r, 0, 0, 0, self.selection_wash);
        }
        if (st.links.items.len > 0) switch (tl.indexForPosition(window.mouse_position)) {
            .inside => |ix| if (inRanges(st.links.items, ix) != null) window.setCursorStyle(.pointing_hand, hitbox.*),
            .outside => {},
        };
        const Ctx = struct { state: *State, hitbox: HitboxId, key: u64, selectable: bool, owner: ?LinkOwner };
        const ctx: Ctx = .{ .state = st, .hitbox = hitbox.id, .key = self.key, .selectable = self.selectable, .owner = self.link_owner };
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
                const src_ix = c.state.original(ix);
                if (ev.click_count >= 2) {
                    const word = wordAt(c.state.text.items, src_ix);
                    registry.sel_anchor = word.start;
                    registry.sel_head = word.end;
                } else {
                    registry.sel_anchor = src_ix;
                    registry.sel_head = src_ix;
                    registry.dragging = true;
                }
                w.refresh();
            }
        }.f);
        window.onMouseEvent(input.MouseMoveEvent, ctx, struct {
            fn f(c: *Ctx, ev: *const input.MouseMoveEvent, phase: DispatchPhase, w: *Window, _: *App) void {
                if (phase != .bubble or !registry.dragging or registry.sel_key != c.key) return;
                const ix = c.state.original(indexAt(&c.state.layout, ev.position));
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
                    if (registry.url(c.key, down)) |u| {
                        if (c.owner) |o| if (o.f(o.owner, u, w, a)) return;
                        openLink(u, w, a);
                    }
                }
            }
        }.f);
        self.text.paint(null, bounds, rl, rl, window, app);
        for (ps.overlays) |o| o.paint(window, app);
        for (glyphs) |g| {
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

fn mixId(a: u64, b: usize) u64 {
    var h = std.hash.Wyhash.init(a);
    h.update(std.mem.asBytes(&b));
    return h.final();
}

/// The rects covering byte range `r` of a laid-out text, one per visual
/// (soft-wrapped) line segment (`range_rects`).
pub fn rangeRects(tl: *const TextLayout, r: Range, a: std.mem.Allocator, out: *std.ArrayList(Bounds)) void {
    if (r.end <= r.start) return;
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
        var v: usize = 0;
        var v_start_x: f32 = 0;
        var seg_min: f32 = std.math.inf(f32);
        var seg_max: f32 = -std.math.inf(f32);
        var seg_v: usize = 0;
        for (layout.runs, 0..) |run, ri| {
            for (run.glyphs, 0..) |g, gi| {
                if (v < bounds_list.len and bounds_list[v].run_ix == ri and bounds_list[v].glyph_ix == gi) {
                    if (seg_max > seg_min) out.append(a, .{ .origin = .{ .x = b.origin.x + seg_min, .y = y + @as(f32, @floatFromInt(seg_v)) * lh }, .size = .{ .width = seg_max - seg_min, .height = lh } }) catch return;
                    seg_min = std.math.inf(f32);
                    seg_max = -std.math.inf(f32);
                    v += 1;
                    v_start_x = g.position.x;
                }
                const abs = line_start + g.index;
                if (abs < r.start or abs >= r.end) continue;
                seg_min = @min(seg_min, g.position.x - v_start_x);
                seg_max = @max(seg_max, nextX(layout, ri, gi) - v_start_x);
                seg_v = v;
            }
        }
        if (seg_max > seg_min) out.append(a, .{ .origin = .{ .x = b.origin.x + seg_min, .y = y + @as(f32, @floatFromInt(seg_v)) * lh }, .size = .{ .width = seg_max - seg_min, .height = lh } }) catch return;
    }
}

// ---------------------------------------------------------------------------
// Destination disclosure (link_destination.rs)
// ---------------------------------------------------------------------------

const LinkTip = struct { key: u64, ix: u32 };

/// Opens link `ix` of text `key` (assistive-technology activation of a link node).
fn linkActivation(key: u64, ix: usize, owner: ?LinkOwner) zpui.Listener(zpui.a11y.ActionRequest) {
    const Data = extern struct { ix: u64, owner: u64, f: usize };
    var l: zpui.Listener(zpui.a11y.ActionRequest) = .{ .func = struct {
        fn f(data: *const zpui.core.context.ListenerData, _: *const zpui.a11y.ActionRequest, window: ?*Window, app: *App) void {
            const d = data.get(Data);
            const w = window orelse return;
            const u = registry.url(data.entity, @intCast(d.ix)) orelse return;
            if (d.f != 0) {
                const hook: *const fn (u64, []const u8, *Window, *App) bool = @ptrFromInt(d.f);
                if (hook(d.owner, u, w, app)) return;
            }
            openLink(u, w, app);
        }
    }.f };
    l.data.entity = key;
    l.data.set(Data{ .ix = ix, .owner = if (owner) |o| o.owner else 0, .f = if (owner) |o| @intFromPtr(o.f) else 0 });
    return l;
}

/// `viewport_limits`: the card fits small viewports.
pub fn viewportLimits(width: f32, height: f32) [2]f32 {
    return .{ std.math.clamp(width - 24, 1, 360), std.math.clamp(height - 80, 1, 160) };
}

/// `breakable_url`: invisible break opportunities between characters, so
/// even one long path segment wraps. Presentation only.
pub fn breakableUrl(a: std.mem.Allocator, url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = (std.unicode.Utf8View.init(url) catch return a.dupe(u8, url)).iterator();
    var first = true;
    while (it.nextCodepointSlice()) |cp| {
        // Combining marks and joiners stay glued to their base.
        const c = std.unicode.utf8Decode(cp) catch 0;
        const glue = c == 0x200D or (c >= 0x300 and c <= 0x36F) or (c >= 0xFE00 and c <= 0xFE0F) or (c >= 0x1F3FB and c <= 0x1F3FF) or (c >= 0xE0020 and c <= 0xE007F);
        if (!first and !glue and !(out.items.len >= 3 and std.mem.endsWith(u8, out.items, "\u{200D}"))) try out.appendSlice(a, "\u{200B}");
        first = false;
        try out.appendSlice(a, cp);
    }
    return out.items;
}

/// What the card shows: a file link's decoded path, else the destination.
pub fn shownDestination(a: std.mem.Allocator, url: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, url, "file://")) return url;
    const raw = url["file://".len..];
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '%' and i + 2 < raw.len) {
            if (std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16)) |b| {
                out.append(a, b) catch return raw;
                i += 2;
                continue;
            } else |_| {}
        }
        out.append(a, raw[i]) catch return raw;
    }
    return if (std.unicode.utf8ValidateSlice(out.items)) out.items else raw;
}

/// The hover card: the complete destination, wrapped at any character,
/// scrolling past 160px (`destination_card`).
pub const Destination = struct {
    gpa: std.mem.Allocator,
    text: []u8,

    pub fn build(tip: LinkTip, _: *Window, cx: *App) zpui.Entity(Destination) {
        const url = registry.url(tip.key, tip.ix) orelse "";
        var arena = std.heap.ArenaAllocator.init(cx.gpa);
        defer arena.deinit();
        const shown = shownDestination(arena.allocator(), url);
        const text = breakableUrl(cx.gpa, shown) catch cx.gpa.dupe(u8, shown) catch @panic("OOM");
        return cx.new(Destination, .{ .gpa = cx.gpa, .text = text }) catch @panic("OOM");
    }

    pub fn deinit(self: *Destination) void {
        self.gpa.free(self.text);
    }

    pub fn render(self: *Destination, window: *Window, _: *zpui.Context(Destination)) zpui.AnyElement {
        const theme = &(card_theme orelse return zpui.empty());
        const vp = window.viewportSize();
        const limits = viewportLimits(vp.width, vp.height);
        // Short URLs stay on one line despite the break points: size from
        // the shaped natural width.
        const run: TextRun = .{ .len = self.text.len, .font = .{ .family = theme.font_sans }, .color = theme.text };
        const natural: f32 = if (window.text_system.shapeLine(self.text, 11, &.{run}, null)) |shaped| blk: {
            defer shaped.deinit(window.app.gpa);
            break :blk shaped.width();
        } else |_| limits[0];
        const width = @min(@ceil(natural) + 14, limits[0]);
        const px = zpui.px;
        return zpui.intoAnyElement(zpui.div().id("web-destination-card").relative()
            .w(px(width)).maxW(px(width)).px(px(6)).py(px(4)).rounded(px(4))
            .border1().borderColor(theme.border_strong).bg(theme.surface_raised).shadowSm()
            .fontFamily(theme.font_sans).textSize(px(11)).lineHeight(px(14)).textColor(theme.text)
            .flex().flexCol()
            .child(zpui.div().id("web-destination-scroll").maxH(px(limits[1])).overflowYScroll().child(self.text)));
    }
};

test "disclosure fits small viewports and keeps the complete destination" {
    for ([_][2]f32{ .{ 320, 240 }, .{ 1000, 800 }, .{ 80, 80 } }) |vp| {
        const l = viewportLimits(vp[0], vp[1]);
        try std.testing.expect(l[0] < vp[0] and l[1] < vp[1]);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var url: std.ArrayList(u8) = .empty;
    try url.appendSlice(a, "https://example.com/");
    for (0..500) |_| try url.appendSlice(a, "á界");
    try url.appendSlice(a, "?q=🙂");
    const b = try breakableUrl(a, url.items);
    const back = try a.alloc(u8, std.mem.replacementSize(u8, b, "\u{200B}", ""));
    _ = std.mem.replace(u8, b, "\u{200B}", "", back);
    try std.testing.expectEqualStrings(url.items, back);
    try std.testing.expectEqualStrings("/repo/a b.rs", shownDestination(a, "file:///repo/a%20b.rs"));
}
