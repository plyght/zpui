//! The CSS flexbox algorithm (https://www.w3.org/TR/css-flexbox-1/#layout-algorithm), structured
//! after taffy's implementation. All sizes are border-box; "outer" sizes include margins.
//! Main/cross helpers take `row: bool` (true when the main axis is horizontal).

const std = @import("std");
const engine = @import("layout.zig");
const s = @import("style.zig");
const absolute = @import("absolute.zig");

const Dims = s.Dims;
const Sides = s.Sides;
const AvailableSpace = s.AvailableSpace;
const LayoutEngine = engine.LayoutEngine;
const NodeId = engine.NodeId;
const Input = engine.Input;
const Size = @import("../geometry.zig").Size(f32);

/// A flex item's working state during layout.
pub const Item = struct {
    node: NodeId,
    size: Dims(?f32),
    min_size: Dims(?f32),
    max_size: Dims(?f32),
    align_self: s.AlignItems,
    overflow: s.OverflowXY,
    flex_grow: f32,
    flex_shrink: f32,
    /// Relative-position offsets.
    inset: Sides(?f32),
    margin: Sides(f32),
    margin_is_auto: Sides(bool),
    padding_border: Sides(f32),

    flex_basis: f32 = 0,
    inner_flex_basis: f32 = 0,
    violation: f32 = 0,
    frozen: bool = false,
    resolved_minimum_main_size: f32 = 0,
    hypothetical_inner_size: Dims(f32) = .all(0),
    hypothetical_outer_size: Dims(f32) = .all(0),
    target_size: Dims(f32) = .all(0),
    outer_target_size: Dims(f32) = .all(0),
    offset_main: f32 = 0,
    offset_cross: f32 = 0,
};

/// A flex line: a range of items plus its cross size and offset.
pub const Line = struct {
    start: usize,
    end: usize,
    cross_size: f32 = 0,
    offset_cross: f32 = 0,
};

/// Values that are constant for one invocation of the algorithm on a container.
const Ctx = struct {
    row: bool,
    reverse: bool,
    wrap: bool,
    wrap_reverse: bool,
    min_size: Dims(?f32),
    max_size: Dims(?f32),
    border: Sides(f32),
    gutter: Dims(f32),
    /// padding + border + scrollbar gutter.
    content_box_inset: Sides(f32),
    gap: Dims(f32),
    align_items: s.AlignItems,
    align_content: s.AlignContent,
    justify_content: s.JustifyContent,
    node_inner_size: Dims(?f32),
    container_size: Dims(f32) = .all(0),
    inner_container_size: Dims(f32) = .all(0),
};

/// Entry point: sizes (and in perform mode, lays out) flex container `id`.
pub fn compute(e: *LayoutEngine, id: NodeId, input: Input) Size {
    const style = &e.node(id).style;
    const parent = input.parent_size;
    const ratio = style.aspect_ratio;
    const min_size = s.applyAspectRatio(s.resolveDims(style.min_size, parent), ratio);
    const max_size = s.applyAspectRatio(s.resolveDims(style.max_size, parent), ratio);
    const pb_sum = s.paddingBorder(style, parent.width).sum();
    const styled: Dims(?f32) = if (input.sizing_mode == .inherent_size)
        s.clampDims(s.applyAspectRatio(s.resolveDims(style.size, parent), ratio), min_size, max_size)
    else
        .all(null);
    const min_max_definite: Dims(?f32) = .{
        .width = if (min_size.width != null and max_size.width != null and max_size.width.? <= min_size.width.?) min_size.width else null,
        .height = if (min_size.height != null and max_size.height != null and max_size.height.? <= min_size.height.?) min_size.height else null,
    };
    const known: Dims(?f32) = .{
        .width = s.maxOpt(input.known.width orelse min_max_definite.width orelse styled.width, pb_sum.width),
        .height = s.maxOpt(input.known.height orelse min_max_definite.height orelse styled.height, pb_sum.height),
    };
    if (input.run_mode == .compute_size) {
        if (known.width) |w| if (known.height) |h| return .{ .width = w, .height = h };
    }
    var inner = input;
    inner.known = known;
    return run(e, id, inner, min_size, max_size);
}

fn run(e: *LayoutEngine, id: NodeId, input: Input, min_size: Dims(?f32), max_size: Dims(?f32)) Size {
    const style = &e.node(id).style;
    const row = style.flex_direction.isRow();
    const parent_w = input.parent_size.width;
    const known = input.known;

    const border = s.resolveSidesLP(style.border, parent_w);
    const gutter = s.scrollbarGutter(style);
    var inset = s.resolveSidesLP(style.padding, parent_w).add(border);
    inset.right += gutter.width;
    inset.bottom += gutter.height;
    const node_inner_size: Dims(?f32) = .{
        .width = s.subOpt(known.width, inset.horizontal()),
        .height = s.subOpt(known.height, inset.vertical()),
    };
    var ctx: Ctx = .{
        .row = row,
        .reverse = style.flex_direction.isReverse(),
        .wrap = style.flex_wrap != .no_wrap,
        .wrap_reverse = style.flex_wrap == .wrap_reverse,
        .min_size = min_size,
        .max_size = max_size,
        .border = border,
        .gutter = gutter,
        .content_box_inset = inset,
        .gap = .{ .width = style.gap.width.resolve(node_inner_size.width), .height = style.gap.height.resolve(node_inner_size.height) },
        .align_items = style.align_items orelse .stretch,
        .align_content = style.align_content orelse .stretch,
        .justify_content = style.justify_content orelse .flex_start,
        .node_inner_size = node_inner_size,
    };

    // 1. Generate flex items from in-flow children.
    const items_start = e.flex_items.items.len;
    defer e.flex_items.shrinkRetainingCapacity(items_start);
    for (e.children(id)) |child| {
        const cs = &e.node(child).style;
        if (cs.display == .none or cs.position == .absolute) continue;
        const r = cs.aspect_ratio;
        e.flex_items.appendAssumeCapacity(.{
            .node = child,
            .size = s.applyAspectRatio(s.resolveDims(cs.size, node_inner_size), r),
            .min_size = s.applyAspectRatio(s.resolveDims(cs.min_size, node_inner_size), r),
            .max_size = s.applyAspectRatio(s.resolveDims(cs.max_size, node_inner_size), r),
            .align_self = cs.align_self orelse ctx.align_items,
            .overflow = cs.overflow,
            .flex_grow = cs.flex_grow,
            .flex_shrink = cs.flex_shrink,
            .inset = .{
                .top = cs.inset.top.resolve(node_inner_size.height),
                .bottom = cs.inset.bottom.resolve(node_inner_size.height),
                .left = cs.inset.left.resolve(node_inner_size.width),
                .right = cs.inset.right.resolve(node_inner_size.width),
            },
            .margin = s.orZero(s.resolveSidesOpt(cs.margin, node_inner_size.width)),
            .margin_is_auto = .{ .top = cs.margin.top.isAuto(), .right = cs.margin.right.isAuto(), .bottom = cs.margin.bottom.isAuto(), .left = cs.margin.left.isAuto() },
            .padding_border = s.paddingBorder(cs, node_inner_size.width),
        });
    }
    const items = e.flex_items.items[items_start..];

    // 2. Available space for items (content box).
    const available: Dims(AvailableSpace) = blk: {
        const margin = s.orZero(s.resolveSidesOpt(style.margin, parent_w));
        break :blk .{
            .width = if (known.width) |w| .{ .definite = w - inset.horizontal() } else input.available.width.sub(margin.horizontal()).sub(inset.horizontal()),
            .height = if (known.height) |h| .{ .definite = h - inset.vertical() } else input.available.height.sub(margin.vertical()).sub(inset.vertical()),
        };
    };

    // 3. Flex base size and hypothetical main size of each item.
    for (items) |*it| determineFlexBaseSize(e, &ctx, available, it);

    // 4. Collect items into flex lines.
    const lines_start = e.flex_lines.items.len;
    defer e.flex_lines.shrinkRetainingCapacity(lines_start);
    collectLines(e, &ctx, available, items);
    const lines = e.flex_lines.items[lines_start..];

    // 5. Main size of the container.
    determineContainerMainSize(e, &ctx, known, available, items, lines);

    // 6. Resolve flexible lengths.
    for (lines) |line| resolveFlexibleLengths(&ctx, items[line.start..line.end]);

    // 7. Hypothetical cross size of each item.
    for (items) |*it| determineHypotheticalCrossSize(e, &ctx, available, it);

    // 8-9. Cross size of each line.
    const inset_cross = inset.crossSum(row);
    if (!ctx.wrap and known.cross(row) != null) {
        lines[0].cross_size = s.clamp(known.cross(row).?, ctx.min_size.cross(row), ctx.max_size.cross(row)) - inset_cross;
    } else {
        for (lines) |*line| {
            var m: f32 = 0;
            for (items[line.start..line.end]) |it| m = @max(m, it.hypothetical_outer_size.cross(row));
            line.cross_size = m;
        }
        if (!ctx.wrap and lines.len > 0) {
            lines[0].cross_size = s.clamp(lines[0].cross_size, s.subOpt(ctx.min_size.cross(row), inset_cross), s.subOpt(ctx.max_size.cross(row), inset_cross));
        }
    }

    // 10. align-content: stretch.
    const cross_gap = ctx.gap.cross(row);
    const total_cross_gap = if (lines.len > 1) cross_gap * @as(f32, @floatFromInt(lines.len - 1)) else 0;
    if (ctx.align_content == .stretch and lines.len > 0) {
        if (s.clampOpt(s.subOpt(known.cross(row) orelse ctx.min_size.cross(row), inset_cross), s.subOpt(ctx.min_size.cross(row), inset_cross), s.subOpt(ctx.max_size.cross(row), inset_cross))) |inner_cross| {
            var total = total_cross_gap;
            for (lines) |line| total += line.cross_size;
            if (total < inner_cross) {
                const add = (inner_cross - total) / @as(f32, @floatFromInt(lines.len));
                for (lines) |*line| line.cross_size += add;
            }
        }
    }

    // 11. Used cross size of each item (stretch).
    for (lines) |line| {
        for (items[line.start..line.end]) |*it| {
            const pb_cross = it.padding_border.crossSum(row);
            if (it.align_self == .stretch and !it.margin_is_auto.crossStart(row) and !it.margin_is_auto.crossEnd(row) and it.size.cross(row) == null) {
                // Max size ignoring aspect ratio, as in taffy.
                const max_raw = s.resolveDims(e.node(it.node).style.max_size, node_inner_size).cross(row);
                it.target_size.setCross(row, @max(s.clamp(line.cross_size - it.margin.crossSum(row), it.min_size.cross(row), max_raw), pb_cross));
            } else {
                it.target_size.setCross(row, it.hypothetical_inner_size.cross(row));
            }
            it.outer_target_size.setCross(row, it.target_size.cross(row) + it.margin.crossSum(row));
        }
    }

    // 12. Distribute remaining main-axis free space (auto margins, justify-content).
    for (lines) |line| distributeMainFreeSpace(&ctx, items[line.start..line.end]);

    // 13. Cross-axis auto margins and align-self.
    for (lines) |line| {
        for (items[line.start..line.end]) |*it| {
            const free = line.cross_size - it.outer_target_size.cross(row);
            const start_auto = it.margin_is_auto.crossStart(row);
            const end_auto = it.margin_is_auto.crossEnd(row);
            if (start_auto and end_auto) {
                it.margin.setCrossStart(row, @max(free, 0) / 2);
                it.margin.setCrossEnd(row, @max(free, 0) / 2);
            } else if (start_auto) {
                it.margin.setCrossStart(row, @max(free, 0));
            } else if (end_auto) {
                it.margin.setCrossEnd(row, @max(free, 0));
            } else {
                it.offset_cross = switch (it.align_self) {
                    .start => 0,
                    .baseline, .stretch, .flex_start => if (ctx.wrap_reverse) free else 0,
                    .flex_end => if (ctx.wrap_reverse) 0 else free,
                    .end => free,
                    .center => free / 2,
                };
            }
        }
    }

    // 14. Container cross size.
    var total_lines_cross = total_cross_gap;
    for (lines) |line| total_lines_cross += line.cross_size;
    const outer_cross = @max(s.clamp(known.cross(row) orelse total_lines_cross + inset_cross, ctx.min_size.cross(row), ctx.max_size.cross(row)), inset_cross);
    ctx.container_size.setCross(row, outer_cross);
    ctx.inner_container_size.setCross(row, outer_cross - inset_cross);
    const container: Size = .{ .width = ctx.container_size.width, .height = ctx.container_size.height };
    if (input.run_mode == .compute_size) return container;

    // 15. align-content: position lines.
    {
        const free = ctx.inner_container_size.cross(row) - total_lines_cross;
        const n = lines.len;
        for (0..n) |i| {
            const line = if (ctx.wrap_reverse) &lines[n - 1 - i] else &lines[i];
            line.offset_cross = alignmentOffset(free, n, cross_gap, ctx.align_content, ctx.wrap_reverse, i == 0);
        }
    }

    // 16. Final layout of in-flow items.
    {
        var total_cross = inset.crossStart(row);
        const final_avail: Dims(AvailableSpace) = .{ .width = .{ .definite = container.width }, .height = .{ .definite = container.height } };
        const n_lines = lines.len;
        for (0..n_lines) |li| {
            const line = if (ctx.wrap_reverse) lines[n_lines - 1 - li] else lines[li];
            var total_main = inset.mainStart(row);
            const line_items = items[line.start..line.end];
            for (0..line_items.len) |ii| {
                const it = if (ctx.reverse) &line_items[line_items.len - 1 - ii] else &line_items[ii];
                const size = e.performLayout(it.node, .{ .width = it.target_size.width, .height = it.target_size.height }, ctx.node_inner_size, final_avail, .inherent_size);
                const sz: Dims(f32) = .{ .width = size.width, .height = size.height };
                const rel_main = it.inset.mainStart(row) orelse if (it.inset.mainEnd(row)) |v| -v else 0;
                const rel_cross = it.inset.crossStart(row) orelse if (it.inset.crossEnd(row)) |v| -v else 0;
                const off_main = total_main + it.offset_main + it.margin.mainStart(row) + rel_main;
                const off_cross = total_cross + it.offset_cross + line.offset_cross + it.margin.crossStart(row) + rel_cross;
                e.setLayout(it.node, if (row) .{ .x = off_main, .y = off_cross } else .{ .x = off_cross, .y = off_main }, size);
                total_main += it.offset_main + it.margin.mainSum(row) + sz.main(row);
            }
            total_cross += line.offset_cross + line.cross_size;
        }
    }

    // 17. Absolutely positioned and hidden children.
    for (e.children(id)) |child| {
        const cs = &e.node(child).style;
        if (cs.display == .none) {
            e.hideSubtree(child);
        } else if (cs.position == .absolute) {
            absolute.layoutChild(e, child, .{
                .size = ctx.container_size,
                .border = ctx.border,
                .gutter = ctx.gutter,
                .inner_size = ctx.node_inner_size,
            }, .{ .flex = .{
                .row = row,
                .reverse = ctx.reverse,
                .wrap_reverse = ctx.wrap_reverse,
                .justify = ctx.justify_content,
                .align_items = cs.align_self orelse ctx.align_items,
                .content_box_inset = inset,
            } });
        }
    }
    return container;
}

/// Known dimensions used when measuring an item's content: its styled cross size, or the stretched
/// available cross space.
fn itemContentKnown(ctx: *const Ctx, it: *const Item, cross_avail: AvailableSpace) Dims(?f32) {
    var known = it.size;
    known.setMain(ctx.row, null);
    if (it.align_self == .stretch and known.cross(ctx.row) == null) {
        known.setCross(ctx.row, s.subOpt(cross_avail.toOption(), it.margin.crossSum(ctx.row)));
    }
    return known;
}

/// Cross available space for items: the container's inner cross size when known.
fn crossAvailable(ctx: *const Ctx, available: Dims(AvailableSpace)) AvailableSpace {
    const a = available.cross(ctx.row);
    return switch (a) {
        .definite => |v| .{ .definite = ctx.node_inner_size.cross(ctx.row) orelse v },
        else => a,
    };
}

fn measureMain(e: *LayoutEngine, ctx: *const Ctx, node: NodeId, known: Dims(?f32), parent: Dims(?f32), main_avail: AvailableSpace, cross_avail: AvailableSpace, mode: engine.SizingMode) f32 {
    const size = e.computeSize(node, known, parent, .fromMainCross(ctx.row, main_avail, cross_avail), mode);
    return if (ctx.row) size.width else size.height;
}

fn determineFlexBaseSize(e: *LayoutEngine, ctx: *const Ctx, available: Dims(AvailableSpace), it: *Item) void {
    const row = ctx.row;
    const cs = &e.node(it.node).style;
    const cross_avail = crossAvailable(ctx, available);
    const child_parent: Dims(?f32) = .fromMainCross(row, null, ctx.node_inner_size.cross(row));
    const known = itemContentKnown(ctx, it, cross_avail);
    const main_avail: AvailableSpace = if (available.main(row) == .min_content) .min_content else .max_content;

    const basis: f32 = if (cs.flex_basis.resolve(ctx.node_inner_size.main(row)) orelse it.size.main(row)) |b|
        b
    else if (cs.aspect_ratio != null and known.cross(row) != null)
        (if (row) known.cross(row).? * cs.aspect_ratio.? else known.cross(row).? / cs.aspect_ratio.?)
    else
        measureMain(e, ctx, it.node, known, child_parent, main_avail, cross_avail, .content_size);

    const pb_main = it.padding_border.mainSum(row);
    it.flex_basis = @max(basis, pb_main);
    it.inner_flex_basis = it.flex_basis - pb_main;

    // Automatic minimum size (4.5): zero for scroll containers, else content-based.
    const overflow_main = if (row) it.overflow.x else it.overflow.y;
    const style_min: ?f32 = it.min_size.main(row) orelse if (overflow_main.isScrollContainer()) @as(f32, 0) else null;
    var min_main = style_min orelse blk: {
        var v = measureMain(e, ctx, it.node, known, child_parent, .min_content, cross_avail, .content_size);
        if (it.size.main(row)) |sz| v = @min(v, sz);
        if (it.max_size.main(row)) |sz| v = @min(v, sz);
        break :blk v;
    };
    min_main = @max(min_main, pb_main);
    it.resolved_minimum_main_size = min_main;

    const hyp = s.clamp(it.flex_basis, min_main, it.max_size.main(row));
    it.hypothetical_inner_size.setMain(row, hyp);
    it.hypothetical_outer_size.setMain(row, hyp + it.margin.mainSum(row));
}

fn collectLines(e: *LayoutEngine, ctx: *const Ctx, available: Dims(AvailableSpace), items: []Item) void {
    const row = ctx.row;
    if (items.len == 0) {
        e.flex_lines.appendAssumeCapacity(.{ .start = 0, .end = 0 });
        return;
    }
    var main_avail = available.main(row);
    if (ctx.wrap) if (ctx.max_size.main(row)) |mx| {
        const inner_max = mx - ctx.content_box_inset.mainSum(row);
        main_avail = .{ .definite = if (main_avail.toOption()) |v| @min(v, inner_max) else inner_max };
    };
    if (!ctx.wrap or main_avail == .max_content) {
        e.flex_lines.appendAssumeCapacity(.{ .start = 0, .end = items.len });
        return;
    }
    if (main_avail == .min_content) {
        for (0..items.len) |i| e.flex_lines.appendAssumeCapacity(.{ .start = i, .end = i + 1 });
        return;
    }
    const limit = main_avail.definite;
    const gap = ctx.gap.main(row);
    var i: usize = 0;
    while (i < items.len) {
        const start = i;
        var len: f32 = 0;
        while (i < items.len) : (i += 1) {
            const g: f32 = if (i == start) 0 else gap;
            const sz = items[i].hypothetical_outer_size.main(row);
            if (i > start and len + g + sz > limit) break;
            len += g + sz;
        }
        e.flex_lines.appendAssumeCapacity(.{ .start = start, .end = i });
    }
}

fn sumGaps(gap: f32, n: usize) f32 {
    return if (n > 1) gap * @as(f32, @floatFromInt(n - 1)) else 0;
}

fn determineContainerMainSize(e: *LayoutEngine, ctx: *Ctx, known: Dims(?f32), available: Dims(AvailableSpace), items: []Item, lines: []const Line) void {
    const row = ctx.row;
    const inset_main = ctx.content_box_inset.mainSum(row);
    const gap = ctx.gap.main(row);
    var outer = known.main(row) orelse switch (available.main(row)) {
        .definite => |avail| blk: {
            var longest: f32 = 0;
            for (lines) |line| {
                var len = sumGaps(gap, line.end - line.start);
                for (items[line.start..line.end]) |it| len += it.hypothetical_outer_size.main(row);
                longest = @max(longest, len);
            }
            var size = longest + inset_main;
            if (lines.len > 1) size = @max(size, avail + inset_main);
            break :blk size;
        },
        .min_content, .max_content => blk: {
            const cross_avail = crossAvailable(ctx, available);
            var longest: f32 = 0;
            for (lines) |line| {
                var len = sumGaps(gap, line.end - line.start);
                for (items[line.start..line.end]) |*it| len += contentContribution(e, ctx, available, cross_avail, it);
                longest = @max(longest, len);
            }
            break :blk longest + inset_main;
        },
    };
    outer = @max(s.clamp(outer, ctx.min_size.main(row), ctx.max_size.main(row)), inset_main);
    ctx.container_size.setMain(row, outer);
    ctx.inner_container_size.setMain(row, outer - inset_main);
    ctx.node_inner_size.setMain(row, outer - inset_main);
}

/// An item's outer main-size contribution to an intrinsically sized container.
fn contentContribution(e: *LayoutEngine, ctx: *const Ctx, available: Dims(AvailableSpace), cross_avail: AvailableSpace, it: *const Item) f32 {
    const row = ctx.row;
    const margin = it.margin.mainSum(row);
    const pref = it.size.main(row);
    const basis = if (pref) |p| @max(it.flex_basis, p) else it.flex_basis;
    const basis_min: ?f32 = if (it.flex_shrink == 0) basis else null;
    const basis_max: ?f32 = if (it.flex_grow == 0) basis else null;
    const style_min = it.min_size.main(row);
    const style_max = it.max_size.main(row);
    const min_main = @max(if (style_min) |m| (if (basis_min) |b| @max(m, b) else m) else basis_min orelse it.resolved_minimum_main_size, it.resolved_minimum_main_size);
    const max_main = (if (style_max) |m| (if (basis_max) |b| @min(m, b) else m) else basis_max) orelse std.math.inf(f32);
    if (pref) |p| if (max_main <= min_main or max_main <= p) return @max(@min(p, max_main), min_main) + margin;
    if (max_main <= min_main) return min_main + margin;
    const known = itemContentKnown(ctx, it, cross_avail);
    const content = measureMain(e, ctx, it.node, known, ctx.node_inner_size, available.main(row), cross_avail, .inherent_size);
    return s.clamp(content, min_main, max_main) + margin;
}

/// 9.7 Resolving flexible lengths, for one line.
fn resolveFlexibleLengths(ctx: *const Ctx, items: []Item) void {
    const row = ctx.row;
    const inner_main = ctx.inner_container_size.main(row);
    const total_gap = sumGaps(ctx.gap.main(row), items.len);

    var used: f32 = total_gap;
    for (items) |it| used += it.hypothetical_outer_size.main(row);
    const growing = used < inner_main;
    const shrinking = used > inner_main;
    const exact = !growing and !shrinking;

    // Size inflexible items.
    for (items) |*it| {
        const hyp = it.hypothetical_inner_size.main(row);
        it.target_size.setMain(row, hyp);
        it.frozen = false;
        if (exact or (it.flex_grow == 0 and it.flex_shrink == 0) or
            (growing and (it.flex_basis > hyp or it.flex_grow == 0)) or
            (shrinking and (it.flex_basis < hyp or it.flex_shrink == 0)))
        {
            it.frozen = true;
        }
        it.outer_target_size.setMain(row, it.target_size.main(row) + it.margin.mainSum(row));
    }
    if (exact) return;

    const initial_free = blk: {
        var u: f32 = total_gap;
        for (items) |it| u += if (it.frozen) it.outer_target_size.main(row) else it.flex_basis + it.margin.mainSum(row);
        break :blk inner_main - u;
    };

    while (true) {
        var any_unfrozen = false;
        var u: f32 = total_gap;
        var sum_grow: f32 = 0;
        var sum_shrink: f32 = 0;
        for (items) |it| {
            if (it.frozen) {
                u += it.outer_target_size.main(row);
            } else {
                any_unfrozen = true;
                u += it.flex_basis + it.margin.mainSum(row);
                sum_grow += it.flex_grow;
                sum_shrink += it.flex_shrink;
            }
        }
        if (!any_unfrozen) break;

        const remaining = inner_main - u;
        const free = if (growing and sum_grow < 1)
            @min(initial_free * sum_grow, remaining)
        else if (shrinking and sum_shrink < 1)
            @max(initial_free * sum_shrink, remaining)
        else
            remaining;

        // Distribute free space proportionally.
        if (std.math.isNormal(free)) {
            if (growing and sum_grow > 0) {
                for (items) |*it| if (!it.frozen) it.target_size.setMain(row, it.flex_basis + free * (it.flex_grow / sum_grow));
            } else if (shrinking and sum_shrink > 0) {
                var sum_scaled: f32 = 0;
                for (items) |it| if (!it.frozen) {
                    sum_scaled += it.inner_flex_basis * it.flex_shrink;
                };
                if (sum_scaled > 0) {
                    for (items) |*it| if (!it.frozen) {
                        const scaled = it.inner_flex_basis * it.flex_shrink;
                        it.target_size.setMain(row, it.flex_basis + free * (scaled / sum_scaled));
                    };
                }
            }
        } else {
            for (items) |*it| if (!it.frozen) it.target_size.setMain(row, it.flex_basis);
        }

        // Fix min/max violations.
        var total_violation: f32 = 0;
        for (items) |*it| if (!it.frozen) {
            const target = it.target_size.main(row);
            const clamped = @max(s.clamp(target, it.resolved_minimum_main_size, it.max_size.main(row)), 0);
            it.violation = clamped - target;
            it.target_size.setMain(row, clamped);
            it.outer_target_size.setMain(row, clamped + it.margin.mainSum(row));
            total_violation += it.violation;
        };

        // Freeze over-flexed items.
        for (items) |*it| if (!it.frozen) {
            if (total_violation > 0) {
                if (it.violation > 0) it.frozen = true;
            } else if (total_violation < 0) {
                if (it.violation < 0) it.frozen = true;
            } else {
                it.frozen = true;
            }
        };
    }
}

fn determineHypotheticalCrossSize(e: *LayoutEngine, ctx: *const Ctx, available: Dims(AvailableSpace), it: *Item) void {
    const row = ctx.row;
    const pb_cross = it.padding_border.crossSum(row);
    const min_c = it.min_size.cross(row);
    const max_c = it.max_size.cross(row);
    const styled = s.maxOpt(s.clampOpt(it.size.cross(row), min_c, max_c), pb_cross);
    const inner_cross = styled orelse blk: {
        const target_main = it.target_size.main(row);
        const size = e.computeSize(
            it.node,
            .fromMainCross(row, target_main, null),
            ctx.node_inner_size,
            .fromMainCross(row, .{ .definite = ctx.container_size.main(row) }, available.cross(row).sub(it.margin.crossSum(row))),
            .content_size,
        );
        const c = if (row) size.height else size.width;
        break :blk @max(s.clamp(c, min_c, max_c), pb_cross);
    };
    it.hypothetical_inner_size.setCross(row, inner_cross);
    it.hypothetical_outer_size.setCross(row, inner_cross + it.margin.crossSum(row));
}

fn distributeMainFreeSpace(ctx: *const Ctx, items: []Item) void {
    const row = ctx.row;
    const gap = ctx.gap.main(row);
    var used = sumGaps(gap, items.len);
    var auto_count: f32 = 0;
    for (items) |it| {
        used += it.outer_target_size.main(row);
        if (it.margin_is_auto.mainStart(row)) auto_count += 1;
        if (it.margin_is_auto.mainEnd(row)) auto_count += 1;
    }
    const free = ctx.inner_container_size.main(row) - used;
    const n = items.len;
    if (free > 0 and auto_count > 0) {
        const per = free / auto_count;
        for (0..n) |i| {
            const it = if (ctx.reverse) &items[n - 1 - i] else &items[i];
            if (it.margin_is_auto.mainStart(row)) it.margin.setMainStart(row, per);
            if (it.margin_is_auto.mainEnd(row)) it.margin.setMainEnd(row, per);
            it.offset_main = if (i == 0) 0 else gap;
        }
        return;
    }
    for (0..n) |i| {
        const it = if (ctx.reverse) &items[n - 1 - i] else &items[i];
        it.offset_main = alignmentOffset(free, n, gap, ctx.justify_content, ctx.reverse, i == 0);
    }
}

/// Offset before an item (or line) when distributing `free` space, in physical order. Matches
/// taffy's `compute_alignment_offset` (unsafe alignment: negative free space overflows).
fn alignmentOffset(free: f32, n: usize, gap: f32, mode: s.AlignContent, reverse: bool, first: bool) f32 {
    const count: f32 = @floatFromInt(n);
    if (first) return switch (mode) {
        .start, .stretch => 0,
        .flex_start => if (reverse) free else 0,
        .end => free,
        .flex_end => if (reverse) 0 else free,
        .center => free / 2,
        .space_between => 0,
        .space_around => if (free >= 0) free / count / 2 else free / 2,
        .space_evenly => if (free >= 0) free / (count + 1) else free / 2,
    };
    const f = @max(free, 0);
    return gap + switch (mode) {
        .start, .flex_start, .end, .flex_end, .center, .stretch => 0,
        .space_between => f / (count - 1),
        .space_around => f / count,
        .space_evenly => f / (count + 1),
    };
}
