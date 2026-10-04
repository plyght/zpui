//! Simplified CSS block layout (gpui's default `display`): in-flow children stack vertically,
//! auto-width children fill the container, horizontal auto margins center, and adjacent sibling
//! vertical margins collapse. Margins do not collapse through parents (a taffy difference).

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

/// Entry point: sizes (and in perform mode, lays out) block container `id`.
pub fn compute(e: *LayoutEngine, id: NodeId, input: Input) Size {
    const style = &e.node(id).style;
    const parent = input.parent_size;
    const ratio = style.aspect_ratio;
    const min = s.applyAspectRatio(s.resolveDims(style.min_size, parent), ratio);
    const max = s.applyAspectRatio(s.resolveDims(style.max_size, parent), ratio);
    const pb = s.paddingBorder(style, parent.width);
    const pb_sum = pb.sum();
    const styled: Dims(?f32) = if (input.sizing_mode == .inherent_size)
        s.clampDims(s.applyAspectRatio(s.resolveDims(style.size, parent), ratio), min, max)
    else
        .all(null);
    const known: Dims(?f32) = .{
        .width = s.maxOpt(input.known.width orelse styled.width, pb_sum.width),
        .height = s.maxOpt(input.known.height orelse styled.height, pb_sum.height),
    };
    if (input.run_mode == .compute_size) {
        if (known.width) |w| if (known.height) |h| return .{ .width = w, .height = h };
    }

    const gutter = s.scrollbarGutter(style);
    var inset = pb;
    inset.right += gutter.width;
    inset.bottom += gutter.height;

    // Width: definite, or the widest child's contribution.
    const outer_w = known.width orelse blk: {
        const avail_w = input.available.width.sub(inset.horizontal());
        var widest: f32 = 0;
        for (e.children(id)) |child| {
            const cs = &e.node(child).style;
            if (cs.display == .none or cs.position == .absolute) continue;
            const none: Dims(?f32) = .all(null);
            const ck = s.clampDims(s.resolveDims(cs.size, none), s.resolveDims(cs.min_size, none), s.resolveDims(cs.max_size, none));
            const m = s.orZero(s.resolveSidesOpt(cs.margin, avail_w.toOption())).horizontal();
            const w = ck.width orelse e.computeSize(child, .{ .width = null, .height = ck.height }, none, .{
                .width = avail_w.sub(m),
                .height = .max_content,
            }, .inherent_size).width;
            widest = @max(widest, w + m);
        }
        break :blk @max(s.clamp(widest + inset.horizontal(), min.width, max.width), pb_sum.width);
    };
    if (input.run_mode == .compute_size) {
        if (known.height) |h| return .{ .width = outer_w, .height = h };
    }

    const perform = input.run_mode == .perform_layout;
    const inner_w = outer_w - inset.horizontal();
    const inner_h = s.subOpt(known.height, inset.vertical());
    const child_parent: Dims(?f32) = .{ .width = inner_w, .height = inner_h };

    // In-flow children.
    var y = inset.top;
    var pending_margin: f32 = 0;
    for (e.children(id)) |child| {
        const cs = &e.node(child).style;
        if (cs.display == .none) {
            if (perform) e.hideSubtree(child);
            continue;
        }
        if (cs.position == .absolute) {
            // Remember the static position; it is consumed after the container size is known.
            if (perform) e.node(child).layout.location = .{ .x = inset.left, .y = y + pending_margin };
            continue;
        }
        const margin = s.resolveSidesOpt(cs.margin, inner_w);
        const nam = s.orZero(margin);
        const r = cs.aspect_ratio;
        const c_min = s.applyAspectRatio(s.resolveDims(cs.min_size, child_parent), r);
        const c_max = s.applyAspectRatio(s.resolveDims(cs.max_size, child_parent), r);
        const c_size = s.applyAspectRatio(s.resolveDims(cs.size, child_parent), r);
        const ck: Dims(?f32) = .{
            .width = s.clamp(c_size.width orelse inner_w - nam.horizontal(), c_min.width, c_max.width),
            .height = s.clampOpt(c_size.height, c_min.height, c_max.height),
        };
        const avail: Dims(AvailableSpace) = .{
            .width = .{ .definite = inner_w - nam.horizontal() },
            .height = if (inner_h) |h| .{ .definite = h - nam.vertical() } else .max_content,
        };
        const size = if (perform)
            e.performLayout(child, ck, child_parent, avail, .inherent_size)
        else
            e.computeSize(child, ck, child_parent, avail, .inherent_size);

        y += collapse(pending_margin, nam.top);
        if (perform) {
            const free_x = @max(inner_w - size.width - nam.horizontal(), 0);
            const autos: f32 = @floatFromInt(@as(u8, @intFromBool(margin.left == null)) + @intFromBool(margin.right == null));
            const auto_x = if (autos > 0) free_x / autos else 0;
            const left = margin.left orelse auto_x;
            const rel_x = cs.inset.left.resolve(inner_w) orelse if (cs.inset.right.resolve(inner_w)) |v| -v else 0;
            const rel_y = cs.inset.top.resolve(inner_h) orelse if (cs.inset.bottom.resolve(inner_h)) |v| -v else 0;
            e.setLayout(child, .{ .x = inset.left + left + rel_x, .y = y + rel_y }, size);
        }
        y += size.height;
        pending_margin = nam.bottom;
    }
    const content_h = y + pending_margin - inset.top;
    const outer_h = known.height orelse @max(s.clamp(content_h + inset.vertical(), min.height, max.height), pb_sum.height);
    const container: Size = .{ .width = outer_w, .height = outer_h };
    if (!perform) return container;

    for (e.children(id)) |child| {
        const cs = &e.node(child).style;
        if (cs.display == .none or cs.position != .absolute) continue;
        absolute.layoutChild(e, child, .{
            .size = .{ .width = outer_w, .height = outer_h },
            .border = s.resolveSidesLP(style.border, parent.width),
            .gutter = gutter,
            .inner_size = .{ .width = inner_w, .height = outer_h - inset.vertical() },
        }, .{ .point = e.node(child).layout.location });
    }
    return container;
}

/// Collapses two adjoining vertical margins (CSS 2.1 §8.3.1).
fn collapse(a: f32, b: f32) f32 {
    if (a >= 0 and b >= 0) return @max(a, b);
    if (a < 0 and b < 0) return @min(a, b);
    return a + b;
}
