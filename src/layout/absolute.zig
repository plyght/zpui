//! Layout of absolutely positioned children, shared by the flex and block algorithms. Insets
//! resolve against the parent's padding box, matching taffy.

const geometry = @import("../geometry.zig");
const engine = @import("layout.zig");
const s = @import("style.zig");

const Dims = s.Dims;
const Sides = s.Sides;
const LayoutEngine = engine.LayoutEngine;
const NodeId = engine.NodeId;

/// Where an absolutely positioned child with `auto` insets is placed.
pub const StaticPosition = union(enum) {
    /// Placed per the flex container's `justify_content` / `align_items`.
    flex: struct {
        row: bool,
        reverse: bool,
        wrap_reverse: bool,
        justify: s.JustifyContent,
        align_items: s.AlignItems,
        content_box_inset: Sides(f32),
    },
    /// Placed at this border-box-relative point (block flow position), before margins.
    point: geometry.Point(f32),
};

/// The parent's geometry needed to place absolute children.
pub const Container = struct {
    size: Dims(f32),
    border: Sides(f32),
    gutter: Dims(f32),
    /// The parent's content box (percentage basis passed down to the child's descendants).
    inner_size: Dims(?f32),
};

/// Sizes, lays out and positions one absolutely positioned child.
pub fn layoutChild(e: *LayoutEngine, child: NodeId, c: Container, static: StaticPosition) void {
    const cs = &e.node(child).style;
    const area: Dims(f32) = .{
        .width = c.size.width - c.border.horizontal() - c.gutter.width,
        .height = c.size.height - c.border.vertical() - c.gutter.height,
    };
    const area_opt: Dims(?f32) = .{ .width = area.width, .height = area.height };
    const ratio = cs.aspect_ratio;
    const margin = s.resolveSidesOpt(cs.margin, area.width);
    const pb = s.paddingBorder(cs, area.width).sum();

    const left = cs.inset.left.resolve(area.width);
    const right = cs.inset.right.resolve(area.width);
    const top = cs.inset.top.resolve(area.height);
    const bottom = cs.inset.bottom.resolve(area.height);

    const styled_min = s.applyAspectRatio(s.resolveDims(cs.min_size, area_opt), ratio);
    const min: Dims(?f32) = .{
        .width = @max(styled_min.width orelse pb.width, pb.width),
        .height = @max(styled_min.height orelse pb.height, pb.height),
    };
    const max = s.applyAspectRatio(s.resolveDims(cs.max_size, area_opt), ratio);
    var known = s.clampDims(s.applyAspectRatio(s.resolveDims(cs.size, area_opt), ratio), min, max);

    if (known.width == null and left != null and right != null) {
        const w = area.width - (margin.left orelse 0) - (margin.right orelse 0) - left.? - right.?;
        known.width = @max(w, 0);
        known = s.clampDims(s.applyAspectRatio(known, ratio), min, max);
    }
    if (known.height == null and top != null and bottom != null) {
        const h = area.height - (margin.top orelse 0) - (margin.bottom orelse 0) - top.? - bottom.?;
        known.height = @max(h, 0);
        known = s.clampDims(s.applyAspectRatio(known, ratio), min, max);
    }

    const avail: Dims(s.AvailableSpace) = .{
        .width = .{ .definite = s.clamp(c.size.width, min.width, max.width) },
        .height = .{ .definite = s.clamp(c.size.height, min.height, max.height) },
    };
    var final: Dims(f32) = .{ .width = known.width orelse 0, .height = known.height orelse 0 };
    if (known.width == null or known.height == null) {
        const measured = e.computeSize(child, known, c.inner_size, avail, .content_size);
        if (known.width == null) final.width = s.clamp(measured.width, min.width, max.width);
        if (known.height == null) final.height = s.clamp(measured.height, min.height, max.height);
    }
    _ = e.performLayout(child, .{ .width = final.width, .height = final.height }, c.inner_size, avail, .inherent_size);

    // Auto margins absorb free space only when both opposing insets are set.
    const nam = s.orZero(margin);
    const free_w = @max(area.width - final.width - nam.horizontal(), 0);
    const free_h = @max(area.height - final.height - nam.vertical(), 0);
    const auto_w: f32 = blk: {
        const n: f32 = @floatFromInt(@as(u8, @intFromBool(margin.left == null)) + @intFromBool(margin.right == null));
        break :blk if (n > 0 and left != null and right != null) free_w / n else 0;
    };
    const auto_h: f32 = blk: {
        const n: f32 = @floatFromInt(@as(u8, @intFromBool(margin.top == null)) + @intFromBool(margin.bottom == null));
        break :blk if (n > 0 and top != null and bottom != null) free_h / n else 0;
    };
    const m: Sides(f32) = .{
        .top = margin.top orelse auto_h,
        .bottom = margin.bottom orelse auto_h,
        .left = margin.left orelse auto_w,
        .right = margin.right orelse auto_w,
    };

    const x = if (left) |l|
        c.border.left + l + m.left
    else if (right) |r|
        c.size.width - c.border.right - c.gutter.width - r - final.width - m.right
    else
        staticOffset(static, c, final, m, true);
    const y = if (top) |t|
        c.border.top + t + m.top
    else if (bottom) |b|
        c.size.height - c.border.bottom - c.gutter.height - b - final.height - m.bottom
    else
        staticOffset(static, c, final, m, false);

    e.setLayout(child, .{ .x = x, .y = y }, .{ .width = final.width, .height = final.height });
}

/// Static position along the horizontal (`horizontal == true`) or vertical axis.
fn staticOffset(static: StaticPosition, c: Container, size: Dims(f32), m: Sides(f32), horizontal: bool) f32 {
    switch (static) {
        .point => |p| return if (horizontal) p.x + m.left else p.y + m.top,
        .flex => |f| {
            const inset = f.content_box_inset;
            const is_main = horizontal == f.row;
            // Values below are flex-relative; `row` maps them to the requested physical axis.
            const row = f.row;
            if (is_main) {
                const at_start = inset.mainStart(row) + m.mainStart(row);
                const at_end = c.size.main(row) - inset.mainEnd(row) - size.main(row) - m.mainEnd(row);
                return switch (f.justify) {
                    .space_between, .start => at_start,
                    .stretch, .flex_start => if (f.reverse) at_end else at_start,
                    .flex_end => if (f.reverse) at_start else at_end,
                    .end => at_end,
                    .space_evenly, .space_around, .center => (c.size.main(row) + inset.mainStart(row) - inset.mainEnd(row) - size.main(row) + m.mainStart(row) - m.mainEnd(row)) / 2,
                };
            } else {
                const at_start = inset.crossStart(row) + m.crossStart(row);
                const at_end = c.size.cross(row) - inset.crossEnd(row) - size.cross(row) - m.crossEnd(row);
                return switch (f.align_items) {
                    .start => at_start,
                    .baseline, .stretch, .flex_start => if (f.wrap_reverse) at_end else at_start,
                    .flex_end => if (f.wrap_reverse) at_start else at_end,
                    .end => at_end,
                    .center => (c.size.cross(row) + inset.crossStart(row) - inset.crossEnd(row) - size.cross(row) + m.crossStart(row) - m.crossEnd(row)) / 2,
                };
            }
        },
    }
}
