//! Message badges — port of zeron `badges.rs`.
//!
//! A feature stages context on the composer, folds it into the prompt as
//! plain text (review comments: `model.comments.withComments`), and
//! registers an extractor here. `split`
//! lifts that block back out of the sent message so the transcript draws a
//! pill instead of the bullets the agent reads. Pure (arena memory).
//!
//! ```zig
//! const s = try badges.split(arena, text);   // s.text, s.badges
//! column.child(badges.pill(.{ "badge", key }, &s.badges[0], theme));
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const assets = @import("zeron_assets");

const comments = @import("zeron_model").comments;

pub const MessageBadge = struct {
    icon: assets.Icon,
    label: []const u8,
    /// Empty means the label says everything and the pill carries no card.
    details: []const BadgeDetail = &.{},
};

/// One row of a hover card: location (`src/main.rs:42`), an optional tag
/// (`L`/`R` for a diff side) and the body.
pub const BadgeDetail = comments.BadgeDetail;

pub const Split = struct { text: []const u8, badges: []const MessageBadge };

/// Returns the text with a feature's block removed plus the pill replacing it.
pub const Extracted = struct { text: []const u8, badge: MessageBadge };
pub const Extractor = *const fn (Allocator, []const u8) Allocator.Error!?Extracted;

const extractors = [_]Extractor{commentBadge};

/// Each extractor sees what the previous ones left behind, so two features
/// can ride the same prompt.
pub fn split(a: Allocator, text: []const u8) Allocator.Error!Split {
    var rest = text;
    var out: std.ArrayList(MessageBadge) = .empty;
    for (extractors) |extract| if (try extract(a, rest)) |hit| {
        rest = hit.text;
        try out.append(a, hit.badge);
    };
    return .{ .text = rest, .badges = out.items };
}

/// The review-comment block (`comments::extract_badge`, model/comments.zig).
fn commentBadge(a: Allocator, text: []const u8) Allocator.Error!?Extracted {
    const hit = (try comments.extractBadge(a, text)) orelse return null;
    return .{ .text = hit.text, .badge = .{ .icon = .chat_round_line, .label = hit.badge.label, .details = hit.badge.details } };
}

// ---------------------------------------------------------------------------
// Rendering (`badges::render`, `BadgeCard`)
// ---------------------------------------------------------------------------

const div = zpui.div;
const px = zpui.px;
const Theme = zt.Theme;

/// The composer sizes its strip arithmetically, so this cannot be a measurement.
pub const badge_height: f32 = 24;
const pill_radius: f32 = 8;
const icon_size: f32 = 12;
const text_size: f32 = 12;
const card_width: f32 = 320;
const hover_delay_ns: u64 = 280 * std.time.ns_per_ms;

/// The pill; hovering a pill with details shows its card after 280ms.
/// `badge` must outlive the frame's tooltip (row arena memory).
pub fn pill(id: anytype, badge: *const MessageBadge, theme: *const Theme) zpui.StatefulDiv {
    var el = div().id(id).h(px(badge_height)).flex().flexRow().itemsCenter().gap(px(6)).px(px(8))
        .rounded(px(pill_radius)).bg(theme.ink(0.06)).textSize(px(text_size)).fontWeight(500)
        .textColor(theme.text_muted)
        .child(zpui.svg().source(badge.icon.path(), badge.icon.svg()).size(px(icon_size)).flexNone()
            .textColor(theme.text_muted.opacity(0.7)))
        .child(badge.label);
    if (badge.details.len > 0) el = el.tooltipWith(badge, BadgeCard.build).tooltipShowDelay(hover_delay_ns);
    return el;
}

pub const BadgeCard = struct {
    /// An owned copy: the row that rendered the pill may be rebuilt while
    /// the card is up.
    arena: std.heap.ArenaAllocator,
    details: []const BadgeDetail,

    pub fn build(badge: *const MessageBadge, _: *zpui.Window, cx: *zpui.App) zpui.Entity(BadgeCard) {
        var arena = std.heap.ArenaAllocator.init(cx.gpa);
        const a = arena.allocator();
        const details = a.alloc(BadgeDetail, badge.details.len) catch @panic("OOM");
        for (badge.details, details) |d, *o| o.* = .{
            .location = a.dupe(u8, d.location) catch @panic("OOM"),
            .tag = if (d.tag) |t| a.dupe(u8, t) catch @panic("OOM") else null,
            .body = a.dupe(u8, d.body) catch @panic("OOM"),
        };
        return cx.new(BadgeCard, .{ .arena = arena, .details = details }) catch @panic("OOM");
    }

    pub fn deinit(self: *BadgeCard) void {
        self.arena.deinit();
    }

    fn row(d: BadgeDetail, theme: *const Theme) zpui.Div {
        var meta = div().flex().flexRow().itemsCenter().gap(px(6)).fontFamily(theme.font_mono)
            .textSize(px(10)).textColor(theme.text_faint)
            .child(div().flex1().minW0().truncate().child(d.location));
        if (d.tag) |t| meta = meta.child(div().flexNone().px(px(4)).rounded(px(3)).bg(theme.ink(0.10)).child(t));
        return div().flex().flexRow().gap(px(8)).p(px(8)).rounded(px(6)).bg(theme.ink(0.05))
            .child(div().flexNone().w(px(2)).rounded(px(1)).bg(theme.solid.opacity(0.35)))
            .child(div().flex1().minW0().flex().flexCol().gap(px(4))
                .child(meta)
                .child(div().minW0().textSize(px(text_size)).lineHeight(px(16)).textColor(theme.text).child(d.body)));
    }

    pub fn render(self: *BadgeCard, window: *zpui.Window, cx: *zpui.Context(BadgeCard)) zpui.AnyElement {
        const theme = zpui.window.arena_mod.current().create(Theme, @import("view.zig").themeOf(cx.app).forPopup());
        // [native-popover] In a native tooltip window the material is the card.
        if (window.isNativePopover()) {
            var bare = div().overflowHidden().fontFamily(theme.font_sans).textSize(px(13)).textColor(theme.text)
                .w(px(card_width)).p(px(6)).flex().flexCol().gap(px(4));
            for (self.details) |d| bare = bare.child(row(d, theme));
            return zpui.intoAnyElement(bare);
        }
        // `popover::popover_card` (12px radius, 4px inset) at 320px.
        var card = div().border1().borderColor(theme.onGlassBorder(theme.border)).rounded(px(card_radius))
            .bg(popoverBg(theme)).overflowHidden().fontFamily(theme.font_sans).textSize(px(13)).textColor(theme.text)
            .w(px(card_width)).p(px(6)).flex().flexCol().gap(px(4));
        if (!theme.isFrost()) card = card.shadowLg();
        for (self.details) |d| card = card.child(row(d, theme));
        // `frosted` gives the card its own scene layer, so the bubble's text
        // never paints over it.
        return zpui.intoAnyElement(zpui.frosted(card_radius, zt.layout.menu_blur, card));
    }
};

const card_radius: f32 = 12;

/// `popover::surface_bg`.
fn popoverBg(theme: *const Theme) zpui.Hsla {
    if (theme.isFrost()) return theme.onGlass(if (theme.appearance.isDark()) theme.composerSidebarTint() else theme.glassOverlay());
    return theme.inputGlassBg();
}

// ---------------------------------------------------------------------------
// Tests (badges.rs / comments.rs)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a plain message carries no badges" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try split(arena.allocator(), "just a prompt");
    try testing.expectEqualStrings("just a prompt", s.text);
    try testing.expectEqual(@as(usize, 0), s.badges.len);
}

fn diffComment(path: []const u8, side: comments.CommentSide, line: u32, body: []const u8) comments.ReviewComment {
    return .{ .id = "c", .path = path, .line = line, .body = body, .source = .{ .diff = .{ .side = side } } };
}

test "a sent comment block becomes one pill with one row per comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const staged = [_]comments.ReviewComment{
        diffComment("src/main.rs", .new, 42, "early-return here"),
        diffComment("src/lib.rs", .old, 7, "why was this dropped?"),
    };
    const s = try split(a, try comments.withComments(a, "look", &staged));
    try testing.expectEqualStrings("look", s.text);
    try testing.expectEqual(@as(usize, 1), s.badges.len);
    try testing.expectEqualStrings("2 comments", s.badges[0].label);
    try testing.expectEqual(assets.Icon.chat_round_line, s.badges[0].icon);
    const d = s.badges[0].details;
    try testing.expectEqualStrings("src/main.rs:42", d[0].location);
    try testing.expectEqualStrings("R", d[0].tag.?);
    try testing.expectEqualStrings("early-return here", d[0].body);
    try testing.expectEqualStrings("src/lib.rs:7", d[1].location);
    try testing.expectEqualStrings("L", d[1].tag.?);
}

test "a comment-only send keeps its stand-in body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try split(a, try comments.withComments(a, "", &.{diffComment("a.rs", .new, 3, "fix")}));
    try testing.expectEqualStrings(comments.comment_only_text, s.text);
    try testing.expectEqualStrings("1 comment", s.badges[0].label);
}
