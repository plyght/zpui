//! The composer's staged review-comment chip — zeron `Composer::render_comments_chip`
//! (a `badges::render` pill, "N comments", no hover card: the staged set is
//! already on screen in the changes pane). The chip row adds
//! `review_comments.stripHeight(count)` to the pill.

const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const chrome = @import("chrome.zig");

const div = zpui.div;
const px = zpui.px;
const Theme = zt.Theme;
const rc = model.review_comments;

/// Staged comments under the composer's current key.
pub fn count(state: zpui.Entity(model.AppState), key: []const u8, cx: anytype) usize {
    return state.read(cx).review_comments.read(cx).comments(key).len;
}

/// The chip row, or null with nothing staged.
pub fn render(n: usize, theme: *const Theme) ?zpui.Div {
    if (n == 0) return null;
    const label = if (n == 1) "1 comment" else zpui.fmt("{d} comments", .{n});
    return div().flexNone().flex().flexRow().px(px(rc.strip_pad_x)).pt(px(rc.strip_pad_top))
        .child(div().id("composer-comments").h(px(rc.badge_height)).flex().flexRow().itemsCenter().gap(px(6)).px(px(8))
        .rounded(px(8)).bg(theme.ink(0.06)).textSize(px(12)).fontWeight(500).textColor(theme.text_muted)
        .child(chrome.icon(.chat_round_line, 12, theme.text_muted.opacity(0.7)))
        .child(label));
}
