//! Shaped line layouts, wrap boundaries and the two-frame `LineLayoutCache`
//! (gpui `text_system/line_layout.rs`).
//!
//! Layouts are reference counted (`SharedLineLayout`, `SharedWrappedLayout`), the
//! Zig equivalent of gpui's `Arc<LineLayout>`: the cache holds one reference per
//! frame it lives in and every handed-out layout holds another, released with
//! `release()`. Not thread-safe: use from the thread that owns the window.

const std = @import("std");
const types = @import("types.zig");
const platform = @import("../platform/platform.zig");
const geometry = @import("../geometry.zig");
const fallback = @import("fallback.zig");
const line_wrapper = @import("line_wrapper.zig");

const Allocator = std.mem.Allocator;
const Pixels = types.Pixels;
const FontId = types.FontId;
const FontRun = types.FontRun;
const LineLayout = types.LineLayout;
const ShapedRun = types.ShapedRun;
const ShapedGlyph = types.ShapedGlyph;
const Point = geometry.Point(Pixels);
const Size = geometry.Size(Pixels);

// ---------------------------------------------------------------------------
// LineLayout queries (gpui `impl LineLayout`)
// ---------------------------------------------------------------------------

/// UTF-8 index of the glyph containing `x`, or null if `x` is past the end.
pub fn indexForX(layout: *const LineLayout, x: Pixels) ?usize {
    if (x >= layout.width) return null;
    var r = layout.runs.len;
    while (r > 0) {
        r -= 1;
        const glyphs = layout.runs[r].glyphs;
        var g = glyphs.len;
        while (g > 0) {
            g -= 1;
            if (glyphs[g].position.x <= x) return glyphs[g].index;
        }
    }
    return 0;
}

/// UTF-8 index of the glyph boundary closest to `x` (for caret placement).
pub fn closestIndexForX(layout: *const LineLayout, x: Pixels) usize {
    var prev_index: usize = 0;
    var prev_x: Pixels = 0;
    for (layout.runs) |run| {
        for (run.glyphs) |glyph| {
            if (glyph.position.x >= x) {
                return if (glyph.position.x - x < x - prev_x) glyph.index else prev_index;
            }
            prev_index = glyph.index;
            prev_x = glyph.position.x;
        }
    }
    if (layout.len == 1) return if (x > layout.width / 2) 1 else 0;
    return layout.len;
}

/// X position of the glyph at (or after) UTF-8 `index`; the line width past the end.
pub fn xForIndex(layout: *const LineLayout, index: usize) Pixels {
    for (layout.runs) |run| {
        for (run.glyphs) |glyph| {
            if (glyph.index >= index) return glyph.position.x;
        }
    }
    return layout.width;
}

pub fn fontIdForIndex(layout: *const LineLayout, index: usize) ?FontId {
    for (layout.runs) |run| {
        for (run.glyphs) |glyph| {
            if (glyph.index >= index) return run.font_id;
        }
    }
    return null;
}

/// Glyph addressed by a wrap boundary.
pub const WrapBoundary = struct {
    run_ix: usize,
    glyph_ix: usize,

    pub fn order(a: WrapBoundary, b: WrapBoundary) std.math.Order {
        if (a.run_ix != b.run_ix) return std.math.order(a.run_ix, b.run_ix);
        return std.math.order(a.glyph_ix, b.glyph_ix);
    }
    pub fn eql(a: WrapBoundary, b: WrapBoundary) bool {
        return a.run_ix == b.run_ix and a.glyph_ix == b.glyph_ix;
    }
};

pub fn glyphAt(layout: *const LineLayout, b: WrapBoundary) ShapedGlyph {
    return layout.runs[b.run_ix].glyphs[b.glyph_ix];
}

/// gpui `LineLayout::compute_wrap_boundaries`: soft-wrap a shaped line at `wrap_width`,
/// using shaped glyph positions and the same break rules as `LineWrapper.wrapLine`
/// (including zui's rule keeping closing punctuation with its word).
pub fn computeWrapBoundaries(
    gpa: Allocator,
    layout: *const LineLayout,
    text: []const u8,
    wrap_width: Pixels,
    max_lines: ?usize,
) ![]WrapBoundary {
    var boundaries: std.ArrayList(WrapBoundary) = .empty;
    errdefer boundaries.deinit(gpa);

    var first_non_whitespace: ?WrapBoundary = null;
    var last_candidate: ?WrapBoundary = null;
    var last_candidate_x: Pixels = 0;
    var last_boundary: WrapBoundary = .{ .run_ix = 0, .glyph_ix = 0 };
    var last_boundary_x: Pixels = 0;
    var prev_ch: u21 = 0;

    for (layout.runs, 0..) |run, run_ix| {
        for (run.glyphs, 0..) |glyph, glyph_ix| {
            const boundary: WrapBoundary = .{ .run_ix = run_ix, .glyph_ix = glyph_ix };
            const ch = if (glyph.index < text.len) fallback.decodeAt(text, glyph.index).cp else ' ';
            const x = glyph.position.x;
            if (ch == '\n') continue;

            if (line_wrapper.isWordChar(ch)) {
                if (prev_ch == ' ' and ch != ' ' and first_non_whitespace != null) {
                    last_candidate = boundary;
                    last_candidate_x = x;
                }
            } else if (ch != ' ' and !line_wrapper.isWordChar(prev_ch) and first_non_whitespace != null) {
                last_candidate = boundary;
                last_candidate_x = x;
            }

            if (ch != ' ' and first_non_whitespace == null) first_non_whitespace = boundary;

            const next_x = nextGlyphX(layout, run_ix, glyph_ix) orelse layout.width;
            const width = next_x - last_boundary_x;
            if (width > wrap_width and boundary.order(last_boundary) == .gt) {
                if (max_lines) |max| {
                    if (boundaries.items.len >= max -| 1) return boundaries.toOwnedSlice(gpa);
                }
                if (last_candidate) |c| {
                    last_boundary = c;
                    last_boundary_x = last_candidate_x;
                    last_candidate = null;
                } else {
                    last_boundary = boundary;
                    last_boundary_x = x;
                }
                try boundaries.append(gpa, last_boundary);
            }
            prev_ch = ch;
        }
    }
    return boundaries.toOwnedSlice(gpa);
}

fn nextGlyphX(layout: *const LineLayout, run_ix: usize, glyph_ix: usize) ?Pixels {
    if (glyph_ix + 1 < layout.runs[run_ix].glyphs.len) return layout.runs[run_ix].glyphs[glyph_ix + 1].position.x;
    var r = run_ix + 1;
    while (r < layout.runs.len) : (r += 1) {
        if (layout.runs[r].glyphs.len > 0) return layout.runs[r].glyphs[0].position.x;
    }
    return null;
}

/// gpui `apply_force_width_to_layout`: snap base glyphs to a fixed cell grid,
/// keeping zero-advance combining marks attached to their base.
pub fn applyForceWidth(layout: *LineLayout, force_width: Pixels) void {
    var glyph_pos: usize = 0;
    var last_base_shaped_x: Pixels = -std.math.inf(Pixels);
    var last_base_actual_x: Pixels = 0;
    for (layout.runs) |run| {
        for (run.glyphs) |*glyph| {
            const shaped_x = glyph.position.x;
            if (shaped_x > last_base_shaped_x + force_width * 0.5) {
                const forced_x = @as(Pixels, @floatFromInt(glyph_pos)) * force_width;
                if (@abs(shaped_x - forced_x) > 1) glyph.position.x = forced_x;
                last_base_shaped_x = shaped_x;
                last_base_actual_x = glyph.position.x;
                glyph_pos += 1;
            } else {
                glyph.position.x = last_base_actual_x + (shaped_x - last_base_shaped_x);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Reference-counted layouts
// ---------------------------------------------------------------------------

/// A `LineLayout` plus the arena owning its runs/glyphs (gpui `Arc<LineLayout>`).
pub const SharedLineLayout = struct {
    ref_count: u32 = 1,
    gpa: Allocator,
    arena: std.heap.ArenaAllocator.State,
    layout: LineLayout,

    /// Takes ownership of `arena` (which must own `layout`'s slices).
    pub fn create(gpa: Allocator, arena: std.heap.ArenaAllocator, layout: LineLayout) !*SharedLineLayout {
        const self = try gpa.create(SharedLineLayout);
        self.* = .{ .gpa = gpa, .arena = arena.state, .layout = layout };
        return self;
    }

    pub fn retain(self: *SharedLineLayout) *SharedLineLayout {
        self.ref_count += 1;
        return self;
    }

    pub fn release(self: *SharedLineLayout) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.arena.promote(self.gpa).deinit();
            self.gpa.destroy(self);
        }
    }
};

/// gpui `WrappedLineLayout`: an unwrapped layout plus soft-wrap boundaries.
pub const SharedWrappedLayout = struct {
    ref_count: u32 = 1,
    gpa: Allocator,
    unwrapped: *SharedLineLayout,
    wrap_boundaries: []WrapBoundary,
    wrap_width: ?Pixels,

    pub fn retain(self: *SharedWrappedLayout) *SharedWrappedLayout {
        self.ref_count += 1;
        return self;
    }

    pub fn release(self: *SharedWrappedLayout) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.unwrapped.release();
            self.gpa.free(self.wrap_boundaries);
            self.gpa.destroy(self);
        }
    }

    pub fn layout(self: *const SharedWrappedLayout) *const LineLayout {
        return &self.unwrapped.layout;
    }
    pub fn len(self: *const SharedWrappedLayout) usize {
        return self.unwrapped.layout.len;
    }
    pub fn width(self: *const SharedWrappedLayout) Pixels {
        return @min(self.wrap_width orelse std.math.floatMax(Pixels), self.unwrapped.layout.width);
    }
    pub fn size(self: *const SharedWrappedLayout, line_height: Pixels) Size {
        return .{
            .width = self.width(),
            .height = line_height * @as(Pixels, @floatFromInt(self.wrap_boundaries.len + 1)),
        };
    }

    /// Result of a hit test: `inside` the text, or the nearest index `outside` it.
    pub const PositionIndex = union(enum) { inside: usize, outside: usize };

    pub fn indexForPosition(self: *const SharedWrappedLayout, position: Point, line_height: Pixels) PositionIndex {
        return self.indexForPositionImpl(position, line_height, false);
    }
    pub fn closestIndexForPosition(self: *const SharedWrappedLayout, position: Point, line_height: Pixels) PositionIndex {
        return self.indexForPositionImpl(position, line_height, true);
    }

    fn indexForPositionImpl(self: *const SharedWrappedLayout, position: Point, line_height: Pixels, closest: bool) PositionIndex {
        const l = self.layout();
        const wrapped_line_ix: usize = if (position.y <= 0) 0 else @intFromFloat(position.y / line_height);
        var start_index: usize = 0;
        var start_x: Pixels = 0;
        if (wrapped_line_ix > 0) {
            if (wrapped_line_ix - 1 >= self.wrap_boundaries.len) return .{ .outside = 0 };
            const g = glyphAt(l, self.wrap_boundaries[wrapped_line_ix - 1]);
            start_index = g.index;
            start_x = g.position.x;
        }
        var end_index = l.len;
        var end_x = l.width;
        if (wrapped_line_ix < self.wrap_boundaries.len) {
            const g = glyphAt(l, self.wrap_boundaries[wrapped_line_ix]);
            end_index = g.index;
            end_x = g.position.x;
        }
        const x = position.x + start_x;
        if (x < start_x) return .{ .outside = start_index };
        if (x >= end_x) return .{ .outside = end_index };
        return .{ .inside = if (closest) closestIndexForX(l, x) else indexForX(l, x).? };
    }

    /// Position (relative to the paragraph origin) of the caret at UTF-8 `index`.
    pub fn positionForIndex(self: *const SharedWrappedLayout, index: usize, line_height: Pixels) ?Point {
        const l = self.layout();
        var line_start_ix: usize = 0;
        var ix: usize = 0;
        while (ix <= self.wrap_boundaries.len) : (ix += 1) {
            const line_end_ix = if (ix < self.wrap_boundaries.len) glyphAt(l, self.wrap_boundaries[ix]).index else l.len;
            const line_y = @as(Pixels, @floatFromInt(ix)) * line_height;
            if (index < line_start_ix) break;
            if (index > line_end_ix) {
                line_start_ix = line_end_ix;
                continue;
            }
            const line_start_x = xForIndex(l, line_start_ix);
            return .{ .x = xForIndex(l, index) - line_start_x, .y = line_y };
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// LineLayoutCache
// ---------------------------------------------------------------------------

const CacheKey = struct {
    ref_count: u32 = 1,
    hash: u64,
    /// Owned text; empty for content-hash keys.
    text: []const u8,
    /// Caller-provided content hash (`by_hash` keys only).
    text_hash: u64,
    text_len: usize,
    by_hash: bool,
    font_size: Pixels,
    runs: []const FontRun,
    wrap_width: ?Pixels,
    force_width: ?Pixels,

    fn view(self: *const CacheKey) KeyRef {
        return .{
            .text = self.text,
            .text_hash = self.text_hash,
            .text_len = self.text_len,
            .by_hash = self.by_hash,
            .font_size = self.font_size,
            .runs = self.runs,
            .wrap_width = self.wrap_width,
            .force_width = self.force_width,
        };
    }

    fn create(gpa: Allocator, ref: KeyRef) !*CacheKey {
        const key = try gpa.create(CacheKey);
        errdefer gpa.destroy(key);
        const text = try gpa.dupe(u8, ref.text);
        errdefer gpa.free(text);
        key.* = .{
            .hash = ref.computeHash(),
            .text = text,
            .text_hash = ref.text_hash,
            .text_len = ref.text_len,
            .by_hash = ref.by_hash,
            .font_size = ref.font_size,
            .runs = try gpa.dupe(FontRun, ref.runs),
            .wrap_width = ref.wrap_width,
            .force_width = ref.force_width,
        };
        return key;
    }

    fn retain(self: *CacheKey) *CacheKey {
        self.ref_count += 1;
        return self;
    }

    fn release(self: *CacheKey, gpa: Allocator) void {
        self.ref_count -= 1;
        if (self.ref_count == 0) {
            gpa.free(self.text);
            gpa.free(self.runs);
            gpa.destroy(self);
        }
    }
};

/// Borrowed lookup key.
const KeyRef = struct {
    text: []const u8 = "",
    text_hash: u64 = 0,
    text_len: usize,
    by_hash: bool = false,
    font_size: Pixels,
    runs: []const FontRun,
    wrap_width: ?Pixels = null,
    force_width: ?Pixels = null,

    fn computeHash(self: KeyRef) u64 {
        var h = std.hash.Wyhash.init(0);
        if (self.by_hash) h.update(std.mem.asBytes(&self.text_hash)) else h.update(self.text);
        h.update(std.mem.asBytes(&self.text_len));
        h.update(std.mem.asBytes(&self.by_hash));
        h.update(std.mem.asBytes(&self.font_size));
        for (self.runs) |r| {
            h.update(std.mem.asBytes(&r.len));
            h.update(std.mem.asBytes(&r.font_id));
        }
        hashOptional(&h, self.wrap_width);
        hashOptional(&h, self.force_width);
        return h.final();
    }

    fn eql(a: KeyRef, b: KeyRef) bool {
        if (a.by_hash != b.by_hash or a.text_len != b.text_len or a.font_size != b.font_size) return false;
        if (a.by_hash) {
            if (a.text_hash != b.text_hash) return false;
        } else if (!std.mem.eql(u8, a.text, b.text)) return false;
        if (!std.meta.eql(a.wrap_width, b.wrap_width) or !std.meta.eql(a.force_width, b.force_width)) return false;
        if (a.runs.len != b.runs.len) return false;
        for (a.runs, b.runs) |x, y| {
            if (x.len != y.len or x.font_id != y.font_id) return false;
        }
        return true;
    }
};

fn hashOptional(h: *std.hash.Wyhash, v: ?Pixels) void {
    if (v) |x| {
        h.update(&.{1});
        h.update(std.mem.asBytes(&x));
    } else h.update(&.{0});
}

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: *CacheKey) u64 {
        return k.hash;
    }
    pub fn eql(_: KeyContext, a: *CacheKey, b: *CacheKey) bool {
        return a == b or (a.hash == b.hash and a.view().eql(b.view()));
    }
};

const RefContext = struct {
    hash_value: u64,
    pub fn hash(self: RefContext, _: KeyRef) u64 {
        return self.hash_value;
    }
    pub fn eql(self: RefContext, a: KeyRef, b: *CacheKey) bool {
        return self.hash_value == b.hash and a.eql(b.view());
    }
};

fn Map(comptime V: type) type {
    return std.HashMapUnmanaged(*CacheKey, V, KeyContext, std.hash_map.default_max_load_percentage);
}

const FrameCache = struct {
    lines: Map(*SharedLineLayout) = .empty,
    wrapped_lines: Map(*SharedWrappedLayout) = .empty,
    used_lines: std.ArrayList(*CacheKey) = .empty,
    used_wrapped_lines: std.ArrayList(*CacheKey) = .empty,

    fn clear(self: *FrameCache, gpa: Allocator) void {
        var it = self.lines.iterator();
        while (it.next()) |e| {
            e.key_ptr.*.release(gpa);
            e.value_ptr.*.release();
        }
        var wit = self.wrapped_lines.iterator();
        while (wit.next()) |e| {
            e.key_ptr.*.release(gpa);
            e.value_ptr.*.release();
        }
        for (self.used_lines.items) |k| k.release(gpa);
        for (self.used_wrapped_lines.items) |k| k.release(gpa);
        self.lines.clearRetainingCapacity();
        self.wrapped_lines.clearRetainingCapacity();
        self.used_lines.clearRetainingCapacity();
        self.used_wrapped_lines.clearRetainingCapacity();
    }

    fn deinit(self: *FrameCache, gpa: Allocator) void {
        self.clear(gpa);
        self.lines.deinit(gpa);
        self.wrapped_lines.deinit(gpa);
        self.used_lines.deinit(gpa);
        self.used_wrapped_lines.deinit(gpa);
    }
};

/// Position in the cache's "used" lists, for reusing a cached view's layouts (gpui `LineLayoutIndex`).
pub const LineLayoutIndex = struct {
    lines_index: usize = 0,
    wrapped_lines_index: usize = 0,
};

/// gpui `LineLayoutCache`: layouts shaped this frame, plus last frame's layouts that
/// can be promoted on reuse. `finishFrame` drops everything not used this frame.
pub const LineLayoutCache = struct {
    gpa: Allocator,
    platform: platform.TextSystem,
    previous_frame: FrameCache = .{},
    current_frame: FrameCache = .{},

    pub fn init(gpa: Allocator, platform_text_system: platform.TextSystem) LineLayoutCache {
        return .{ .gpa = gpa, .platform = platform_text_system };
    }

    pub fn deinit(self: *LineLayoutCache) void {
        self.previous_frame.deinit(self.gpa);
        self.current_frame.deinit(self.gpa);
    }

    pub fn layoutIndex(self: *const LineLayoutCache) LineLayoutIndex {
        return .{
            .lines_index = self.current_frame.used_lines.items.len,
            .wrapped_lines_index = self.current_frame.used_wrapped_lines.items.len,
        };
    }

    /// Carry the layouts used between `start` and `end` last frame over into this frame.
    pub fn reuseLayouts(self: *LineLayoutCache, start: LineLayoutIndex, end: LineLayoutIndex) !void {
        const gpa = self.gpa;
        const prev = &self.previous_frame;
        const cur = &self.current_frame;
        for (prev.used_lines.items[start.lines_index..end.lines_index]) |key| {
            if (prev.lines.fetchRemove(key)) |kv| {
                try putOrRelease(*SharedLineLayout, gpa, &cur.lines, kv.key, kv.value);
            }
            try cur.used_lines.append(gpa, key.retain());
        }
        for (prev.used_wrapped_lines.items[start.wrapped_lines_index..end.wrapped_lines_index]) |key| {
            if (prev.wrapped_lines.fetchRemove(key)) |kv| {
                try putOrRelease(*SharedWrappedLayout, gpa, &cur.wrapped_lines, kv.key, kv.value);
            }
            try cur.used_wrapped_lines.append(gpa, key.retain());
        }
    }

    pub fn truncateLayouts(self: *LineLayoutCache, index: LineLayoutIndex) void {
        const cur = &self.current_frame;
        for (cur.used_lines.items[index.lines_index..]) |k| k.release(self.gpa);
        for (cur.used_wrapped_lines.items[index.wrapped_lines_index..]) |k| k.release(self.gpa);
        cur.used_lines.shrinkRetainingCapacity(index.lines_index);
        cur.used_wrapped_lines.shrinkRetainingCapacity(index.wrapped_lines_index);
    }

    pub fn finishFrame(self: *LineLayoutCache) void {
        std.mem.swap(FrameCache, &self.previous_frame, &self.current_frame);
        self.current_frame.clear(self.gpa);
    }

    /// Shape (or fetch) one unwrapped line. Returns a retained reference.
    pub fn layoutLine(self: *LineLayoutCache, text: []const u8, font_size: Pixels, runs: []const FontRun, force_width: ?Pixels) !*SharedLineLayout {
        return self.layoutLineImpl(.{ .text = text, .text_len = text.len, .font_size = font_size, .runs = runs, .force_width = force_width }, text);
    }

    /// Like `layoutLine` but keyed by a caller-provided content hash; `text` is only
    /// shaped on a miss (pass it lazily via `materialize`, called as `materialize.text()`).
    pub fn layoutLineByHash(self: *LineLayoutCache, text_hash: u64, text_len: usize, font_size: Pixels, runs: []const FontRun, force_width: ?Pixels, materialize: anytype) !*SharedLineLayout {
        const ref: KeyRef = .{ .text_hash = text_hash, .text_len = text_len, .by_hash = true, .font_size = font_size, .runs = runs, .force_width = force_width };
        if (try self.lookup(*SharedLineLayout, ref, &self.current_frame.lines, &self.previous_frame.lines, &self.current_frame.used_lines)) |l| return l;
        return self.layoutLineImpl(ref, materialize.text());
    }

    /// Lookup-only variant of `layoutLineByHash`.
    pub fn tryLayoutLineByHash(self: *LineLayoutCache, text_hash: u64, text_len: usize, font_size: Pixels, runs: []const FontRun, force_width: ?Pixels) !?*SharedLineLayout {
        const ref: KeyRef = .{ .text_hash = text_hash, .text_len = text_len, .by_hash = true, .font_size = font_size, .runs = runs, .force_width = force_width };
        return self.lookup(*SharedLineLayout, ref, &self.current_frame.lines, &self.previous_frame.lines, &self.current_frame.used_lines);
    }

    fn layoutLineImpl(self: *LineLayoutCache, ref: KeyRef, text: []const u8) !*SharedLineLayout {
        if (try self.lookup(*SharedLineLayout, ref, &self.current_frame.lines, &self.previous_frame.lines, &self.current_frame.used_lines)) |l| return l;

        const shared = try self.shape(text, ref.font_size, ref.runs, ref.force_width);
        errdefer shared.release();
        const key = try CacheKey.create(self.gpa, ref);
        try self.insert(*SharedLineLayout, &self.current_frame.lines, &self.current_frame.used_lines, key, shared);
        return shared.retain();
    }

    /// Shape (or fetch) a line soft-wrapped at `wrap_width`. Returns a retained reference.
    pub fn layoutWrappedLine(self: *LineLayoutCache, text: []const u8, font_size: Pixels, runs: []const FontRun, wrap_width: ?Pixels, max_lines: ?usize) !*SharedWrappedLayout {
        const ref: KeyRef = .{ .text = text, .text_len = text.len, .font_size = font_size, .runs = runs, .wrap_width = wrap_width };
        if (try self.lookup(*SharedWrappedLayout, ref, &self.current_frame.wrapped_lines, &self.previous_frame.wrapped_lines, &self.current_frame.used_wrapped_lines)) |l| return l;

        const unwrapped = try self.layoutLine(text, font_size, runs, null);
        errdefer unwrapped.release();
        const boundaries = if (wrap_width) |w|
            try computeWrapBoundaries(self.gpa, &unwrapped.layout, text, w, max_lines)
        else
            try self.gpa.alloc(WrapBoundary, 0);
        errdefer self.gpa.free(boundaries);
        const wrapped = try self.gpa.create(SharedWrappedLayout);
        wrapped.* = .{ .gpa = self.gpa, .unwrapped = unwrapped, .wrap_boundaries = boundaries, .wrap_width = wrap_width };
        errdefer wrapped.release();
        const key = try CacheKey.create(self.gpa, ref);
        try self.insert(*SharedWrappedLayout, &self.current_frame.wrapped_lines, &self.current_frame.used_wrapped_lines, key, wrapped);
        return wrapped.retain();
    }

    fn lookup(self: *LineLayoutCache, comptime V: type, ref: KeyRef, cur: *Map(V), prev: *Map(V), used: *std.ArrayList(*CacheKey)) !?V {
        const ctx: RefContext = .{ .hash_value = ref.computeHash() };
        if (cur.getAdapted(ref, ctx)) |v| return v.retain();
        if (prev.fetchRemoveAdapted(ref, ctx)) |kv| {
            try cur.putContext(self.gpa, kv.key, kv.value, .{});
            try used.append(self.gpa, kv.key.retain());
            return kv.value.retain();
        }
        return null;
    }

    fn insert(self: *LineLayoutCache, comptime V: type, map: *Map(V), used: *std.ArrayList(*CacheKey), key: *CacheKey, value: V) !void {
        errdefer key.release(self.gpa);
        try used.ensureUnusedCapacity(self.gpa, 1);
        try map.putContext(self.gpa, key, value, .{});
        used.appendAssumeCapacity(key.retain());
    }

    fn shape(self: *LineLayoutCache, text: []const u8, font_size: Pixels, runs: []const FontRun, force_width: ?Pixels) !*SharedLineLayout {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        errdefer arena.deinit();
        var layout = try self.platform.vtable.layoutLine(self.platform.ptr, arena.allocator(), text, font_size, runs);
        if (force_width) |w| applyForceWidth(&layout, w);
        return SharedLineLayout.create(self.gpa, arena, layout);
    }
};

fn putOrRelease(comptime V: type, gpa: Allocator, map: *Map(V), key: *CacheKey, value: V) !void {
    const gop = try map.getOrPut(gpa, key);
    if (gop.found_existing) {
        key.release(gpa);
        value.release();
    } else gop.value_ptr.* = value;
}
