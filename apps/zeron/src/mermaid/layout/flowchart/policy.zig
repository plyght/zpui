//! `layout/flowchart/policy.rs`: spacing heuristics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../../ir.zig");
const util = @import("../../util.zig");
const Theme = @import("../../theme.zig").Theme;
const LayoutConfig = @import("../../config.zig").LayoutConfig;
const t = @import("../types.zig");
const ranking = @import("../ranking.zig");
const Graph = ir.Graph;

pub fn applyInitialConfigHeuristics(graph: *const Graph, config: *const LayoutConfig) LayoutConfig {
    var e = config.*;
    if (graph.kind == .requirement) e.max_label_width_chars = @max(e.max_label_width_chars, 32);
    if (graph.kind == .er) {
        e.node_spacing *= 0.80;
        e.rank_spacing *= 0.80;
        e.flowchart.order_passes = @max(e.flowchart.order_passes, 10);
    }
    if (graph.kind == .flowchart) {
        const p = densityProfile(graph);
        const auto = config.flowchart.auto_spacing;
        if (auto.enabled and auto.buckets.len > 0) {
            var scale = auto.buckets[0].scale;
            for (auto.buckets) |b| if (p.node_count >= b.min_nodes) {
                scale = b.scale;
            };
            if (p.density > auto.density_threshold) scale = @max(scale, auto.dense_scale_floor);
            e.node_spacing = @max(e.node_spacing * scale, auto.min_spacing);
            e.rank_spacing = @max(e.rank_spacing * scale, auto.min_spacing);
        }
        if (p.node_count >= 12 and p.hub_ratio >= 0.40 and p.density <= 2.5) {
            e.flowchart.routing.enable_grid_router = false;
            e.flowchart.routing.snap_ports_to_grid = false;
        }
        if (isTinyNoCycleCheck(graph) and !hasCycleNoAlloc(graph)) {
            e.flowchart.order_passes = 1;
            e.flowchart.routing.enable_grid_router = false;
            e.flowchart.routing.snap_ports_to_grid = false;
        }
    }
    return e;
}

pub fn applyMeasuredSpacingHeuristics(a: Allocator, graph: *const Graph, theme: *const Theme, config: *LayoutConfig, nodes: *const t.NodeMap) Allocator.Error!void {
    _ = a;
    const auto = config.flowchart.auto_spacing;
    if (auto.enabled) {
        const ns = adaptiveSpacing(nodes, auto.min_spacing, config.node_spacing);
        const rs = adaptiveSpacing(nodes, auto.min_spacing, config.rank_spacing);
        if (ns < config.node_spacing) config.node_spacing = ns;
        if (rs < config.rank_spacing) config.rank_spacing = rs;
    }
    if (graph.kind != .flowchart) return;
    const p = densityProfile(graph);
    if (auto.enabled and graph.nodes.len() >= 10 and p.hub_ratio >= 0.30 and p.density <= 3.0) {
        const hub_scale = std.math.clamp(0.92 - (p.hub_ratio - 0.30) * 0.55, 0.62, 0.92);
        const floor = @max(auto.min_spacing * 0.5, 14.0);
        config.node_spacing = @max(config.node_spacing * hub_scale, floor);
        config.rank_spacing = @max(config.rank_spacing * hub_scale, floor);
    }
    if (labelSpacingFloor(graph, theme, config, p.edge_count)) |f| {
        config.node_spacing = @max(config.node_spacing, f);
        config.rank_spacing = @max(config.rank_spacing, f);
    }
}

fn isTinyNoCycleCheck(graph: *const Graph) bool {
    return graph.subgraphs.items.len == 0 and graph.nodes.len() <= 4 and graph.edges.items.len <= 4;
}

/// Cycle check for tiny graphs (≤ 4 edges): repeated relaxation is exact.
fn hasCycleNoAlloc(graph: *const Graph) bool {
    const edges = graph.edges.items;
    // A directed cycle exists iff some edge's target reaches its source.
    for (edges) |start| {
        var frontier: [8][]const u8 = undefined;
        var n: usize = 1;
        frontier[0] = start.to;
        var steps: usize = 0;
        while (steps < 8) : (steps += 1) {
            var changed = false;
            for (edges) |e| {
                var reach = false;
                for (frontier[0..n]) |f| reach = reach or util.eql(f, e.from);
                if (!reach) continue;
                var dup = false;
                for (frontier[0..n]) |f| dup = dup or util.eql(f, e.to);
                if (!dup and n < frontier.len) {
                    frontier[n] = e.to;
                    n += 1;
                    changed = true;
                }
            }
            if (!changed) break;
        }
        for (frontier[0..n]) |f| if (util.eql(f, start.from)) return true;
    }
    return false;
}

pub fn isTinyGraphLayout(a: Allocator, graph: *const Graph) Allocator.Error!bool {
    _ = a;
    return isTinyNoCycleCheck(graph) and !hasCycleNoAlloc(graph);
}

fn adaptiveSpacing(nodes: *const t.NodeMap, min_spacing: f32, max_spacing: f32) f32 {
    var total: f32 = 0;
    var count: usize = 0;
    for (nodes.values()) |n| {
        if (n.hidden or n.anchor_subgraph != null) continue;
        total += (n.width + n.height) * 0.5;
        count += 1;
    }
    if (count == 0) return max_spacing;
    return @min(@max(total / @as(f32, @floatFromInt(count)) * 0.5, min_spacing), max_spacing);
}

const Profile = struct { node_count: usize, edge_count: f32, density: f32, hub_ratio: f32 };

fn densityProfile(graph: *const Graph) Profile {
    const nc = graph.nodes.len();
    const ec: f32 = @floatFromInt(graph.edges.items.len);
    const density = if (nc > 0) ec / @as(f32, @floatFromInt(nc)) else 0.0;
    var max_degree: usize = 0;
    for (graph.nodes.keys.items) |id| {
        var d: usize = 0;
        for (graph.edges.items) |e| {
            if (util.eql(e.from, id)) d += 1;
            if (util.eql(e.to, id)) d += 1;
        }
        max_degree = @max(max_degree, d);
    }
    // Edge endpoints missing from the node map still count in Rust's degree map.
    for (graph.edges.items) |e| for ([_][]const u8{ e.from, e.to }) |id| {
        if (graph.nodes.contains(id)) continue;
        var d: usize = 0;
        for (graph.edges.items) |o| {
            if (util.eql(o.from, id)) d += 1;
            if (util.eql(o.to, id)) d += 1;
        }
        max_degree = @max(max_degree, d);
    };
    const hub = if (nc > 0) @as(f32, @floatFromInt(max_degree)) / @as(f32, @floatFromInt(nc)) else 0.0;
    return .{ .node_count = nc, .edge_count = ec, .density = density, .hub_ratio = hub };
}

fn labelSpacingFloor(graph: *const Graph, theme: *const Theme, config: *const LayoutConfig, edge_count: f32) ?f32 {
    if (edge_count <= 0.0) return null;
    var total: usize = 0;
    var count: usize = 0;
    var endpoint_edges: usize = 0;
    for (graph.edges.items) |e| {
        var has_end = false;
        if (e.label) |l| {
            total += util.charCount(l);
            count += 1;
        }
        if (e.start_label) |l| {
            total += util.charCount(l);
            count += 1;
            has_end = true;
        }
        if (e.end_label) |l| {
            total += util.charCount(l);
            count += 1;
            has_end = true;
        }
        if (has_end) endpoint_edges += 1;
    }
    if (count == 0) return null;
    const avg = @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(count));
    const text_p = std.math.clamp((avg - 10.0) / 26.0, 0.0, 1.0);
    const end_p = std.math.clamp(@as(f32, @floatFromInt(endpoint_edges)) / @max(edge_count, 1.0), 0.0, 1.0);
    const pressure = std.math.clamp(text_p * 0.7 + end_p * 0.3, 0.0, 1.0);
    if (pressure <= 0.0) return null;
    return config.flowchart.auto_spacing.min_spacing + pressure * @max(theme.font_size * 1.1, 8.0);
}
