//! Composer constants and pure decision logic — ports of the top of zeron
//! `crates/ui/src/composer.rs` (pill geometry, compact ↔ expanded flip with
//! hysteresis, auto-grow height, send-button mode, attachment strip height,
//! the flip morph and its anchoring helpers).

const std = @import("std");
const zt = @import("zeron_theme");
const motion = zt.motion;

/// Expanded textarea vertical padding: `pt-4 pb-1` = 16 + 4.
pub const textarea_pad_v: f32 = 20;
/// The expanded textarea box clamps to 76–260 (the original's auto-grow).
pub const textarea_min: f32 = 76;
pub const textarea_max: f32 = 260;
/// Expanded actions row: 2px top + 32px picker + 8px bottom.
pub const actions_bottom_pad: f32 = 8;
pub const actions_row_height: f32 = 2.0 + 32.0 + actions_bottom_pad;
/// The pill's 1px hairline, top + bottom.
pub const pill_border_v: f32 = 2;
/// Corner radius shared by the composer and the queue tray behind it.
pub const composer_radius: f32 = 26;
pub const composer_min_height: f32 = textarea_min + actions_row_height + pill_border_v;
pub const composer_max_height: f32 = textarea_max + actions_row_height + pill_border_v;
/// Compact pill, border-box: `py-3` (24) + one 22.75px line + hairline = 49.
pub const compact_total_height: f32 = 49;
/// `max-w-3xl`: outer width of the new-chat composer.
pub const composer_max_width: f32 = 768;
/// The queue reads as a narrower tray emerging from behind the composer.
pub const queue_side_inset: f32 = 16;
/// The composer covers the tray's lower padding.
pub const queue_composer_overlap: f32 = 18;
pub const new_thread_selector_row_height: f32 = 20;
pub const session_footer_height: f32 = 24;
/// Below this pill input width the composer always expands.
pub const min_compact_input_width: f32 = 200;
pub const input_line_height: f32 = 22.75;
pub const input_text_size: f32 = 14;
pub const input_fade_band: f32 = 12;
/// Expanded→compact collapses only this far below the compact capacity.
pub const collapse_hysteresis: f32 = 32;
pub const resize_settle_ms: u64 = 150;
pub const caret_blink_ms: u64 = 500;

/// Staged-attachment strip (`flex flex-wrap gap-2 px-4 pt-3`, `size-14`).
pub const strip_thumb: f32 = 56;
pub const strip_gap: f32 = 8;
pub const strip_pad_top: f32 = 12;
pub const strip_pad_x: f32 = 16;

/// Send / attach center sits 25px above the expanded pill's bottom versus
/// 24.5px in compact; the morph glides the delta.
pub const cluster_y_delta: f32 = actions_bottom_pad + 16.0 + pill_border_v / 2.0 - compact_total_height / 2.0;
/// Attachment and Send share an outer inset: compact 8px, expanded 12px.
pub const cluster_x_delta: f32 = 4;
pub const action_utility_gap: f32 = 2;
pub const action_primary_gap: f32 = zt.layout.space_sm;
/// Circular action buttons (attach, mic, send) are `size-7`.
pub const action_button_size: f32 = 28;
/// Model chip: `h-8 rounded-lg px-1.5 gap-1.5 text-[12px] font-medium`.
pub const model_chip_height: f32 = 32;
pub const model_chip_max_width: f32 = 248;
pub const model_popover_width: f32 = 304;

/// Compact ↔ expanded flip with hysteresis (`composer_flip`).
pub fn composerFlip(expanded: bool, text_width: f32, capacity: f32, has_newline: bool, resizing: bool) bool {
    if (has_newline) return true;
    if (capacity < min_compact_input_width) return true;
    if (expanded) return resizing or text_width >= capacity - collapse_hysteresis;
    return text_width > capacity;
}

/// Auto-grow content height for a wrapped-line count.
pub fn inputContentHeight(wrapped_lines: usize) f32 {
    return @as(f32, @floatFromInt(@max(wrapped_lines, 1))) * input_line_height;
}

/// Total expanded composer height (border-box) for a content height: 120–304.
pub fn composerTotalHeight(content_height: f32) f32 {
    return std.math.clamp(content_height + textarea_pad_v, textarea_min, textarea_max) + actions_row_height + pill_border_v;
}

/// Height the wrap strip adds for `count` thumbnails at `inner_width`.
pub fn attachmentStripHeight(count: usize, inner_width: f32) f32 {
    if (count == 0) return 0;
    const usable = @max(inner_width - 2.0 * strip_pad_x, strip_thumb);
    const per_row: usize = @max(@as(usize, @intFromFloat(@floor((usable + strip_gap) / (strip_thumb + strip_gap)))), 1);
    const rows = (count + per_row - 1) / per_row;
    const r: f32 = @floatFromInt(rows);
    return strip_pad_top + r * strip_thumb + (r - 1) * strip_gap;
}

pub const SendButtonMode = enum {
    /// No live run: plain send.
    send,
    /// Live run with content: queue for the next turn.
    queue,
    /// Live run, nothing typed: stop square.
    stop,
};

pub fn sendButtonMode(run_live: bool, has_content: bool) SendButtonMode {
    if (!run_live) return .send;
    return if (has_content) .queue else .stop;
}

/// What the composer holds that a send could carry.
pub fn composerHasContent(text: []const u8, attachments: usize, comments: usize) bool {
    return std.mem.trim(u8, text, " \t\r\n").len > 0 or attachments > 0 or comments > 0;
}

/// Cmd/Ctrl+Enter: submit content, or with an empty composer activate the
/// latest queued row.
pub const ModifiedSubmitTarget = enum { submit_content, activate_latest_queued };

pub fn modifiedSubmitTarget(has_content: bool) ModifiedSubmitTarget {
    return if (has_content) .submit_content else .activate_latest_queued;
}

/// The shared outer inset during a morph (compact 8 ↔ expanded 12).
pub fn morphClusterInset(expanded: bool, progress: f32) f32 {
    const from: f32, const to: f32 = if (expanded) .{ 8, 8 + cluster_x_delta } else .{ 8 + cluster_x_delta, 8 };
    return lerp(from, to, progress);
}

/// Expanded text top padding across the morph (12 → 16).
pub fn morphTextPad(progress: f32) f32 {
    return lerp(12, 16, progress);
}

/// Collapse-morph text glide (decaying offset).
pub fn collapseTextGlide(from: f32, progress: f32) f32 {
    return @max(from - 53.0, 0) * (1.0 - progress);
}

/// The decaying cluster y offset for an in-flight morph.
pub fn morphClusterDy(progress: f32) f32 {
    return cluster_y_delta * (1.0 - progress);
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// One committed compact ↔ expanded flip animates the pill's height (180 ms
/// ease-out `COLLAPSE`); reduced motion snaps.
pub const FlipMorph = struct {
    from: f32,
    start_ms: f32,
    spec: motion.MotionSpec = motion.collapse,

    fn raw(self: FlipMorph, now_ms: f32) f32 {
        const total: f32 = @floatFromInt(self.spec.totalMs());
        return std.math.clamp((now_ms - self.start_ms) / total, 0, 1);
    }

    pub fn progress(self: FlipMorph, now_ms: f32) f32 {
        return self.spec.progress(self.raw(now_ms));
    }

    pub fn done(self: FlipMorph, now_ms: f32) bool {
        return self.raw(now_ms) >= 1.0;
    }

    /// Eased lerp from the flip-time height to the live target.
    pub fn height(self: FlipMorph, target: f32, now_ms: f32) f32 {
        return lerp(self.from, target, self.progress(now_ms));
    }
};

/// Advance the flip morph across one render pass (`flip_morph_step`).
pub fn flipMorphStep(morph: ?FlipMorph, mode_changed: bool, last_height: f32, now_ms: f32, reduced_motion: bool, route_snap: bool) ?FlipMorph {
    if (route_snap or reduced_motion) return null;
    if (!mode_changed) {
        const m = morph orelse return null;
        return if (m.done(now_ms)) null else m;
    }
    if (last_height <= 0) return null;
    return .{ .from = last_height, .start_ms = now_ms };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "flip hysteresis matches composer_flip" {
    try testing.expect(composerFlip(false, 10, 400, true, false)); // newline
    try testing.expect(composerFlip(false, 10, 150, false, false)); // too narrow
    try testing.expect(!composerFlip(false, 399, 400, false, false));
    try testing.expect(composerFlip(false, 401, 400, false, false));
    // Expanded stays expanded until comfortably narrower.
    try testing.expect(composerFlip(true, 380, 400, false, false));
    try testing.expect(!composerFlip(true, 360, 400, false, false));
    try testing.expect(composerFlip(true, 10, 400, false, true)); // resizing
}

test "heights and strips" {
    try testing.expectEqual(@as(f32, 120), composerTotalHeight(input_line_height));
    try testing.expectEqual(@as(f32, 120), composer_min_height);
    try testing.expectEqual(@as(f32, 304), composerTotalHeight(1000));
    try testing.expectEqual(@as(f32, 304), composer_max_height);
    try testing.expectApproxEqAbs(@as(f32, 3.0 * 22.75 + 20 + 44), composerTotalHeight(inputContentHeight(3)), 0.001);
    try testing.expectEqual(@as(f32, 0), attachmentStripHeight(0, 700));
    try testing.expectEqual(@as(f32, 68), attachmentStripHeight(3, 700));
    // 160 inner → 128 usable → 2 per row → 3 thumbs take 2 rows.
    try testing.expectEqual(@as(f32, 12 + 56 * 2 + 8), attachmentStripHeight(3, 160));
    try testing.expectEqual(@as(f32, 0.5), cluster_y_delta);
}

test "send mode and content" {
    try testing.expectEqual(SendButtonMode.send, sendButtonMode(false, false));
    try testing.expectEqual(SendButtonMode.queue, sendButtonMode(true, true));
    try testing.expectEqual(SendButtonMode.stop, sendButtonMode(true, false));
    try testing.expect(!composerHasContent("  \n", 0, 0));
    try testing.expect(composerHasContent(" x ", 0, 0));
    try testing.expect(composerHasContent("", 1, 0));
    try testing.expectEqual(ModifiedSubmitTarget.activate_latest_queued, modifiedSubmitTarget(false));
}

test "flip morph" {
    try testing.expect(flipMorphStep(null, true, 49, 0, true, false) == null);
    try testing.expect(flipMorphStep(null, true, 0, 0, false, false) == null);
    const m = flipMorphStep(null, true, 49, 1000, false, false).?;
    try testing.expectEqual(@as(f32, 49), m.height(120, 1000));
    try testing.expectEqual(@as(f32, 120), m.height(120, 1000 + 180));
    try testing.expect(flipMorphStep(m, false, 80, 1100, false, false) != null);
    try testing.expect(flipMorphStep(m, false, 80, 1200, false, false) == null);
    try testing.expectEqual(@as(f32, 12), morphClusterInset(true, 1));
    try testing.expectEqual(@as(f32, 8), morphClusterInset(false, 1));
    try testing.expectEqual(@as(f32, 16), morphTextPad(1));
}
