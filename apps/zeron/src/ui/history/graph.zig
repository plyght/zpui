//! Pure git-history logic — port of zeron `history.rs`: the topological lane
//! layout (`layout_graph`), branch-run folding (`collapse_branch_runs`),
//! search compaction (`compact_commits_to_visible`), responsive graph
//! geometry, ref-badge budgeting, date / author formatting, the fuzzy
//! commit matcher (`git_history_matches`), and a small stroke tessellator
//! for the lane curves (zpui paths are fills).

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

const Commit = types.GitHistoryCommit;
const Ref = types.GitHistoryRef;

pub const page_size: usize = 100;
pub const row_height: f32 = 36;
pub const lane_spacing: f32 = 12;
pub const node_radius: f32 = 3;
pub const head_ring_padding: f32 = 2;
pub const stroke_width: f32 = 1.5;
pub const graph_saturation: f32 = 0.72;
/// `EDGE_INSET * 2 - NODE_RADIUS`: the first lane centers on the header gutter.
pub const side_padding: f32 = 8 * 2 - node_radius;
pub const trailing_padding: f32 = 12;
pub const min_compact_width: f32 = 48;
pub const max_width_ratio: f32 = 0.34;
pub const resize_step: f32 = 2;
pub const compact_enter_subject_width: f32 = 160;
pub const compact_exit_subject_width: f32 = 184;
pub const compact_enter_lane_spacing: f32 = 4;
pub const compact_exit_lane_spacing: f32 = 5;
pub const row_overlap: f32 = 0.75;
pub const focused_stroke_width: f32 = 2.25;
pub const unfocused_opacity: f32 = 0.24;
pub const row_unfocused_opacity: f32 = 0.6;
pub const subject_min_width: f32 = 80;
pub const ref_area_ratio: f32 = 0.45;
pub const ref_badge_max_width: f32 = 112;
pub const ref_gap: f32 = 5;
pub const search_width: f32 = 196;
pub const comparison_min_width: f32 = 260;

/// Default optional column widths (`GitHistoryColumnWidths::default`).
pub const author_width: f32 = 88;
pub const date_width: f32 = 88;
pub const sha_width: f32 = 74;
pub const author_min: f32 = 44;
pub const author_max: f32 = 220;
pub const date_min: f32 = 68;
pub const date_max: f32 = 180;
pub const sha_min: f32 = 58;
pub const sha_max: f32 = 140;

// ---------------------------------------------------------------------------
// Lane layout
// ---------------------------------------------------------------------------

pub const SegmentShape = enum { through, incoming, outgoing };

pub const Segment = struct {
    from_lane: usize,
    to_lane: usize,
    color_id: usize,
    shape: SegmentShape,
};

pub const Row = struct {
    node_lane: usize,
    node_color_id: usize,
    segments: []Segment,
    is_head: bool,
};

pub const Layout = struct {
    rows: []Row = &.{},
    max_lane_count: usize = 0,
};

const ActiveLane = struct {
    id: usize,
    color_id: usize,
    target: []const u8,
};

fn laneIndex(lanes: []const ActiveLane, id: usize) usize {
    for (lanes, 0..) |l, i| if (l.id == id) return i;
    unreachable;
}

/// Commits arrive child-before-parent (`git log --topo-order`). Active lanes
/// point at the parent that will eventually resolve each path. Allocates in
/// `a` (an arena: nothing is freed individually).
pub fn layoutGraph(a: Allocator, commits: []const Commit, head_sha: ?[]const u8) Allocator.Error!Layout {
    var active: std.ArrayList(ActiveLane) = .empty;
    var next_lane_id: usize = 0;
    var next_color_id: usize = 0;
    var max_lanes: usize = 0;
    const out = try a.alloc(Row, commits.len);
    var incoming: std.ArrayList(usize) = .empty;
    var next: std.ArrayList(ActiveLane) = .empty;
    var outgoing: std.ArrayList([2]usize) = .empty;
    var segs: std.ArrayList(Segment) = .empty;
    for (commits, 0..) |c, ci| {
        const before = active.items;
        incoming.clearRetainingCapacity();
        for (before, 0..) |l, i| if (std.mem.eql(u8, l.target, c.sha)) try incoming.append(a, i);
        const primary_in: ?usize = if (incoming.items.len > 0) incoming.items[0] else null;
        const node_lane = primary_in orelse before.len;
        const primary_lane: ?ActiveLane = if (primary_in) |i| before[i] else null;
        const node_color = if (primary_lane) |l| l.color_id else blk: {
            const col = next_color_id;
            next_color_id += 1;
            break :blk col;
        };
        next.clearRetainingCapacity();
        for (before, 0..) |l, i| {
            if (std.mem.indexOfScalar(usize, incoming.items, i) == null) try next.append(a, l);
        }
        outgoing.clearRetainingCapacity();
        var primary_out_id: ?usize = null;
        if (c.parentShas.len > 0) {
            const id = if (primary_lane) |l| l.id else blk: {
                const id = next_lane_id;
                next_lane_id += 1;
                break :blk id;
            };
            try next.insert(a, @min(node_lane, next.items.len), .{ .id = id, .color_id = node_color, .target = c.parentShas[0] });
            primary_out_id = id;
            try outgoing.append(a, .{ id, node_color });
        }
        var parent_offset: usize = 1;
        for (c.parentShas[@min(1, c.parentShas.len)..]) |p| {
            var found: ?ActiveLane = null;
            for (next.items) |l| if (std.mem.eql(u8, l.target, p)) {
                found = l;
                break;
            };
            if (found) |l| {
                try outgoing.append(a, .{ l.id, l.color_id });
                continue;
            }
            const lane: ActiveLane = .{ .id = next_lane_id, .color_id = next_color_id, .target = p };
            next_lane_id += 1;
            next_color_id += 1;
            const primary_ix = if (primary_out_id) |id| laneIndex(next.items, id) else @min(node_lane, next.items.len);
            try next.insert(a, @min(primary_ix + parent_offset, next.items.len), lane);
            parent_offset += 1;
            try outgoing.append(a, .{ lane.id, lane.color_id });
        }
        segs.clearRetainingCapacity();
        for (before, 0..) |l, i| {
            if (std.mem.indexOfScalar(usize, incoming.items, i) != null) continue;
            try segs.append(a, .{ .from_lane = i, .to_lane = laneIndex(next.items, l.id), .color_id = l.color_id, .shape = .through });
        }
        for (incoming.items) |i| try segs.append(a, .{ .from_lane = i, .to_lane = node_lane, .color_id = before[i].color_id, .shape = .incoming });
        for (outgoing.items) |o| try segs.append(a, .{ .from_lane = node_lane, .to_lane = laneIndex(next.items, o[0]), .color_id = o[1], .shape = .outgoing });
        max_lanes = @max(max_lanes, @max(before.len, @max(next.items.len, node_lane + 1)));
        out[ci] = .{
            .node_lane = node_lane,
            .node_color_id = node_color,
            .segments = try a.dupe(Segment, segs.items),
            .is_head = if (head_sha) |h| std.mem.eql(u8, h, c.sha) else false,
        };
        // Swap lane lists.
        const tmp = active;
        active = next;
        next = tmp;
    }
    return .{ .rows = out, .max_lane_count = max_lanes };
}

// ---------------------------------------------------------------------------
// Compaction (search / folded branch runs)
// ---------------------------------------------------------------------------

const ShaSet = std.StringHashMapUnmanaged(void);

/// Keep `visible` commits in order, contracting parent edges across omitted
/// commits to the nearest visible ancestors.
pub fn compactToVisible(a: Allocator, commits: []const Commit, visible: *const ShaSet) Allocator.Error![]Commit {
    var by_sha: std.StringHashMapUnmanaged(usize) = .empty;
    for (commits, 0..) |c, i| try by_sha.put(a, c.sha, i);
    var memo: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    var out: std.ArrayList(Commit) = .empty;
    for (commits) |c| {
        if (!visible.contains(c.sha)) continue;
        var parents: std.ArrayList([]const u8) = .empty;
        var seen: ShaSet = .empty;
        for (c.parentShas) |p| {
            const resolved = try nearestVisible(a, p, visible, &by_sha, commits, &memo, 0);
            for (resolved) |r| if (!seen.contains(r)) {
                try seen.put(a, r, {});
                try parents.append(a, r);
            };
        }
        var copy = c;
        copy.parentShas = parents.items;
        try out.append(a, copy);
    }
    return out.items;
}

fn nearestVisible(a: Allocator, sha: []const u8, visible: *const ShaSet, by_sha: *const std.StringHashMapUnmanaged(usize), commits: []const Commit, memo: *std.StringHashMapUnmanaged([]const []const u8), depth: usize) Allocator.Error![]const []const u8 {
    if (visible.contains(sha) or !by_sha.contains(sha)) {
        const one = try a.alloc([]const u8, 1);
        one[0] = sha;
        return one;
    }
    if (memo.get(sha)) |m| return m;
    // Guard against pathological depth (the Rust walk is iterative).
    if (depth > 4096) return &.{};
    try memo.put(a, sha, &.{}); // cycle guard
    var acc: std.ArrayList([]const u8) = .empty;
    var seen: ShaSet = .empty;
    const c = commits[by_sha.get(sha).?];
    for (c.parentShas) |p| {
        for (try nearestVisible(a, p, visible, by_sha, commits, memo, depth + 1)) |r| if (!seen.contains(r)) {
            try seen.put(a, r, {});
            try acc.append(a, r);
        };
    }
    try memo.put(a, sha, acc.items);
    return acc.items;
}

/// `branch_ref_key`: `local:<label>` / `remote:<label>`; tags have none.
pub fn branchRefKey(a: Allocator, r: Ref) ?[]const u8 {
    const prefix = switch (r.kind) {
        .branch => "local",
        .remote => "remote",
        .tag => return null,
    };
    return std.fmt.allocPrint(a, "{s}:{s}", .{ prefix, r.label }) catch null;
}

pub const Collapsed = struct {
    commits: []const Commit,
    /// Hidden commit count per collapsed ref key.
    hidden: std.StringHashMapUnmanaged(usize) = .empty,
};

/// Remove the linear portions of the selected branch lanes while keeping
/// refs, roots, merges and branch points.
pub fn collapseBranchRuns(a: Allocator, commits: []const Commit, collapsed: *const ShaSet, head_sha: ?[]const u8) Allocator.Error!Collapsed {
    if (collapsed.count() == 0 or commits.len == 0) return .{ .commits = commits };
    const source = try layoutGraph(a, commits, head_sha);
    var colors_by_ref: std.StringHashMapUnmanaged(usize) = .empty;
    for (commits, source.rows) |c, r| for (c.refs) |ref| {
        const key = branchRefKey(a, ref) orelse continue;
        if (collapsed.contains(key)) try colors_by_ref.put(a, key, r.node_color_id);
    };
    if (colors_by_ref.count() == 0) return .{ .commits = commits };
    var child_counts: std.StringHashMapUnmanaged(usize) = .empty;
    for (commits) |c| for (c.parentShas) |p| {
        const gop = try child_counts.getOrPut(a, p);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    };
    var visible: ShaSet = .empty;
    var hidden: std.StringHashMapUnmanaged(usize) = .empty;
    for (commits, source.rows) |c, r| {
        var is_tip = false;
        for (c.refs) |ref| if (branchRefKey(a, ref)) |k| {
            if (collapsed.contains(k)) is_tip = true;
        };
        const is_junction = c.parentShas.len != 1 or (child_counts.get(c.sha) orelse 0) > 1;
        var color_collapsed = false;
        var it = colors_by_ref.valueIterator();
        while (it.next()) |v| if (v.* == r.node_color_id) {
            color_collapsed = true;
        };
        if (color_collapsed and !is_tip and c.refs.len == 0 and !is_junction) {
            var kit = colors_by_ref.iterator();
            while (kit.next()) |e| if (e.value_ptr.* == r.node_color_id) {
                const gop = try hidden.getOrPut(a, e.key_ptr.*);
                gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
            };
        } else try visible.put(a, c.sha, {});
    }
    return .{ .commits = try compactToVisible(a, commits, &visible), .hidden = hidden };
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

pub const Geometry = struct {
    lane_count: usize = 1,
    width: f32 = side_padding + trailing_padding + node_radius * 2,
    lane_spacing: f32 = lane_spacing,
    device_scale: f32 = 1,
    compact: bool = false,

    pub fn natural(count_in: usize) Geometry {
        const count = @max(count_in, 1);
        return .{
            .lane_count = count,
            .width = side_padding + trailing_padding + node_radius * 2 + @as(f32, @floatFromInt(count - 1)) * lane_spacing,
        };
    }

    pub fn fitted(count_in: usize, width_in: f32) Geometry {
        const count = @max(count_in, 1);
        const nat = natural(count);
        if (count == 1 or width_in >= nat.width) return nat;
        const fixed = side_padding + trailing_padding + node_radius * 2;
        const width = std.math.clamp(width_in, fixed, nat.width);
        return .{ .lane_count = count, .width = width, .lane_spacing = (width - fixed) / @as(f32, @floatFromInt(count - 1)) };
    }

    pub fn compactRail(count: usize) Geometry {
        var g = natural(1);
        g.lane_count = @max(count, 1);
        g.lane_spacing = 0;
        g.compact = true;
        return g;
    }

    pub fn laneX(self: Geometry, lane: usize) f32 {
        const x = side_padding + node_radius + @as(f32, @floatFromInt(lane)) * self.lane_spacing;
        return @round(x * self.device_scale) / self.device_scale;
    }
};

/// `interpolate_graph_geometry`: width and lane spacing tween; the full
/// topology stays while lanes converge, the compact rail takes over only once
/// every path shares its x (and expanding does the inverse from frame one).
pub fn interpolate(from: Geometry, to: Geometry, progress_in: f32) Geometry {
    const p = std.math.clamp(progress_in, 0, 1);
    return .{
        .lane_count = to.lane_count,
        .width = from.width + (to.width - from.width) * p,
        .lane_spacing = from.lane_spacing + (to.lane_spacing - from.lane_spacing) * p,
        .device_scale = to.device_scale,
        .compact = if (from.compact) p <= 0.001 else to.compact and p >= 0.999,
    };
}

/// The subject stays primary: the graph takes at most a third of the
/// surface and never eats the subject's minimum or the metadata columns.
pub fn responsiveGeometry(lane_count: usize, container: f32, optional_columns: f32) Geometry {
    const nat = Geometry.natural(lane_count);
    if (nat.width <= min_compact_width) return nat;
    const content_budget = @max(container - optional_columns - subject_min_width, min_compact_width);
    const share_budget = @max(container * max_width_ratio, min_compact_width);
    return Geometry.fitted(lane_count, @min(nat.width, @min(content_budget, share_budget)));
}

pub fn shouldUseCompact(target: Geometry, previous: Geometry, container: f32, optional_columns: f32) bool {
    if (target.lane_count <= 1) return false;
    const subject = container - optional_columns - target.width;
    if (previous.compact) return subject < compact_exit_subject_width or target.lane_spacing < compact_exit_lane_spacing;
    return subject < compact_enter_subject_width or target.lane_spacing < compact_enter_lane_spacing;
}

pub fn stabilizedGeometry(target: Geometry, previous: Geometry, device_scale: f32, compact: bool) Geometry {
    if (compact) {
        var g = Geometry.compactRail(target.lane_count);
        g.device_scale = @max(device_scale, 1);
        return g;
    }
    const nat = Geometry.natural(target.lane_count);
    const is_natural = @abs(target.width - nat.width) < std.math.floatEps(f32);
    const snapped = if (is_natural) nat.width else @floor(target.width / resize_step) * resize_step;
    var next = Geometry.fitted(target.lane_count, snapped);
    next.device_scale = @max(device_scale, 1);
    if (!is_natural and previous.lane_count == next.lane_count and @abs(previous.width - next.width) < resize_step) {
        var stable = previous;
        stable.device_scale = next.device_scale;
        return stable;
    }
    return next;
}

// ---------------------------------------------------------------------------
// Refs / formatting / search
// ---------------------------------------------------------------------------

fn charCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// 10px icon + 2px gap + 10px padding + the 10px label.
pub fn estimatedRefBadgeWidth(r: Ref) f32 {
    return @min(22 + @as(f32, @floatFromInt(charCount(r.label))) * 5.7, ref_badge_max_width);
}

pub fn estimatedRefOverflowWidth(hidden: usize) f32 {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "+{d}", .{hidden}) catch return 12;
    return @as(f32, @floatFromInt(s.len)) * 5.7;
}

pub fn refAreaWidth(commit_column_width: f32) f32 {
    const inner = @max(commit_column_width - 8, 0);
    return @min(inner * ref_area_ratio, @max(inner - subject_min_width - ref_gap, 0));
}

pub fn visibleRefCount(refs: []const Ref, available: f32) usize {
    var visible: usize = 0;
    for (1..refs.len + 1) |count| {
        const hidden = refs.len - count;
        const items = count + @intFromBool(hidden > 0);
        var badges: f32 = 0;
        for (refs[0..count]) |r| badges += estimatedRefBadgeWidth(r);
        const overflow: f32 = if (hidden > 0) estimatedRefOverflowWidth(hidden) else 0;
        const gaps = @as(f32, @floatFromInt(items -| 1)) * ref_gap;
        if (badges + overflow + gaps <= available) visible = count;
    }
    return visible;
}

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// RFC 3339 → "Oct 4, 2026" (in the timestamp's own offset), else "—".
pub fn formatDate(a: Allocator, value: []const u8) []const u8 {
    if (value.len < 10 or value[4] != '-' or value[7] != '-') return "\u{2014}";
    const year = std.fmt.parseInt(u32, value[0..4], 10) catch return "\u{2014}";
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return "\u{2014}";
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return "\u{2014}";
    if (month < 1 or month > 12 or day < 1 or day > 31) return "\u{2014}";
    return std.fmt.allocPrint(a, "{s} {d}, {d}", .{ month_names[month - 1], day, year }) catch "\u{2014}";
}

pub fn authorName(name: []const u8) []const u8 {
    return if (std.mem.trim(u8, name, " \t").len == 0) "Unknown" else name;
}

/// First non-space character, uppercased (ASCII), else "?".
pub fn authorInitial(a: Allocator, name: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, name, " \t");
    if (t.len == 0) return "?";
    const n = std.unicode.utf8ByteSequenceLength(t[0]) catch 1;
    if (n == 1) return std.fmt.allocPrint(a, "{c}", .{std.ascii.toUpper(t[0])}) catch "?";
    return t[0..@min(n, t.len)];
}

/// Subsequence fuzzy match (case-insensitive), as `fuzzy_score(..).is_some()`.
fn fuzzyMatch(query: []const u8, text: []const u8) bool {
    var qi: usize = 0;
    for (text) |c| {
        if (qi >= query.len) break;
        if (query[qi] == ' ') {
            qi += 1;
            continue;
        }
        if (std.ascii.toLower(c) == std.ascii.toLower(query[qi])) qi += 1;
    }
    while (qi < query.len and query[qi] == ' ') qi += 1;
    return qi >= query.len;
}

/// `git_history_matches`: SHA prefix, or a fuzzy match over "sha subject".
pub fn matches(query_in: []const u8, c: Commit) bool {
    const query = std.mem.trim(u8, query_in, " \t");
    if (query.len == 0) return true;
    if (c.sha.len >= query.len and std.ascii.eqlIgnoreCase(c.sha[0..query.len], query)) return true;
    return fuzzyMatch(query, c.subject) or fuzzyMatch(query, c.sha);
}

// ---------------------------------------------------------------------------
// Stroke tessellation
// ---------------------------------------------------------------------------

pub const Pt = struct { x: f32, y: f32 };

/// A polyline flattening of a cubic bezier (`n` segments).
pub fn flattenCubic(out: *[17]Pt, p0: Pt, c1: Pt, c2: Pt, p3: Pt) []Pt {
    const n = 16;
    for (0..n + 1) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / n;
        const u = 1 - t;
        out[i] = .{
            .x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p3.x,
            .y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p3.y,
        };
    }
    return out[0 .. n + 1];
}

/// Quads (as triangle pairs) covering a polyline of `width`.
pub fn strokeQuads(points: []const Pt, width: f32, emit: anytype) void {
    if (points.len < 2) return;
    const hw = width / 2;
    for (points[0 .. points.len - 1], points[1..]) |a, b| {
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 1e-4) continue;
        // Extend each segment by half the width along its direction so
        // consecutive pieces overlap at joints (no cracks on curves).
        const ux = dx / len;
        const uy = dy / len;
        const nx = -uy * hw;
        const ny = ux * hw;
        const ex = ux * hw * 0.5;
        const ey = uy * hw * 0.5;
        const a0: Pt = .{ .x = a.x - ex + nx, .y = a.y - ey + ny };
        const a1: Pt = .{ .x = a.x - ex - nx, .y = a.y - ey - ny };
        const b0: Pt = .{ .x = b.x + ex + nx, .y = b.y + ey + ny };
        const b1: Pt = .{ .x = b.x + ex - nx, .y = b.y + ey - ny };
        emit.triangle(a0, a1, b0);
        emit.triangle(a1, b1, b0);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mk(sha: []const u8, parents: []const []const u8) Commit {
    return .{ .sha = sha, .parentShas = parents };
}

test "linear history is one lane" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const commits = [_]Commit{ mk("b", &.{"a"}), mk("a", &.{}) };
    const l = try layoutGraph(arena.allocator(), &commits, "b");
    try testing.expectEqual(@as(usize, 1), l.max_lane_count);
    try testing.expect(l.rows[0].is_head);
    try testing.expectEqual(SegmentShape.outgoing, l.rows[0].segments[0].shape);
    try testing.expectEqual(SegmentShape.incoming, l.rows[1].segments[0].shape);
}

test "merge opens and closes a second lane" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // m merges f into a; f's parent is a.
    const commits = [_]Commit{ mk("m", &.{ "a", "f" }), mk("f", &.{"a"}), mk("a", &.{}) };
    const l = try layoutGraph(arena.allocator(), &commits, null);
    try testing.expectEqual(@as(usize, 2), l.max_lane_count);
    try testing.expectEqual(@as(usize, 1), l.rows[1].node_lane);
    try testing.expect(l.rows[1].node_color_id != l.rows[0].node_color_id);
    try testing.expectEqual(@as(usize, 0), l.rows[2].node_lane);
}

test "compaction contracts hidden commits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const commits = [_]Commit{ mk("d", &.{"c"}), mk("c", &.{"b"}), mk("b", &.{"a"}), mk("a", &.{}) };
    var vis: ShaSet = .empty;
    try vis.put(a, "d", {});
    try vis.put(a, "a", {});
    const out = try compactToVisible(a, &commits, &vis);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("a", out[0].parentShas[0]);
}

test "geometry, refs, dates, matching" {
    try testing.expectEqual(@as(f32, 13 + 12 + 6), Geometry.natural(1).width);
    try testing.expectEqual(@as(f32, 16), Geometry.natural(1).laneX(0));
    try testing.expect(!shouldUseCompact(Geometry.natural(1), .{}, 520, 250));
    const refs = [_]Ref{ .{ .kind = .branch, .label = "feat/stream-backpressure" }, .{ .kind = .branch, .label = "main" } };
    try testing.expectEqual(@as(usize, 0), visibleRefCount(&refs, 20));
    try testing.expectEqual(@as(usize, 2), visibleRefCount(&refs, 400));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("Oct 4, 2026", formatDate(arena.allocator(), "2026-10-04T07:11:12+00:00"));
    try testing.expectEqualStrings("\u{2014}", formatDate(arena.allocator(), "bad"));
    try testing.expectEqualStrings("A", authorInitial(arena.allocator(), " ada"));
    try testing.expect(matches("f561", .{ .sha = "f5618ff", .subject = "Bump" }));
    try testing.expect(matches("bmp rtry", .{ .sha = "x", .subject = "Bump retry default" }));
    try testing.expect(!matches("zzz", .{ .sha = "x", .subject = "Bump" }));
}

test "graph geometry morph converges lanes before entering the compact rail" {
    const full = Geometry.natural(8);
    const compact = Geometry.compactRail(8);
    const halfway = interpolate(full, compact, 0.5);
    try testing.expect(!halfway.compact);
    try testing.expect(halfway.width < full.width and halfway.width > compact.width);
    try testing.expect(halfway.lane_spacing < full.lane_spacing and halfway.lane_spacing > compact.lane_spacing);
    const settled = interpolate(full, compact, 1);
    try testing.expect(settled.compact);
    try testing.expectEqual(compact.width, settled.width);
    try testing.expectEqual(@as(f32, 0), settled.lane_spacing);
}

test "graph geometry morph expands the rail from its compact start" {
    const compact = Geometry.compactRail(8);
    const full = Geometry.natural(8);
    try testing.expect(interpolate(compact, full, 0).compact);
    const halfway = interpolate(compact, full, 0.5);
    try testing.expect(!halfway.compact);
    try testing.expect(halfway.lane_spacing > 0 and halfway.lane_spacing < full.lane_spacing);
}
