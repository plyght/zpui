//! Layout results (mermaid-rs-renderer `layout/types.rs`), for the diagram
//! kinds zeron renders. Everything lives in the render arena.

const std = @import("std");
const ir = @import("../ir.zig");
pub const TextBlock = @import("../text.zig").TextBlock;

pub const Point = struct { f32, f32 };
pub const Rect = struct { f32, f32, f32, f32 };

pub const NodeLayout = struct {
    id: []const u8,
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
    label: TextBlock,
    shape: ir.NodeShape,
    style: ir.NodeStyle = .{},
    link: ?ir.NodeLink = null,
    anchor_subgraph: ?usize = null,
    hidden: bool = false,
    icon: ?[]const u8 = null,
};

pub const EdgeLayout = struct {
    from: []const u8,
    to: []const u8,
    label: ?TextBlock = null,
    start_label: ?TextBlock = null,
    end_label: ?TextBlock = null,
    label_anchor: ?Point = null,
    start_label_anchor: ?Point = null,
    end_label_anchor: ?Point = null,
    points: std.ArrayList(Point) = .empty,
    directed: bool = false,
    arrow_start: bool = false,
    arrow_end: bool = false,
    arrow_start_kind: ?ir.EdgeArrowhead = null,
    arrow_end_kind: ?ir.EdgeArrowhead = null,
    start_decoration: ?ir.EdgeDecoration = null,
    end_decoration: ?ir.EdgeDecoration = null,
    style: ir.EdgeStyle = .solid,
    override_style: ir.EdgeStyleOverride = .{},
};

pub const SubgraphLayout = struct {
    label: []const u8,
    label_block: TextBlock,
    nodes: []const []const u8,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    style: ir.NodeStyle,
    icon: ?[]const u8 = null,
};

pub const Lifeline = struct { id: []const u8, x: f32, y1: f32, y2: f32 };

pub const SequenceLabel = struct { x: f32, y: f32, text: TextBlock };

pub const SequenceFrameLayout = struct {
    kind: ir.SequenceFrameKind,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    label_box: Rect,
    label: SequenceLabel,
    section_labels: []SequenceLabel,
    dividers: []f32,
};

pub const SequenceBoxLayout = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    label: ?TextBlock,
    color: ?[]const u8,
};

pub const SequenceNoteLayout = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    label: TextBlock,
    position: ir.SequenceNotePosition,
    participants: []const []const u8,
    index: usize,
};

pub const StateNoteLayout = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    label: TextBlock,
    position: ir.StateNotePosition,
    target: []const u8,
};

pub const SequenceActivationLayout = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    participant: []const u8,
    depth: usize,
};

pub const SequenceNumberLayout = struct { x: f32, y: f32, value: usize };

pub const PieSliceLayout = struct {
    label: TextBlock,
    value: f32,
    start_angle: f32,
    end_angle: f32,
    color: []const u8,
};

pub const PieLegendItem = struct {
    x: f32,
    y: f32,
    label: TextBlock,
    color: []const u8,
    marker_size: f32,
    value: f32,
};

pub const PieTitleLayout = struct { x: f32, y: f32, text: TextBlock };

pub const SequenceData = struct {
    lifelines: std.ArrayList(Lifeline) = .empty,
    footboxes: std.ArrayList(NodeLayout) = .empty,
    boxes: std.ArrayList(SequenceBoxLayout) = .empty,
    frames: std.ArrayList(SequenceFrameLayout) = .empty,
    notes: std.ArrayList(SequenceNoteLayout) = .empty,
    activations: std.ArrayList(SequenceActivationLayout) = .empty,
    numbers: std.ArrayList(SequenceNumberLayout) = .empty,
};

pub const PieData = struct {
    slices: std.ArrayList(PieSliceLayout) = .empty,
    legend: std.ArrayList(PieLegendItem) = .empty,
    center: Point,
    radius: f32,
    title: ?PieTitleLayout,
};

pub const GanttSectionLayout = struct {
    label: TextBlock,
    y: f32,
    height: f32,
    color: []const u8,
    band_color: []const u8,
};

pub const GanttTaskLayout = struct {
    label: TextBlock,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    color: []const u8,
    start: f32,
    duration: f32,
    status: ?ir.GanttStatus,
};

pub const GanttTick = struct { x: f32, label: []const u8 };

pub const GanttLayout = struct {
    title: ?TextBlock,
    sections: std.ArrayList(GanttSectionLayout) = .empty,
    tasks: std.ArrayList(GanttTaskLayout) = .empty,
    time_start: f32,
    time_end: f32,
    chart_x: f32,
    chart_y: f32,
    chart_width: f32,
    chart_height: f32,
    row_height: f32,
    label_x: f32,
    label_width: f32,
    section_label_x: f32,
    section_label_width: f32,
    task_label_x: f32,
    task_label_width: f32,
    title_y: f32,
    ticks: std.ArrayList(GanttTick) = .empty,
    compact: bool,
};

pub const DiagramData = union(enum) {
    graph: struct { state_notes: std.ArrayList(StateNoteLayout) = .empty },
    sequence: SequenceData,
    pie: PieData,
    gantt: GanttLayout,
};

pub const NodeMap = ir.SortedMap(NodeLayout);

pub const Layout = struct {
    kind: ir.DiagramKind,
    nodes: NodeMap = .{},
    edges: std.ArrayList(EdgeLayout) = .empty,
    subgraphs: std.ArrayList(SubgraphLayout) = .empty,
    width: f32,
    height: f32,
    diagram: DiagramData,
};
