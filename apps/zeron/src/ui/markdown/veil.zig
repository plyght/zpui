//! Streaming fade veil — port of zeron `markdown/veil.rs`: per-appended-chunk
//! opacity over already-committed text.
//!
//! Streamed text commits to layout instantly; a purely cosmetic veil
//! dissolves over the newly arrived characters. `ElemVeil` tracks, per
//! rendered text element, the previously rendered flat text; each append
//! registers the new byte range as a chunk with its arrival time, so a fast
//! stream keeps several chunks fading concurrently. A chunk fades exactly
//! once; a settled element returns no spans at all. `applyVeil` multiplies
//! the alpha into the `TextRun` colors covering each chunk — paint-only: a
//! color-only run split never changes shaping or wrapping.
//!
//! Constants and curve match mugen-markdown's `FadePainter`: per-chunk
//! duration `clamp(ema × 3, 120ms, 400ms)` from an EMA of inter-append gaps,
//! text alpha `1 − (1 − p)^1.6`, and a speed boost once 3+ chunks fade at
//! once. Zero translate — opacity only.
//!
//! ```zig
//! var row: veil.RowVeil = .init(gpa);              // or .seeded(gpa)
//! const spans = row.advance(elem_ix, flat.text, now_ns);
//! runs = veil.applyVeil(arena, runs, spans);
//! if (row.isFading()) window.requestAnimationFrame();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const TextRun = @import("zpui").text.TextRun;

/// EMA seed for the inter-append gap (mugen `EMA_SEED_MS`).
pub const ema_seed_ms: f32 = 160.0;
/// Duration clamp (mugen `MIN_FADE_MS` / `MAX_FADE_MS`).
pub const min_fade_ms: f32 = 120.0;
pub const max_fade_ms: f32 = 400.0;
/// Dissolve exponent (mugen: `alpha = (1 - p) ** 1.6`).
pub const curve_pow: f32 = 1.6;
/// Gap clamp feeding the EMA (mugen: `min(gap, 1000)`).
const gap_clamp_ms: f32 = 1000.0;

pub const Range = struct { start: usize, end: usize };

/// A veiled byte range and its current opacity (0..1).
pub const Span = struct { range: Range, alpha: f32 };

const Chunk = struct {
    range: Range,
    started_ns: u64,
    /// Fade duration fixed at arrival from the cadence EMA.
    duration_ms: f32,
};

/// Text alpha for a fade progress `p` (0..1): `1 − (1 − p)^1.6`.
pub fn opacity(p: f32) f32 {
    return 1.0 - std.math.pow(f32, 1.0 - std.math.clamp(p, 0, 1), curve_pow);
}

/// Chunk fade duration for the current inter-append EMA.
pub fn durationMs(ema_ms: f32) f32 {
    return std.math.clamp(ema_ms * 3.0, min_fade_ms, max_fade_ms);
}

/// Fast-stream boost: 3+ concurrent chunks speed up by 30% each.
pub fn boost(active_chunks: usize) f32 {
    return 1.0 + 0.3 * @as(f32, @floatFromInt(active_chunks -| 2));
}

/// EMA update on a new append gap.
pub fn emaNext(ema_ms: f32, gap_ms: f32) f32 {
    return ema_ms * 0.7 + @min(gap_ms, gap_clamp_ms) * 0.3;
}

fn elapsedMs(now_ns: u64, start_ns: u64) f32 {
    return @as(f32, @floatFromInt(now_ns -| start_ns)) / std.time.ns_per_ms;
}

/// Longest common prefix length, snapped back to a UTF-8 char boundary.
pub fn commonPrefix(a: []const u8, b: []const u8) usize {
    var p: usize = 0;
    const n = @min(a.len, b.len);
    while (p < n and a[p] == b[p]) p += 1;
    while (p > 0 and p < b.len and b[p] & 0xC0 == 0x80) p -= 1;
    return p;
}

/// Per-element chunk tracker: remembers the last rendered flat text and
/// fades every newly appended suffix exactly once.
pub const ElemVeil = struct {
    prev: std.ArrayList(u8) = .empty,
    chunks: std.ArrayList(Chunk) = .empty,
    /// EMA of inter-append gaps (drives per-chunk durations).
    ema_ms: f32 = ema_seed_ms,
    last_append_ns: ?u64 = null,
    /// Scratch for the returned spans (valid until the next `advance`).
    out: std.ArrayList(Span) = .empty,

    pub fn deinit(self: *ElemVeil, gpa: Allocator) void {
        self.prev.deinit(gpa);
        self.chunks.deinit(gpa);
        self.out.deinit(gpa);
    }

    /// Adopt `text` as the committed baseline without fading it.
    fn seed(self: *ElemVeil, gpa: Allocator, text: []const u8) void {
        self.prev.clearRetainingCapacity();
        self.prev.appendSlice(gpa, text) catch {};
    }

    /// Advance to `text` at `now_ns`: registers a fading chunk for newly
    /// appended bytes, prunes settled chunks, and returns the active spans.
    /// Idempotent for unchanged text.
    pub fn advance(self: *ElemVeil, gpa: Allocator, text: []const u8, now_ns: u64) []const Span {
        if (!std.mem.eql(u8, text, self.prev.items)) {
            // Non-append rewrites keep the common prefix's committed fades and
            // re-veil only the changed tail.
            const p = commonPrefix(self.prev.items, text);
            var w: usize = 0;
            for (self.chunks.items) |c| {
                var k = c;
                k.range.end = @min(k.range.end, p);
                if (k.range.start < k.range.end) {
                    self.chunks.items[w] = k;
                    w += 1;
                }
            }
            self.chunks.shrinkRetainingCapacity(w);
            if (text.len > p) {
                if (self.last_append_ns) |last| self.ema_ms = emaNext(self.ema_ms, elapsedMs(now_ns, last));
                self.last_append_ns = now_ns;
                self.chunks.append(gpa, .{ .range = .{ .start = p, .end = text.len }, .started_ns = now_ns, .duration_ms = durationMs(self.ema_ms) }) catch {};
            }
            self.prev.clearRetainingCapacity();
            self.prev.appendSlice(gpa, text) catch {};
        }
        const b0 = boost(self.chunks.items.len);
        var w: usize = 0;
        for (self.chunks.items) |c| if (elapsedMs(now_ns, c.started_ns) * b0 < c.duration_ms) {
            self.chunks.items[w] = c;
            w += 1;
        };
        self.chunks.shrinkRetainingCapacity(w);
        const b1 = boost(self.chunks.items.len);
        self.out.clearRetainingCapacity();
        for (self.chunks.items) |c| {
            const progress = std.math.clamp(elapsedMs(now_ns, c.started_ns) * b1 / c.duration_ms, 0, 1);
            self.out.append(gpa, .{ .range = c.range, .alpha = opacity(progress) }) catch {};
        }
        return self.out.items;
    }

    pub fn isFading(self: *const ElemVeil) bool {
        return self.chunks.items.len > 0;
    }
};

/// Veil state for one live streaming row, keyed by the renderer's stable
/// per-element discriminator.
pub const RowVeil = struct {
    gpa: Allocator,
    elems: std.AutoHashMapUnmanaged(usize, ElemVeil) = .empty,
    /// Attach pass in progress: elements first seen while seeding adopt
    /// their current text as the baseline instead of fading it in (switching
    /// back to a streaming chat must not dissolve the whole reply).
    seeding: bool = false,

    pub fn init(gpa: Allocator) RowVeil {
        return .{ .gpa = gpa };
    }

    /// A veil whose first render pass seeds baselines instead of fading.
    pub fn seeded(gpa: Allocator) RowVeil {
        return .{ .gpa = gpa, .seeding = true };
    }

    pub fn deinit(self: *RowVeil) void {
        var it = self.elems.valueIterator();
        while (it.next()) |e| e.deinit(self.gpa);
        self.elems.deinit(self.gpa);
    }

    /// The attach pass is over: elements that appear from here on fade.
    pub fn finishSeeding(self: *RowVeil) void {
        self.seeding = false;
    }

    pub fn advance(self: *RowVeil, elem: usize, text: []const u8, now_ns: u64) []const Span {
        const gpa = self.gpa;
        const gop = self.elems.getOrPut(gpa, elem) catch return &.{};
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
            if (self.seeding) {
                gop.value_ptr.seed(gpa, text);
                return &.{};
            }
        }
        return gop.value_ptr.advance(gpa, text, now_ns);
    }

    /// Any element still fading? Drives the per-frame repaint request.
    pub fn isFading(self: *const RowVeil) bool {
        var it = self.elems.valueIterator();
        while (it.next()) |e| if (e.isFading()) return true;
        return false;
    }
};

/// Intersect spans with `[start, end)` and shift them to local offsets (per
/// code line, with chunks tracked on the whole code text).
pub fn sliceSpans(a: Allocator, spans: []const Span, start: usize, end: usize) []const Span {
    var out: std.ArrayList(Span) = .empty;
    for (spans) |sp| {
        const s = @max(sp.range.start, start);
        const e = @min(sp.range.end, end);
        if (s < e) out.append(a, .{ .range = .{ .start = s - start, .end = e - start }, .alpha = sp.alpha }) catch {};
    }
    return out.items;
}

/// Multiply veil opacities into the runs' paint colors, splitting runs at
/// span boundaries. Fonts and lengths are untouched (total length preserved).
pub fn applyVeil(a: Allocator, runs: []const TextRun, spans: []const Span) []const TextRun {
    if (spans.len == 0) return runs;
    var any = false;
    for (spans) |sp| if (sp.alpha < 1.0) {
        any = true;
    };
    if (!any) return runs;
    var out: std.ArrayList(TextRun) = .empty;
    var pos: usize = 0;
    for (runs) |run| {
        const start = pos;
        const end = pos + run.len;
        pos = end;
        var cuts: std.ArrayList(usize) = .empty;
        cuts.append(a, start) catch return runs;
        cuts.append(a, end) catch return runs;
        for (spans) |sp| {
            if (sp.range.start > start and sp.range.start < end) cuts.append(a, sp.range.start) catch return runs;
            if (sp.range.end > start and sp.range.end < end) cuts.append(a, sp.range.end) catch return runs;
        }
        std.mem.sort(usize, cuts.items, {}, std.sort.asc(usize));
        var i: usize = 0;
        while (i + 1 < cuts.items.len) : (i += 1) {
            const s = cuts.items[i];
            const e = cuts.items[i + 1];
            if (s == e) continue;
            var piece = run;
            piece.len = e - s;
            for (spans) |sp| if (sp.range.start <= s and e <= sp.range.end) {
                if (sp.alpha < 1.0) {
                    piece.color = piece.color.opacity(sp.alpha);
                    if (piece.background_color) |c| piece.background_color = c.opacity(sp.alpha);
                    if (piece.underline) |*u| if (u.color) |c| {
                        u.color = c.opacity(sp.alpha);
                    };
                    if (piece.strikethrough) |*st| if (st.color) |c| {
                        st.color = c.opacity(sp.alpha);
                    };
                }
                break;
            };
            out.append(a, piece) catch return runs;
        }
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests (veil.rs)
// ---------------------------------------------------------------------------

const testing = std.testing;
const ms = std.time.ns_per_ms;

fn expectSpans(want: []const Span, got: []const Span) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqual(w.range, g.range);
        try testing.expectApproxEqAbs(w.alpha, g.alpha, 1e-6);
    }
}

test "first text fades and settles once" {
    const gpa = testing.allocator;
    var v: ElemVeil = .{};
    defer v.deinit(gpa);
    const t0: u64 = 1_000_000_000;
    try expectSpans(&.{.{ .range = .{ .start = 0, .end = 5 }, .alpha = 0 }}, v.advance(gpa, "hello", t0));
    const mid = v.advance(gpa, "hello", t0 + 250 * ms);
    try testing.expectEqual(@as(usize, 1), mid.len);
    try testing.expect(mid[0].alpha > 0 and mid[0].alpha < 1);
    try testing.expectEqual(@as(usize, 0), v.advance(gpa, "hello", t0 + 600 * ms).len);
    try testing.expect(!v.isFading());
    try testing.expectEqual(@as(usize, 0), v.advance(gpa, "hello", t0 + 700 * ms).len);
}

test "appended chunks fade concurrently and independently" {
    const gpa = testing.allocator;
    var v: ElemVeil = .{};
    defer v.deinit(gpa);
    const t0: u64 = 5 * std.time.ns_per_s;
    _ = v.advance(gpa, "one ", t0);
    const spans = v.advance(gpa, "one two ", t0 + 100 * ms);
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expectEqual(Range{ .start = 0, .end = 4 }, spans[0].range);
    try testing.expectEqual(Range{ .start = 4, .end = 8 }, spans[1].range);
    try testing.expect(spans[0].alpha > spans[1].alpha);
    const later = v.advance(gpa, "one two ", t0 + 410 * ms);
    try testing.expectEqual(@as(usize, 1), later.len);
    try testing.expectEqual(Range{ .start = 4, .end = 8 }, later[0].range);
}

test "fade constants match mugen FadePainter" {
    try testing.expectEqual(@as(f32, 400), durationMs(160));
    try testing.expectEqual(@as(f32, 120), durationMs(30));
    try testing.expectEqual(@as(f32, 180), durationMs(60));
    try testing.expectEqual(@as(f32, 160.0 * 0.7 + 100.0 * 0.3), emaNext(160, 100));
    try testing.expectEqual(@as(f32, 160.0 * 0.7 + 1000.0 * 0.3), emaNext(160, 5000));
    try testing.expectEqual(@as(f32, 1), boost(0));
    try testing.expectEqual(@as(f32, 1), boost(2));
    try testing.expectApproxEqAbs(@as(f32, 1.3), boost(3), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.9), boost(5), 1e-6);
}

test "seeded row adopts existing text without fading" {
    const gpa = testing.allocator;
    var row = RowVeil.seeded(gpa);
    defer row.deinit();
    const t0: u64 = 1;
    try testing.expectEqual(@as(usize, 0), row.advance(0, "already streamed text", t0).len);
    try testing.expectEqual(@as(usize, 0), row.advance(1, "second block", t0).len);
    try testing.expect(!row.isFading());
    try expectSpans(&.{.{ .range = .{ .start = 21, .end = 26 }, .alpha = 0 }}, row.advance(0, "already streamed text plus", t0 + 100 * ms));
    row.finishSeeding();
    try expectSpans(&.{.{ .range = .{ .start = 0, .end = 9 }, .alpha = 0 }}, row.advance(2, "new block", t0 + 200 * ms));
}

test "faded text never reanimates; rewrites keep the prefix" {
    const gpa = testing.allocator;
    var v: ElemVeil = .{};
    defer v.deinit(gpa);
    _ = v.advance(gpa, "stable", 0);
    try testing.expectEqual(@as(usize, 0), v.advance(gpa, "stable", 600 * ms).len);
    try expectSpans(&.{.{ .range = .{ .start = 6, .end = 11 }, .alpha = 0 }}, v.advance(gpa, "stable more", 700 * ms));

    var w: ElemVeil = .{};
    defer w.deinit(gpa);
    _ = w.advance(gpa, "intro **bol", 0);
    const spans = w.advance(gpa, "intro bold", 100 * ms);
    try testing.expectEqual(@as(usize, 2), spans.len);
    try testing.expectEqual(Range{ .start = 0, .end = 6 }, spans[0].range);
    try testing.expectEqual(Range{ .start = 6, .end = 10 }, spans[1].range);
    try testing.expect(spans[0].alpha > spans[1].alpha);
}

test "common prefix respects char boundaries; opacity curve" {
    try testing.expectEqual(@as(usize, 0), commonPrefix("é", "è"));
    try testing.expectEqual(@as(usize, 2), commonPrefix("abé", "abè"));
    try testing.expectEqual(@as(usize, 4), commonPrefix("same", "same"));
    try testing.expectEqual(@as(f32, 0), opacity(0));
    try testing.expectEqual(@as(f32, 1), opacity(1));
    try testing.expectApproxEqAbs(1.0 - std.math.pow(f32, 0.5, 1.6), opacity(0.5), 1e-6);
    try testing.expect(opacity(0.5) > 0.5);
    try testing.expectEqual(@as(f32, 0), opacity(-1));
    try testing.expectEqual(@as(f32, 1), opacity(2));
}

test "applyVeil preserves length and fonts; slices shift to local offsets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const white = @import("zpui").hsla(0, 0, 1, 1);
    const runs = [_]TextRun{ .{ .len = 4, .font = .{ .family = "Test" }, .color = white }, .{ .len = 6, .font = .{ .family = "Test" }, .color = white } };
    const out = applyVeil(a, &runs, &.{.{ .range = .{ .start = 2, .end = 8 }, .alpha = 0.5 }});
    var lens: [4]usize = undefined;
    for (out, 0..) |r, i| lens[i] = r.len;
    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expectEqualSlices(usize, &.{ 2, 2, 4, 2 }, &lens);
    try testing.expectEqual(@as(f32, 1), out[0].color.a);
    try testing.expectEqual(@as(f32, 0.5), out[1].color.a);
    try testing.expectEqual(@as(f32, 0.5), out[2].color.a);
    try testing.expectEqual(@as(f32, 1), out[3].color.a);
    try testing.expectEqual(@as(usize, 2), applyVeil(a, &runs, &.{.{ .range = .{ .start = 0, .end = 10 }, .alpha = 1 }}).len);
    const local = sliceSpans(a, &.{ .{ .range = .{ .start = 3, .end = 10 }, .alpha = 0.4 }, .{ .range = .{ .start = 12, .end = 20 }, .alpha = 0.1 } }, 5, 15);
    try testing.expectEqual(@as(usize, 2), local.len);
    try testing.expectEqual(Range{ .start = 0, .end = 5 }, local[0].range);
    try testing.expectEqual(Range{ .start = 7, .end = 10 }, local[1].range);
}
