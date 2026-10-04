//! The diagram IR (mermaid-rs-renderer `ir.rs`), for the diagram kinds zeron
//! renders: flowchart/graph, class, state, ER, sequence, pie and gantt. All
//! slices live in the render arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Direction = enum {
    top_down,
    left_right,
    bottom_top,
    right_left,

    pub fn fromToken(token: []const u8) ?Direction {
        if (std.ascii.eqlIgnoreCase(token, "TD") or std.ascii.eqlIgnoreCase(token, "TB")) return .top_down;
        if (std.ascii.eqlIgnoreCase(token, "BT")) return .bottom_top;
        if (std.ascii.eqlIgnoreCase(token, "LR")) return .left_right;
        if (std.ascii.eqlIgnoreCase(token, "RL")) return .right_left;
        return null;
    }
};

pub const DiagramKind = enum {
    flowchart,
    class,
    state,
    sequence,
    er,
    pie,
    mindmap,
    journey,
    timeline,
    gantt,
    requirement,
    git_graph,
    c4,
    sankey,
    quadrant,
    zen_uml,
    block,
    packet,
    kanban,
    architecture,
    radar,
    treemap,
    xy_chart,
};

pub const SequenceFrameKind = enum { alt, opt, loop, par, rect, critical, @"break" };
pub const SequenceNotePosition = enum { left_of, right_of, over };
pub const StateNotePosition = enum { left_of, right_of };
pub const SequenceActivationKind = enum { activate, deactivate };

pub const SequenceActivation = struct {
    participant: []const u8,
    index: usize,
    kind: SequenceActivationKind,
};

pub const SequenceNote = struct {
    position: SequenceNotePosition,
    participants: []const []const u8,
    label: []const u8,
    index: usize,
};

pub const PieSlice = struct { label: []const u8, value: f32 };

pub const GanttStatus = enum { done, active, crit, milestone };

pub const GanttTask = struct {
    id: []const u8,
    label: []const u8,
    start: ?[]const u8 = null,
    duration: ?[]const u8 = null,
    after: ?[]const u8 = null,
    section: ?[]const u8 = null,
    status: ?GanttStatus = null,
};

pub const SequenceBox = struct {
    label: ?[]const u8,
    color: ?[]const u8,
    participants: std.ArrayList([]const u8) = .empty,
};

pub const StateNote = struct {
    position: StateNotePosition,
    target: []const u8,
    label: []const u8,
};

pub const SequenceFrameSection = struct {
    label: ?[]const u8,
    start_idx: usize,
    end_idx: usize,
};

pub const SequenceFrame = struct {
    kind: SequenceFrameKind,
    sections: []SequenceFrameSection,
    start_idx: usize,
    end_idx: usize,
};

pub const NodeShape = enum {
    rectangle,
    fork_join,
    round_rect,
    stadium,
    subroutine,
    cylinder,
    actor_box,
    circle,
    double_circle,
    diamond,
    hexagon,
    parallelogram,
    parallelogram_alt,
    trapezoid,
    trapezoid_alt,
    asymmetric,
    mindmap_default,
    text,
};

pub const Node = struct {
    id: []const u8,
    label: []const u8,
    shape: NodeShape = .rectangle,
    value: ?f32 = null,
    icon: ?[]const u8 = null,
};

pub const NodeLink = struct {
    url: []const u8,
    title: ?[]const u8 = null,
    target: ?[]const u8 = null,
};

pub const EdgeStyle = enum { solid, dotted, thick };

pub const EdgeDecoration = enum {
    circle,
    cross,
    diamond,
    diamond_filled,
    crows_foot_one,
    crows_foot_zero_one,
    crows_foot_many,
    crows_foot_zero_many,
};

pub const EdgeArrowhead = enum { open_triangle, class_dependency };

pub const Edge = struct {
    from: []const u8,
    to: []const u8,
    label: ?[]const u8 = null,
    start_label: ?[]const u8 = null,
    end_label: ?[]const u8 = null,
    directed: bool = false,
    arrow_start: bool = false,
    arrow_end: bool = false,
    arrow_start_kind: ?EdgeArrowhead = null,
    arrow_end_kind: ?EdgeArrowhead = null,
    start_decoration: ?EdgeDecoration = null,
    end_decoration: ?EdgeDecoration = null,
    style: EdgeStyle = .solid,
};

pub const Subgraph = struct {
    id: ?[]const u8,
    label: []const u8,
    nodes: std.ArrayList([]const u8) = .empty,
    direction: ?Direction = null,
    icon: ?[]const u8 = null,

    pub fn containsNode(self: *const Subgraph, id: []const u8) bool {
        for (self.nodes.items) |n| if (std.mem.eql(u8, n, id)) return true;
        return false;
    }
};

pub const NodeStyle = struct {
    fill: ?[]const u8 = null,
    stroke: ?[]const u8 = null,
    text_color: ?[]const u8 = null,
    stroke_width: ?f32 = null,
    stroke_dasharray: ?[]const u8 = null,
    line_color: ?[]const u8 = null,
};

pub const EdgeStyleOverride = struct {
    stroke: ?[]const u8 = null,
    stroke_width: ?f32 = null,
    dasharray: ?[]const u8 = null,
    label_color: ?[]const u8 = null,
};

/// An insertion-ordered list of nodes kept sorted by id (Rust `BTreeMap<String, Node>`).
pub fn SortedMap(comptime V: type) type {
    return struct {
        const Self = @This();
        keys: std.ArrayList([]const u8) = .empty,
        vals: std.ArrayList(V) = .empty,

        fn search(self: *const Self, key: []const u8) struct { found: bool, ix: usize } {
            var lo: usize = 0;
            var hi: usize = self.keys.items.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                switch (std.mem.order(u8, self.keys.items[mid], key)) {
                    .eq => return .{ .found = true, .ix = mid },
                    .lt => lo = mid + 1,
                    .gt => hi = mid,
                }
            }
            return .{ .found = false, .ix = lo };
        }

        pub fn get(self: *const Self, key: []const u8) ?*V {
            const r = self.search(key);
            return if (r.found) &self.vals.items[r.ix] else null;
        }

        pub fn contains(self: *const Self, key: []const u8) bool {
            return self.search(key).found;
        }

        /// Insert or replace (the key is borrowed: arena-owned).
        pub fn put(self: *Self, a: Allocator, key: []const u8, value: V) Allocator.Error!void {
            const r = self.search(key);
            if (r.found) {
                self.vals.items[r.ix] = value;
                return;
            }
            try self.keys.insert(a, r.ix, key);
            try self.vals.insert(a, r.ix, value);
        }

        pub fn len(self: *const Self) usize {
            return self.keys.items.len;
        }

        pub fn values(self: *const Self) []V {
            return self.vals.items;
        }

        pub fn clone(self: *const Self, a: Allocator) Allocator.Error!Self {
            return .{ .keys = try self.keys.clone(a), .vals = try self.vals.clone(a) };
        }

        pub fn remove(self: *Self, key: []const u8) void {
            const r = self.search(key);
            if (!r.found) return;
            _ = self.keys.orderedRemove(r.ix);
            _ = self.vals.orderedRemove(r.ix);
        }
    };
}

/// String-keyed hash map in the arena (Rust `HashMap<String, V>`).
pub fn StrMap(comptime V: type) type {
    return std.StringHashMapUnmanaged(V);
}

pub const Graph = struct {
    kind: DiagramKind = .flowchart,
    direction: Direction = .top_down,
    nodes: SortedMap(Node) = .{},
    node_order: StrMap(usize) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    subgraphs: std.ArrayList(Subgraph) = .empty,
    sequence_participants: std.ArrayList([]const u8) = .empty,
    sequence_frames: std.ArrayList(SequenceFrame) = .empty,
    sequence_notes: std.ArrayList(SequenceNote) = .empty,
    sequence_activations: std.ArrayList(SequenceActivation) = .empty,
    sequence_autonumber: ?usize = null,
    sequence_boxes: std.ArrayList(SequenceBox) = .empty,
    state_notes: std.ArrayList(StateNote) = .empty,
    pie_slices: std.ArrayList(PieSlice) = .empty,
    pie_title: ?[]const u8 = null,
    pie_show_data: bool = false,
    gantt_tasks: std.ArrayList(GanttTask) = .empty,
    gantt_title: ?[]const u8 = null,
    gantt_sections: std.ArrayList([]const u8) = .empty,
    gantt_display_mode: ?[]const u8 = null,
    class_defs: StrMap(NodeStyle) = .empty,
    node_classes: StrMap(std.ArrayList([]const u8)) = .empty,
    node_styles: StrMap(NodeStyle) = .empty,
    subgraph_styles: StrMap(NodeStyle) = .empty,
    subgraph_classes: StrMap(std.ArrayList([]const u8)) = .empty,
    node_links: StrMap(NodeLink) = .empty,
    edge_styles: std.AutoHashMapUnmanaged(usize, EdgeStyleOverride) = .empty,
    edge_style_default: ?EdgeStyleOverride = null,

    /// `Graph::ensure_node`.
    pub fn ensureNode(self: *Graph, a: Allocator, id: []const u8, label: ?[]const u8, shape: ?NodeShape) Allocator.Error!void {
        const existing = self.nodes.get(id);
        if (existing == null) {
            const key = try a.dupe(u8, id);
            try self.nodes.put(a, key, .{ .id = key, .label = key, .shape = .rectangle });
            const order = self.node_order.count();
            try self.node_order.put(a, key, order);
        }
        const entry = self.nodes.get(id).?;
        if (label) |l| entry.label = l;
        if (shape) |s| entry.shape = s;
    }

    /// Node ids in `node_order` order (insertion order).
    pub fn orderOf(self: *const Graph, id: []const u8) usize {
        return self.node_order.get(id) orelse std.math.maxInt(usize);
    }
};
