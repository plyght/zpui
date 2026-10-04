//! Layout configuration (mermaid-rs-renderer `config.rs`, the parts the
//! supported diagram kinds read), with the crate's defaults.

pub const PieRenderMode = enum { @"error", chart };

pub const PieConfig = struct {
    render_mode: PieRenderMode = .chart,
    use_max_width: bool = true,
    text_position: f32 = 0.75,
    height: f32 = 360.0,
    margin: f32 = 28.0,
    legend_rect_size: f32 = 14.0,
    legend_spacing: f32 = 3.0,
    legend_horizontal_multiplier: f32 = 10.0,
    min_percent: f32 = 1.0,
};

pub const FlowchartAutoSpacingBucket = struct { min_nodes: usize, scale: f32 };

pub const FlowchartAutoSpacingConfig = struct {
    enabled: bool = true,
    min_spacing: f32 = 24.0,
    density_threshold: f32 = 1.5,
    dense_scale_floor: f32 = 0.7,
    buckets: []const FlowchartAutoSpacingBucket = &.{
        .{ .min_nodes = 0, .scale = 1.0 },
        .{ .min_nodes = 50, .scale = 0.75 },
        .{ .min_nodes = 80, .scale = 0.6 },
        .{ .min_nodes = 120, .scale = 0.45 },
        .{ .min_nodes = 160, .scale = 0.3 },
    },
};

pub const FlowchartRoutingConfig = struct {
    enable_grid_router: bool = true,
    grid_cell: f32 = 16.0,
    turn_penalty: f32 = 0.6,
    occupancy_weight: f32 = 1.2,
    max_steps: usize = 160_000,
    snap_ports_to_grid: bool = true,
};

pub const FlowchartObjectiveConfig = struct {
    enabled: bool = true,
    max_aspect_ratio: f32 = 9.0,
    wrap_min_groups: usize = 4,
    wrap_main_gap_scale: f32 = 1.15,
    wrap_cross_gap_scale: f32 = 1.35,
    edge_relax_passes: usize = 6,
    edge_gap_floor_ratio: f32 = 0.55,
    edge_label_weight: f32 = 0.9,
    endpoint_label_weight: f32 = 0.75,
    backedge_cross_weight: f32 = 0.65,
};

pub const FlowchartLayoutConfig = struct {
    order_passes: usize = 4,
    port_pad_ratio: f32 = 0.2,
    port_pad_min: f32 = 4.0,
    port_pad_max: f32 = 30.0,
    port_side_bias: f32 = 0.0,
    auto_spacing: FlowchartAutoSpacingConfig = .{},
    routing: FlowchartRoutingConfig = .{},
    objective: FlowchartObjectiveConfig = .{},
};

pub const LayoutConfig = struct {
    node_spacing: f32 = 50.0,
    rank_spacing: f32 = 50.0,
    node_padding_x: f32 = 30.0,
    node_padding_y: f32 = 15.0,
    label_line_height: f32 = 1.5,
    max_label_width_chars: usize = 22,
    preferred_aspect_ratio: ?f32 = null,
    fast_text_metrics: bool = false,
    pie: PieConfig = .{},
    flowchart: FlowchartLayoutConfig = .{},

    pub fn classLabelLineHeight(self: LayoutConfig) f32 {
        return self.label_line_height * 0.85;
    }
};
