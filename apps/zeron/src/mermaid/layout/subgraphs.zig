//! `layout/subgraphs.rs`: subgraph anchoring, banding, direction overrides
//! and box construction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir.zig");
const util = @import("../util.zig");
const Theme = @import("../theme.zig").Theme;
const LayoutConfig = @import("../config.zig").LayoutConfig;
const text = @import("../text.zig");
const t = @import("types.zig");
const L = @import("layout.zig");
const ranking = @import("ranking.zig");
const geometry = @import("geometry.zig");
const EdgeSide = geometry.EdgeSide;
const Graph = ir.Graph;
const NodeLayout = t.NodeLayout;
const NodeMap = t.NodeMap;
const SubgraphLayout = t.SubgraphLayout;
const TextBlock = t.TextBlock;
const Direction = ir.Direction;
const StrSet = ranking.StrSet;
const isHorizontal = L.isHorizontal;

const FMAX = std.math.floatMax(f32);
const FMIN = -std.math.floatMax(f32);

pub fn isRegionSubgraph(sub: *const ir.Subgraph) bool {
    if (util.trim(sub.label).len != 0) return false;
    const id = sub.id orelse return false;
    return util.startsWith(id, "__region_");
}

const GroupBox = struct { idx: usize, min_x: f32, min_y: f32, max_x: f32, max_y: f32 };

pub fn applySubgraphBands(a: Allocator, graph: *const Graph, nodes: *NodeMap, config: *const LayoutConfig) Allocator.Error!void {
    var group_nodes: std.ArrayList(std.ArrayList([]const u8)) = .empty;
    var node_group: std.StringArrayHashMapUnmanaged(usize) = .empty;
    try group_nodes.append(a, .empty);
    const top_level = (try SubgraphTree.build(a, graph)).top_level;
    for (top_level, 0..) |idx, pos| {
        const gi = pos + 1;
        const sub = &graph.subgraphs.items[idx];
        try group_nodes.append(a, .empty);
        for (sub.nodes.items) |id| if (nodes.contains(id)) try node_group.put(a, id, gi);
        if (subgraphAnchorId(sub, nodes)) |anchor| if (nodes.contains(anchor)) try node_group.put(a, anchor, gi);
    }
    for (graph.nodes.keys.items) |id| if (!node_group.contains(id)) try node_group.put(a, id, 0);
    var it = node_group.iterator();
    while (it.next()) |e| if (e.value_ptr.* < group_nodes.items.len) try group_nodes.items[e.value_ptr.*].append(a, e.key_ptr.*);

    var groups: std.ArrayList(GroupBox) = .empty;
    for (group_nodes.items, 0..) |bucket, idx| {
        if (bucket.items.len == 0) continue;
        var b: GroupBox = .{ .idx = idx, .min_x = FMAX, .min_y = FMAX, .max_x = FMIN, .max_y = FMIN };
        for (bucket.items) |id| if (nodes.get(id)) |n| {
            b.min_x = @min(b.min_x, n.x);
            b.min_y = @min(b.min_y, n.y);
            b.max_x = @max(b.max_x, n.x + n.width);
            b.max_y = @max(b.max_y, n.y + n.height);
        };
        if (b.min_x != FMAX) try groups.append(a, b);
    }

    var inter: usize = 0;
    var links: std.AutoHashMapUnmanaged([2]usize, void) = .empty;
    var degree: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    for (graph.edges.items) |e| {
        const fg = node_group.get(e.from) orelse continue;
        const tg = node_group.get(e.to) orelse continue;
        if (fg == tg) continue;
        inter += 1;
        try links.put(a, if (fg < tg) .{ fg, tg } else .{ tg, fg }, {});
        for ([_]usize{ fg, tg }) |g| {
            const gop = try degree.getOrPut(a, g);
            gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
        }
    }
    var max_degree: usize = 0;
    var dit = degree.valueIterator();
    while (dit.next()) |v| max_degree = @max(max_degree, v.*);
    const path_like = inter > 0 and links.count() <= groups.items.len -| 1 and max_degree <= 2;
    const grid_pack = inter == 0;
    const align_cross = path_like;
    const horizontal = isHorizontal(graph.direction);
    const SortCtx = struct {
        horizontal: bool,
        fn lt(c: @This(), x: GroupBox, y: GroupBox) bool {
            const xp: u8 = if (x.idx == 0) 0 else 1;
            const yp: u8 = if (y.idx == 0) 0 else 1;
            if (xp != yp) return xp < yp;
            return if (c.horizontal) x.min_x < y.min_x else x.min_y < y.min_y;
        }
    };
    std.mem.sort(GroupBox, groups.items, SortCtx{ .horizontal = horizontal }, SortCtx.lt);

    const spacing = config.rank_spacing * 0.8;
    const shift = struct {
        fn f(ns: *NodeMap, ids: []const []const u8, dx: f32, dy: f32) void {
            for (ids) |id| if (ns.get(id)) |n| {
                n.x += dx;
                n.y += dy;
            };
        }
    }.f;
    if (horizontal) {
        if (align_cross and groups.items.len > 0) {
            var target_y: f32 = FMAX;
            for (groups.items) |g| target_y = @min(target_y, g.min_y);
            for (groups.items) |g| shift(nodes, group_nodes.items[g.idx].items, 0, target_y - g.min_y);
        } else if (grid_pack and groups.items.len > 1) {
            var origin_x: f32 = FMAX;
            var origin_y: f32 = FMAX;
            for (groups.items) |g| {
                origin_x = @min(origin_x, g.min_x);
                origin_y = @min(origin_y, g.min_y);
            }
            const n = groups.items.len;
            var best_area: f32 = FMAX;
            var best_cols: usize = 0;
            for (1..n + 1) |cols| {
                var max_row_width: f32 = 0;
                var total_height: f32 = 0;
                var rows: usize = 0;
                var idx: usize = 0;
                while (idx < n) {
                    const end = @min(idx + cols, n);
                    var rw: f32 = 0;
                    var rh: f32 = 0;
                    for (groups.items[idx..end], 0..) |g, pos| {
                        rw += g.max_x - g.min_x;
                        if (idx + pos + 1 < end) rw += spacing;
                        rh = @max(rh, g.max_y - g.min_y);
                    }
                    max_row_width = @max(max_row_width, rw);
                    total_height += rh;
                    rows += 1;
                    idx = end;
                }
                if (rows > 0) total_height += spacing * @as(f32, @floatFromInt(rows -| 1));
                const area = max_row_width * total_height;
                if (area < best_area) {
                    best_area = area;
                    best_cols = cols;
                }
            }
            var cursor_y = origin_y;
            var idx: usize = 0;
            while (best_cols > 0 and idx < n) {
                const end = @min(idx + best_cols, n);
                var rh: f32 = 0;
                var cursor_x = origin_x;
                for (groups.items[idx..end]) |g| {
                    shift(nodes, group_nodes.items[g.idx].items, cursor_x - g.min_x, cursor_y - g.min_y);
                    cursor_x += (g.max_x - g.min_x) + spacing;
                    rh = @max(rh, g.max_y - g.min_y);
                }
                cursor_y += rh + spacing;
                idx = end;
            }
        } else {
            var cursor: f32 = 0;
            for (groups.items) |g| if (g.idx == 0) {
                cursor = g.max_x;
                break;
            };
            cursor += spacing;
            for (groups.items) |g| {
                if (g.idx == 0) continue;
                shift(nodes, group_nodes.items[g.idx].items, cursor - g.min_x, 0);
                cursor += (g.max_x - g.min_x) + spacing;
            }
        }
    } else if (align_cross and groups.items.len > 0) {
        var target_x: f32 = FMAX;
        for (groups.items) |g| target_x = @min(target_x, g.min_x);
        for (groups.items) |g| shift(nodes, group_nodes.items[g.idx].items, target_x - g.min_x, 0);
    } else if (grid_pack and groups.items.len > 1) {
        var origin_x: f32 = FMAX;
        var origin_y: f32 = FMAX;
        for (groups.items) |g| {
            origin_x = @min(origin_x, g.min_x);
            origin_y = @min(origin_y, g.min_y);
        }
        const n = groups.items.len;
        var best_area: f32 = FMAX;
        var best_rows: usize = 0;
        for (1..n + 1) |rows| {
            const cols = (n + rows - 1) / rows;
            var max_col_height: f32 = 0;
            var total_width: f32 = 0;
            var idx: usize = 0;
            for (0..rows) |_| {
                const end = @min(idx + cols, n);
                var ch: f32 = 0;
                var cw: f32 = 0;
                for (groups.items[idx..end], 0..) |g, pos| {
                    ch += g.max_y - g.min_y;
                    if (idx + pos + 1 < end) ch += spacing;
                    cw = @max(cw, g.max_x - g.min_x);
                }
                max_col_height = @max(max_col_height, ch);
                total_width += cw;
                idx = end;
            }
            total_width += spacing * @as(f32, @floatFromInt(rows -| 1));
            const area = total_width * max_col_height;
            if (area < best_area) {
                best_area = area;
                best_rows = rows;
            }
        }
        if (best_rows > 0) {
            const cols = (n + best_rows - 1) / best_rows;
            var cursor_x = origin_x;
            var idx: usize = 0;
            for (0..best_rows) |_| {
                const end = @min(idx + cols, n);
                var cw: f32 = 0;
                var cursor_y = origin_y;
                for (groups.items[idx..end]) |g| {
                    shift(nodes, group_nodes.items[g.idx].items, cursor_x - g.min_x, cursor_y - g.min_y);
                    cursor_y += (g.max_y - g.min_y) + spacing;
                    cw = @max(cw, g.max_x - g.min_x);
                }
                cursor_x += cw + spacing;
                idx = end;
            }
        }
    } else {
        var cursor: f32 = 0;
        for (groups.items) |g| if (g.idx == 0) {
            cursor = g.max_y;
            break;
        };
        cursor += spacing;
        for (groups.items) |g| {
            if (g.idx == 0) continue;
            shift(nodes, group_nodes.items[g.idx].items, 0, cursor - g.min_y);
            cursor += (g.max_y - g.min_y) + spacing;
        }
    }
}

fn isSubset(small: []const []const u8, big: *const StrSet) bool {
    for (small) |id| if (!big.contains(id)) return false;
    return true;
}

fn subgraphSets(a: Allocator, graph: *const Graph) Allocator.Error![]StrSet {
    const sets = try a.alloc(StrSet, graph.subgraphs.items.len);
    for (graph.subgraphs.items, 0..) |sub, i| {
        sets[i] = .empty;
        for (sub.nodes.items) |id| try sets[i].put(a, id, {});
    }
    return sets;
}

fn setKeys(a: Allocator, s: *const StrSet) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = s.keyIterator();
    while (it.next()) |k| try out.append(a, k.*);
    return out.items;
}

pub fn applyOrthogonalRegionBands(a: Allocator, graph: *const Graph, nodes: *NodeMap, config: *const LayoutConfig) Allocator.Error!void {
    var regions: std.ArrayList(usize) = .empty;
    for (graph.subgraphs.items, 0..) |*sub, idx| if (isRegionSubgraph(sub)) try regions.append(a, idx);
    if (regions.items.len == 0) return;
    const sets = try subgraphSets(a, graph);
    var parent_map: std.AutoArrayHashMapUnmanaged(usize, std.ArrayList(usize)) = .empty;
    for (regions.items) |ri| {
        const rset = &sets[ri];
        const rkeys = try setKeys(a, rset);
        var parent: ?usize = null;
        for (sets, 0..) |*set, idx| {
            if (idx == ri or set.count() <= rset.count() or !isSubset(rkeys, set)) continue;
            if (isRegionSubgraph(&graph.subgraphs.items[idx])) continue;
            if (parent) |cur| {
                if (set.count() < sets[cur].count()) parent = idx;
            } else parent = idx;
        }
        if (parent) |pi| {
            const gop = try parent_map.getOrPut(a, pi);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, ri);
        }
    }
    const spacing = config.rank_spacing * 0.6;
    const along_x = isHorizontal(graph.direction);
    for (parent_map.values()) |list| {
        var boxes: std.ArrayList(GroupBox) = .empty;
        for (list.items) |ri| {
            var b: GroupBox = .{ .idx = ri, .min_x = FMAX, .min_y = FMAX, .max_x = FMIN, .max_y = FMIN };
            for (graph.subgraphs.items[ri].nodes.items) |id| if (nodes.get(id)) |n| {
                b.min_x = @min(b.min_x, n.x);
                b.min_y = @min(b.min_y, n.y);
                b.max_x = @max(b.max_x, n.x + n.width);
                b.max_y = @max(b.max_y, n.y + n.height);
            };
            if (b.min_x != FMAX) try boxes.append(a, b);
        }
        if (boxes.items.len <= 1) continue;
        if (along_x) {
            std.mem.sort(GroupBox, boxes.items, {}, struct {
                fn lt(_: void, x: GroupBox, y: GroupBox) bool {
                    return x.min_x < y.min_x;
                }
            }.lt);
            var cursor = boxes.items[0].min_x;
            for (boxes.items) |b| {
                const off = cursor - b.min_x;
                for (graph.subgraphs.items[b.idx].nodes.items) |id| if (nodes.get(id)) |n| {
                    n.x += off;
                };
                cursor += (b.max_x - b.min_x) + spacing;
            }
        } else {
            std.mem.sort(GroupBox, boxes.items, {}, struct {
                fn lt(_: void, x: GroupBox, y: GroupBox) bool {
                    return x.min_y < y.min_y;
                }
            }.lt);
            var cursor = boxes.items[0].min_y;
            for (boxes.items) |b| {
                const off = cursor - b.min_y;
                for (graph.subgraphs.items[b.idx].nodes.items) |id| if (nodes.get(id)) |n| {
                    n.y += off;
                };
                cursor += (b.max_y - b.min_y) + spacing;
            }
        }
    }
}

pub const SubgraphTree = struct {
    parent: []?usize,
    children: []std.ArrayList(usize),
    top_level: []usize,

    pub fn build(a: Allocator, graph: *const Graph) Allocator.Error!SubgraphTree {
        const n = graph.subgraphs.items.len;
        const sets = try subgraphSets(a, graph);
        const by_size = try a.alloc(usize, n);
        for (by_size, 0..) |*v, i| v.* = i;
        std.mem.sort(usize, by_size, sets, struct {
            fn lt(s: []StrSet, x: usize, y: usize) bool {
                return s[x].count() < s[y].count();
            }
        }.lt);
        const parent = try a.alloc(?usize, n);
        @memset(parent, null);
        const children = try a.alloc(std.ArrayList(usize), n);
        for (children) |*c| c.* = .empty;
        for (by_size, 0..) |i, pos| {
            const ikeys = try setKeys(a, &sets[i]);
            for (by_size[pos + 1 ..]) |j| {
                if (sets[j].count() > sets[i].count() and isSubset(ikeys, &sets[j])) {
                    parent[i] = j;
                    try children[j].append(a, i);
                    break;
                }
            }
        }
        var top: std.ArrayList(usize) = .empty;
        for (0..n) |i| if (parent[i] == null) try top.append(a, i);
        return .{ .parent = parent, .children = children, .top_level = top.items };
    }

    fn isAncestor(self: *const SubgraphTree, ancestor: usize, descendant: usize) bool {
        var cur = descendant;
        while (self.parent[cur]) |p| {
            if (p == ancestor) return true;
            cur = p;
        }
        return false;
    }

    pub fn areSiblings(self: *const SubgraphTree, x: usize, y: usize) bool {
        return x != y and !self.isAncestor(x, y) and !self.isAncestor(y, x);
    }
};

pub fn topLevelSubgraphIndices(a: Allocator, graph: *const Graph) Allocator.Error![]usize {
    return (try SubgraphTree.build(a, graph)).top_level;
}

pub const IndexSet = std.AutoHashMapUnmanaged(usize, void);
pub const AnchorInfoMap = std.StringArrayHashMapUnmanaged(SubgraphAnchorInfo);

pub fn applySubgraphNodeLayoutPasses(a: Allocator, graph: *const Graph, nodes: *NodeMap, config: *const LayoutConfig, anchored: *const IndexSet, anchor_info: *const AnchorInfoMap) Allocator.Error!void {
    if (graph.subgraphs.items.len == 0) return;
    if (graph.kind != .state) try applySubgraphDirectionOverrides(a, graph, nodes, config, anchored);
    if (anchor_info.count() > 0) _ = try alignSubgraphsToAnchorNodes(a, graph, anchor_info, nodes, config);
    if (graph.kind == .state and anchor_info.count() > 0) try applyStateSubgraphLayouts(a, graph, nodes, config, anchored);
    try applyOrthogonalRegionBands(a, graph, nodes, config);
    if (graph.kind != .state and graph.kind != .flowchart) try applySubgraphBands(a, graph, nodes, config);
}

fn tempLayout(a: Allocator, graph: *const Graph, sub: *const ir.Subgraph, nodes: *const NodeMap, direction: Direction, local: *const LayoutConfig) Allocator.Error!NodeMap {
    var temp: NodeMap = .{};
    for (sub.nodes.items) |id| if (nodes.get(id)) |n| {
        var c = n.*;
        c.x = 0;
        c.y = 0;
        try temp.put(a, id, c);
    };
    const ranks = try ranking.computeRanksSubset(a, sub.nodes.items, graph.edges.items, &graph.node_order);
    try L.assignPositions(a, sub.nodes.items, &ranks, direction, local, &temp, 0, 0);
    return temp;
}

pub fn applySubgraphDirectionOverrides(a: Allocator, graph: *const Graph, nodes: *NodeMap, config: *const LayoutConfig, skip: *const IndexSet) Allocator.Error!void {
    for (graph.subgraphs.items, 0..) |*sub, idx| {
        if (skip.contains(idx)) continue;
        if (isRegionSubgraph(sub)) continue;
        const direction = sub.direction orelse blk: {
            if (graph.kind != .flowchart) continue;
            break :blk subgraphLayoutDirection(graph, sub);
        };
        if (sub.nodes.items.len == 0 or direction == graph.direction) continue;
        var min_x: f32 = FMAX;
        var min_y: f32 = FMAX;
        for (sub.nodes.items) |id| if (nodes.get(id)) |n| {
            min_x = @min(min_x, n.x);
            min_y = @min(min_y, n.y);
        };
        if (min_x == FMAX) continue;
        const local = subgraphLayoutConfig(graph, false, config);
        var temp = try tempLayout(a, graph, sub, nodes, direction, &local);
        var tmin_x: f32 = FMAX;
        var tmin_y: f32 = FMAX;
        for (sub.nodes.items) |id| if (temp.get(id)) |n| {
            tmin_x = @min(tmin_x, n.x);
            tmin_y = @min(tmin_y, n.y);
        };
        if (tmin_x == FMAX) continue;
        for (sub.nodes.items) |id| {
            const target = nodes.get(id) orelse continue;
            const source = temp.get(id) orelse continue;
            target.x = source.x - tmin_x + min_x;
            target.y = source.y - tmin_y + min_y;
        }
        if (direction == .right_left or direction == .bottom_top) mirrorSubgraphNodes(sub.nodes.items, nodes, direction);
    }
}

fn subgraphIsAnchorable(sub: *const ir.Subgraph, graph: *const Graph, nodes: *const NodeMap) bool {
    if (sub.nodes.items.len == 0) return false;
    const anchor_id = subgraphAnchorId(sub, nodes);
    for (graph.edges.items) |e| {
        if (anchor_id) |anc| if (util.eql(e.from, anc) or util.eql(e.to, anc)) return false;
        const fi = sub.containsNode(e.from);
        const ti = sub.containsNode(e.to);
        if (fi != ti) return false;
    }
    return true;
}

fn subgraphShouldAnchor(sub: *const ir.Subgraph, graph: *const Graph, nodes: *const NodeMap) bool {
    if (sub.nodes.items.len == 0) return false;
    if (graph.kind == .flowchart or graph.kind == .state) return subgraphAnchorId(sub, nodes) != null;
    return subgraphIsAnchorable(sub, graph, nodes);
}

pub fn subgraphAnchorId(sub: *const ir.Subgraph, nodes: *const NodeMap) ?[]const u8 {
    if (sub.id) |id| if (nodes.contains(id) and !sub.containsNode(id)) return id;
    if (nodes.contains(sub.label) and !sub.containsNode(sub.label)) return sub.label;
    return null;
}

pub fn markSubgraphAnchorNodesHidden(a: Allocator, graph: *const Graph, nodes: *NodeMap) Allocator.Error!StrSet {
    var ids: StrSet = .empty;
    for (graph.subgraphs.items) |*sub| {
        const anchor = subgraphAnchorId(sub, nodes) orelse continue;
        try ids.put(a, anchor, {});
        if (nodes.get(anchor)) |n| n.hidden = true;
    }
    return ids;
}

pub fn pickSubgraphAnchorChild(a: Allocator, sub: *const ir.Subgraph, graph: *const Graph, anchor_ids: *const StrSet) Allocator.Error!?[]const u8 {
    var cands: std.ArrayList([]const u8) = .empty;
    for (sub.nodes.items) |id| if (!anchor_ids.contains(id)) try cands.append(a, id);
    if (cands.items.len == 0) try cands.appendSlice(a, sub.nodes.items);
    if (cands.items.len == 0) return null;
    var best = cands.items[0];
    for (cands.items[1..]) |c| if (graph.orderOf(c) < graph.orderOf(best)) {
        best = c;
    };
    return best;
}

pub const SubgraphAnchorInfo = struct { sub_idx: usize, padding_x: f32, top_padding: f32 };

fn subgraphLayoutDirection(graph: *const Graph, sub: *const ir.Subgraph) Direction {
    if (graph.kind == .state) return graph.direction;
    return sub.direction orelse graph.direction;
}

fn subgraphLayoutConfig(graph: *const Graph, anchorable: bool, config: *const LayoutConfig) LayoutConfig {
    var local = config.*;
    if (graph.kind == .flowchart and anchorable) local.rank_spacing = config.rank_spacing + L.STATE_RANK_SPACING_BOOST;
    return local;
}

fn flowchartSubgraphPadding(direction: Direction) [2]f32 {
    return if (isHorizontal(direction)) .{ L.FLOWCHART_PAD_MAIN, L.FLOWCHART_PAD_CROSS } else .{ L.FLOWCHART_PAD_CROSS, L.FLOWCHART_PAD_MAIN };
}

fn internalEdgeCount(graph: *const Graph, sub: *const ir.Subgraph) usize {
    var n: usize = 0;
    for (graph.edges.items) |e| {
        if (sub.containsNode(e.from) and sub.containsNode(e.to)) n += 1;
    }
    return n;
}

pub fn subgraphPaddingFromLabel(graph: *const Graph, sub: *const ir.Subgraph, theme: *const Theme, label_block: *const TextBlock) [3]f32 {
    if (isRegionSubgraph(sub)) return .{ 0, 0, 0 };
    const label_empty = util.trim(sub.label).len == 0;
    const label_height: f32 = if (label_empty) 0 else label_block.height;
    const internal = if (graph.kind == .flowchart) internalEdgeCount(graph, sub) else 0;
    const has_cycle = graph.kind == .flowchart and internal >= @max(sub.nodes.items.len, 1);
    var pad: [2]f32 = if (graph.kind == .flowchart)
        flowchartSubgraphPadding(graph.direction)
    else if (graph.kind == .kanban)
        .{ 8, 8 }
    else blk: {
        const base: f32 = if (graph.kind == .state) L.STATE_SUBGRAPH_BASE_PAD else L.GENERIC_SUBGRAPH_BASE_PAD;
        break :blk .{ base, base };
    };
    if (graph.kind == .flowchart and sub.nodes.items.len <= 3 and
        ((isHorizontal(graph.direction) and graph.edges.items.len <= 20) or (!isHorizontal(graph.direction) and graph.edges.items.len <= 13)))
    {
        var long_label = false;
        for (graph.edges.items) |e| if (e.label) |l| {
            if (util.charCount(l) > 24) long_label = true;
        };
        if (!long_label) {
            const reduction: f32 = if (has_cycle) 1.0 else if (label_empty) 0.7 else 0.9;
            pad[0] *= reduction;
            pad[1] *= reduction;
        }
    }
    if (graph.kind == .flowchart and has_cycle) pad[1] += @max(theme.font_size * 0.75, 10.0);
    const top: f32 = if (label_empty)
        pad[1]
    else if (graph.kind == .flowchart)
        @max(pad[1], label_height + L.SUBGRAPH_LABEL_GAP_FLOWCHART + @max(theme.font_size * 0.75, 10.0))
    else if (graph.kind == .kanban)
        @max(pad[1], label_height + 4.0)
    else if (graph.kind == .state)
        @max(label_height + theme.font_size * L.STATE_SUBGRAPH_TOP_LABEL_SCALE, theme.font_size * L.STATE_SUBGRAPH_TOP_MIN_SCALE)
    else
        pad[1] + label_height + L.SUBGRAPH_LABEL_GAP_GENERIC;
    return .{ pad[0], pad[1], top };
}

fn estimateSubgraphBoxSize(a: Allocator, graph: *const Graph, sub: *const ir.Subgraph, nodes: *const NodeMap, theme: *const Theme, config: *const LayoutConfig, anchorable: bool) Allocator.Error!?[4]f32 {
    if (sub.nodes.items.len == 0) return null;
    const direction = subgraphLayoutDirection(graph, sub);
    const local = subgraphLayoutConfig(graph, anchorable, config);
    var temp = try tempLayout(a, graph, sub, nodes, direction, &local);
    var min_x: f32 = FMAX;
    var min_y: f32 = FMAX;
    var max_x: f32 = FMIN;
    var max_y: f32 = FMIN;
    for (sub.nodes.items) |id| if (temp.get(id)) |n| {
        min_x = @min(min_x, n.x);
        min_y = @min(min_y, n.y);
        max_x = @max(max_x, n.x + n.width);
        max_y = @max(max_y, n.y + n.height);
    };
    if (min_x == FMAX) return null;
    var lb = try text.measureLabel(a, sub.label, theme, config);
    if (util.trim(sub.label).len == 0) {
        lb.width = 0;
        lb.height = 0;
    }
    const p = subgraphPaddingFromLabel(graph, sub, theme, &lb);
    return .{ (max_x - min_x) + p[0] * 2.0, (max_y - min_y) + p[1] + p[2], p[0], p[2] };
}

pub fn applySubgraphAnchorSizes(a: Allocator, graph: *const Graph, nodes: *NodeMap, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!AnchorInfoMap {
    var anchors: AnchorInfoMap = .empty;
    for (graph.subgraphs.items, 0..) |*sub, idx| {
        if (isRegionSubgraph(sub) or !subgraphShouldAnchor(sub, graph, nodes)) continue;
        const anchor = subgraphAnchorId(sub, nodes) orelse continue;
        const size = (try estimateSubgraphBoxSize(a, graph, sub, nodes, theme, config, true)) orelse continue;
        if (nodes.get(anchor)) |n| {
            n.width = size[0];
            n.height = size[1];
        }
        try anchors.put(a, anchor, .{ .sub_idx = idx, .padding_x = size[2], .top_padding = size[3] });
    }
    return anchors;
}

pub fn alignSubgraphsToAnchorNodes(a: Allocator, graph: *const Graph, anchor_info: *const AnchorInfoMap, nodes: *NodeMap, config: *const LayoutConfig) Allocator.Error!StrSet {
    var anchored: StrSet = .empty;
    if (anchor_info.count() == 0) return anchored;
    const tree = try SubgraphTree.build(a, graph);
    const n = graph.subgraphs.items.len;
    const depth = try a.alloc(usize, n);
    for (0..n) |idx| {
        var d: usize = 0;
        var cur = idx;
        while (tree.parent[cur]) |p| {
            d += 1;
            cur = p;
            if (d > n) break;
        }
        depth[idx] = d;
    }
    const Ent = struct { id: []const u8, info: SubgraphAnchorInfo, depth: usize };
    var ordered: std.ArrayList(Ent) = .empty;
    for (anchor_info.keys(), anchor_info.values()) |k, v| try ordered.append(a, .{ .id = k, .info = v, .depth = if (v.sub_idx < n) depth[v.sub_idx] else std.math.maxInt(usize) });
    std.mem.sort(Ent, ordered.items, {}, struct {
        fn lt(_: void, x: Ent, y: Ent) bool {
            if (x.depth != y.depth) return x.depth < y.depth;
            if (x.info.sub_idx != y.info.sub_idx) return x.info.sub_idx < y.info.sub_idx;
            return std.mem.order(u8, x.id, y.id) == .lt;
        }
    }.lt);
    for (ordered.items) |e| {
        const anc = nodes.get(e.id) orelse continue;
        const ax = anc.x;
        const ay = anc.y;
        if (e.info.sub_idx >= n) continue;
        const sub = &graph.subgraphs.items[e.info.sub_idx];
        const direction = subgraphLayoutDirection(graph, sub);
        const local = subgraphLayoutConfig(graph, true, config);
        const ranks = try ranking.computeRanksSubset(a, sub.nodes.items, graph.edges.items, &graph.node_order);
        try L.assignPositions(a, sub.nodes.items, &ranks, direction, &local, nodes, ax + e.info.padding_x, ay + e.info.top_padding);
        if (direction == .right_left or direction == .bottom_top) mirrorSubgraphNodes(sub.nodes.items, nodes, direction);
        for (sub.nodes.items) |id| try anchored.put(a, id, {});
    }
    return anchored;
}

pub fn applyStateSubgraphLayouts(a: Allocator, graph: *const Graph, nodes: *NodeMap, config: *const LayoutConfig, skip: *const IndexSet) Allocator.Error!void {
    const subs = graph.subgraphs.items;
    const n = subs.len;
    const depth = try a.alloc(usize, n);
    const parent_of = try a.alloc(?usize, n);
    @memset(parent_of, null);
    for (subs, 0..) |*sa, i| for (subs, 0..) |*sb, j| {
        if (i == j) continue;
        const b_id = sb.id orelse "";
        if ((sa.containsNode(b_id) or sa.containsNode(sb.label)) and parent_of[j] == null) parent_of[j] = i;
    };
    for (0..n) |i| {
        var d: usize = 0;
        var cur = i;
        while (parent_of[cur]) |p| {
            d += 1;
            cur = p;
            if (d > n) break;
        }
        depth[i] = d;
    }
    const order = try a.alloc(usize, n);
    for (order, 0..) |*v, i| v.* = i;
    std.mem.sort(usize, order, depth, struct {
        fn lt(d: []usize, x: usize, y: usize) bool {
            return d[y] < d[x];
        }
    }.lt);
    var inner_boxes: std.AutoHashMapUnmanaged(usize, [4]f32) = .empty;
    for (order) |idx| {
        const sub = &subs[idx];
        if (skip.contains(idx) or sub.nodes.items.len <= 1) continue;
        var min_x: f32 = FMAX;
        var min_y: f32 = FMAX;
        for (sub.nodes.items) |id| if (nodes.get(id)) |nd| {
            min_x = @min(min_x, nd.x);
            min_y = @min(min_y, nd.y);
        };
        if (min_x == FMAX) continue;
        const Saved = struct { id: []const u8, w: f32, h: f32 };
        var saved: std.ArrayList(Saved) = .empty;
        var inner_anchor_ids: std.ArrayList([]const u8) = .empty;
        for (sub.nodes.items) |id| {
            for (subs, 0..) |*inner, j| {
                const box = inner_boxes.get(j) orelse continue;
                const inner_id = inner.id orelse "";
                if (util.eql(id, inner_id) or util.eql(id, inner.label)) {
                    var dup = false;
                    for (inner_anchor_ids.items) |x| dup = dup or util.eql(x, id);
                    if (!dup) try inner_anchor_ids.append(a, id);
                    if (nodes.get(id)) |nd| {
                        try saved.append(a, .{ .id = id, .w = nd.width, .h = nd.height });
                        nd.width = box[2];
                        nd.height = box[3];
                    }
                }
            }
        }
        const ranks = try ranking.computeRanksSubset(a, sub.nodes.items, graph.edges.items, &graph.node_order);
        try L.assignPositions(a, sub.nodes.items, &ranks, graph.direction, config, nodes, min_x, min_y);
        const nested_min_y = min_y + @max(config.node_spacing * 0.4, 20.0);
        for (inner_anchor_ids.items) |id| if (nodes.get(id)) |anc| {
            if (anc.y < nested_min_y) anc.y = nested_min_y;
        };
        for (saved.items) |s| if (nodes.get(s.id)) |nd| {
            nd.width = s.w;
            nd.height = s.h;
        };
        for (subs, 0..) |*inner, j| {
            const box = inner_boxes.get(j) orelse continue;
            const inner_id = inner.id orelse "";
            if (!sub.containsNode(inner_id) and !sub.containsNode(inner.label)) continue;
            const anchor_id = if (sub.containsNode(inner_id)) inner_id else inner.label;
            if (nodes.get(anchor_id)) |anc| {
                const dx = anc.x - box[0];
                const dy = anc.y - box[1];
                if (@abs(dx) > 0.01 or @abs(dy) > 0.01) {
                    for (inner.nodes.items) |iid| if (nodes.get(iid)) |nd| {
                        nd.x += dx;
                        nd.y += dy;
                    };
                }
            }
        }
        var bmin_x: f32 = FMAX;
        var bmin_y: f32 = FMAX;
        var bmax_x: f32 = FMIN;
        var bmax_y: f32 = FMIN;
        for (sub.nodes.items) |id| if (nodes.get(id)) |nd| {
            bmin_x = @min(bmin_x, nd.x);
            bmin_y = @min(bmin_y, nd.y);
            bmax_x = @max(bmax_x, nd.x + nd.width);
            bmax_y = @max(bmax_y, nd.y + nd.height);
        };
        for (subs, 0..) |*inner, j| {
            if (!inner_boxes.contains(j)) continue;
            const inner_id = inner.id orelse "";
            if (sub.containsNode(inner_id) or sub.containsNode(inner.label)) {
                for (inner.nodes.items) |iid| if (nodes.get(iid)) |nd| {
                    bmin_x = @min(bmin_x, nd.x);
                    bmin_y = @min(bmin_y, nd.y);
                    bmax_x = @max(bmax_x, nd.x + nd.width);
                    bmax_y = @max(bmax_y, nd.y + nd.height);
                };
            }
        }
        const padding = config.node_spacing;
        if (bmin_x < FMAX) try inner_boxes.put(a, idx, .{ bmin_x, bmin_y, bmax_x - bmin_x + padding, bmax_y - bmin_y + padding });
    }
}

pub fn applySubgraphAnchors(graph: *const Graph, subgraphs: []const SubgraphLayout, nodes: *NodeMap) void {
    if (subgraphs.len == 0) return;
    for (graph.subgraphs.items) |*sub| {
        // label_to_index keeps the last layout carrying this label.
        var layout_idx: ?usize = null;
        for (subgraphs, 0..) |s, i| if (util.eql(s.label, sub.label)) {
            layout_idx = i;
        };
        const li = layout_idx orelse continue;
        const lay = &subgraphs[li];
        var ids: [2][]const u8 = undefined;
        var count: usize = 0;
        if (sub.id) |id| {
            ids[0] = id;
            count = 1;
        }
        if (count == 0 or !util.eql(ids[0], sub.label)) {
            ids[count] = sub.label;
            count += 1;
        }
        for (ids[0..count]) |anchor_id| {
            if (sub.containsNode(anchor_id)) continue;
            const node = nodes.get(anchor_id) orelse continue;
            node.anchor_subgraph = li;
            const size: f32 = 2.0;
            node.width = size;
            node.height = size;
            node.x = lay.x + lay.width / 2.0 - size / 2.0;
            node.y = lay.y + lay.height / 2.0 - size / 2.0;
        }
    }
}

pub fn anchorLayoutForEdge(anchor: *const NodeLayout, subgraph: *const SubgraphLayout, direction: Direction, is_from: bool) NodeLayout {
    const size: f32 = 2.0;
    var node = anchor.*;
    node.width = size;
    node.height = size;
    if (isHorizontal(direction)) {
        node.x = if (is_from) subgraph.x + subgraph.width - size else subgraph.x;
        node.y = subgraph.y + subgraph.height / 2.0 - size / 2.0;
    } else {
        node.x = subgraph.x + subgraph.width / 2.0 - size / 2.0;
        node.y = if (is_from) subgraph.y + subgraph.height - size else subgraph.y;
    }
    return node;
}

pub fn anchorLayoutForEdgeTowards(anchor: *const NodeLayout, subgraph: *const SubgraphLayout, remote: *const NodeLayout, direction: Direction, is_from: bool) NodeLayout {
    const rc = t.Point{ remote.x + remote.width * 0.5, remote.y + remote.height * 0.5 };
    const inside_x = rc[0] >= subgraph.x and rc[0] <= subgraph.x + subgraph.width;
    const inside_y = rc[1] >= subgraph.y and rc[1] <= subgraph.y + subgraph.height;
    if (inside_x and inside_y) return anchorLayoutForEdge(anchor, subgraph, direction, is_from);
    const size: f32 = 2.0;
    const min_x = subgraph.x;
    const max_x = subgraph.x + subgraph.width;
    const min_y = subgraph.y;
    const max_y = subgraph.y + subgraph.height;
    const pad = std.math.clamp(@min(subgraph.width, subgraph.height) * 0.08, 0.0, 18.0);
    const cx = rustClamp(rc[0], min_x + pad, max_x - pad);
    const cy = rustClamp(rc[1], min_y + pad, max_y - pad);
    const preferred: EdgeSide = if (isHorizontal(direction)) (if (is_from) .right else .left) else (if (is_from) .bottom else .top);
    const cands = [_]struct { EdgeSide, t.Point }{
        .{ .left, .{ min_x, cy } },
        .{ .right, .{ max_x, cy } },
        .{ .top, .{ cx, min_y } },
        .{ .bottom, .{ cx, max_y } },
    };
    var best = cands[0];
    var best_score = std.math.inf(f32);
    for (cands) |c| {
        const manhattan = @abs(c[1][0] - rc[0]) + @abs(c[1][1] - rc[1]);
        const bias: f32 = if (c[0] == preferred) -0.01 else 0.0;
        if (manhattan + bias < best_score) {
            best = c;
            best_score = manhattan + bias;
        }
    }
    var node = anchor.*;
    node.width = size;
    node.height = size;
    switch (best[0]) {
        .left => {
            node.x = min_x;
            node.y = best[1][1] - size * 0.5;
        },
        .right => {
            node.x = max_x - size;
            node.y = best[1][1] - size * 0.5;
        },
        .top => {
            node.x = best[1][0] - size * 0.5;
            node.y = min_y;
        },
        .bottom => {
            node.x = best[1][0] - size * 0.5;
            node.y = max_y - size;
        },
    }
    return node;
}

/// Rust `f32::clamp` (asserts min <= max; callers here keep that true or the
/// crate would panic — fall back to `min` like a saturated clamp).
pub fn rustClamp(v: f32, lo: f32, hi: f32) f32 {
    if (lo > hi) return @max(@min(v, hi), lo);
    return std.math.clamp(v, lo, hi);
}

fn mirrorSubgraphNodes(ids: []const []const u8, nodes: *NodeMap, direction: Direction) void {
    var min_x: f32 = FMAX;
    var min_y: f32 = FMAX;
    var max_x: f32 = FMIN;
    var max_y: f32 = FMIN;
    for (ids) |id| if (nodes.get(id)) |n| {
        min_x = @min(min_x, n.x);
        min_y = @min(min_y, n.y);
        max_x = @max(max_x, n.x + n.width);
        max_y = @max(max_y, n.y + n.height);
    };
    if (min_x == FMAX) return;
    if (direction == .right_left) for (ids) |id| if (nodes.get(id)) |n| {
        n.x = min_x + (max_x - (n.x + n.width));
    };
    if (direction == .bottom_top) for (ids) |id| if (nodes.get(id)) |n| {
        n.y = min_y + (max_y - (n.y + n.height));
    };
}

pub fn resolveSubgraphStyle(sub: *const ir.Subgraph, graph: *const Graph) ir.NodeStyle {
    var style: ir.NodeStyle = .{};
    const id = sub.id orelse return style;
    if (graph.subgraph_classes.get(id)) |classes| for (classes.items) |cn| {
        if (graph.class_defs.get(cn)) |cs| L.mergeNodeStyle(&style, &cs);
    };
    if (graph.subgraph_styles.get(id)) |ss| L.mergeNodeStyle(&style, &ss);
    return style;
}

pub fn buildSubgraphLayouts(a: Allocator, graph: *const Graph, nodes: *const NodeMap, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!std.ArrayList(SubgraphLayout) {
    var subgraphs: std.ArrayList(SubgraphLayout) = .empty;
    const g2l = try a.alloc(?usize, graph.subgraphs.items.len);
    for (graph.subgraphs.items, 0..) |*sub, gi| {
        var min_x: f32 = FMAX;
        var min_y: f32 = FMAX;
        var max_x: f32 = FMIN;
        var max_y: f32 = FMIN;
        for (sub.nodes.items) |id| if (nodes.get(id)) |n| {
            min_x = @min(min_x, n.x);
            min_y = @min(min_y, n.y);
            max_x = @max(max_x, n.x + n.width);
            max_y = @max(max_y, n.y + n.height);
        };
        if (min_x == FMAX) {
            g2l[gi] = null;
            continue;
        }
        const style = resolveSubgraphStyle(sub, graph);
        var lb = try text.measureLabel(a, sub.label, theme, config);
        const label_empty = util.trim(sub.label).len == 0;
        if (label_empty) {
            lb.width = 0;
            lb.height = 0;
        }
        const p = subgraphPaddingFromLabel(graph, sub, theme, &lb);
        const base_width = (max_x - min_x) + p[0] * 2.0;
        const min_label_width = if (label_empty) base_width else lb.width + p[0] * 2.0;
        const width = @max(base_width, min_label_width);
        const extra = width - base_width;
        g2l[gi] = subgraphs.items.len;
        try subgraphs.append(a, .{
            .label = sub.label,
            .label_block = lb,
            .nodes = sub.nodes.items,
            .x = min_x - p[0] - extra / 2.0,
            .y = min_y - p[2],
            .width = width,
            .height = (max_y - min_y) + p[1] + p[2],
            .style = style,
            .icon = sub.icon,
        });
    }
    if (subgraphs.items.len > 1) {
        const tree = try SubgraphTree.build(a, graph);
        const n = graph.subgraphs.items.len;
        const desc = try a.alloc(std.ArrayList(usize), n);
        for (desc) |*d| d.* = .empty;
        var order: std.ArrayList(usize) = .empty;
        const Fr = struct { idx: usize, visited: bool };
        var stack: std.ArrayList(Fr) = .empty;
        var ti = tree.top_level.len;
        while (ti > 0) {
            ti -= 1;
            try stack.append(a, .{ .idx = tree.top_level[ti], .visited = false });
        }
        while (stack.pop()) |fr| {
            if (fr.visited) {
                try order.append(a, fr.idx);
                continue;
            }
            try stack.append(a, .{ .idx = fr.idx, .visited = true });
            var ci = tree.children[fr.idx].items.len;
            while (ci > 0) {
                ci -= 1;
                try stack.append(a, .{ .idx = tree.children[fr.idx].items[ci], .visited = false });
            }
        }
        for (order.items) |idx| {
            var ds: std.ArrayList(usize) = .empty;
            for (tree.children[idx].items) |c| {
                try ds.append(a, c);
                try ds.appendSlice(a, desc[c].items);
            }
            desc[idx] = ds;
        }
        for (order.items) |i| {
            const li = g2l[i] orelse continue;
            for (desc[i].items) |j| {
                if (isRegionSubgraph(&graph.subgraphs.items[j])) continue;
                const lj = g2l[j] orelse continue;
                const pad: f32 = if (graph.kind == .state) @max(theme.font_size * 1.8, 24.0) else 12.0;
                const child = subgraphs.items[lj];
                const parent = &subgraphs.items[li];
                const mnx = @min(parent.x, child.x - pad);
                const mny = @min(parent.y, child.y - pad);
                const mxx = @max(parent.x + parent.width, child.x + child.width + pad);
                const mxy = @max(parent.y + parent.height, child.y + child.height + pad);
                parent.x = mnx;
                parent.y = mny;
                parent.width = mxx - mnx;
                parent.height = mxy - mny;
            }
        }
    }
    std.mem.sort(SubgraphLayout, subgraphs.items, {}, struct {
        fn lt(_: void, x: SubgraphLayout, y: SubgraphLayout) bool {
            return y.width * y.height < x.width * x.height;
        }
    }.lt);
    return subgraphs;
}
