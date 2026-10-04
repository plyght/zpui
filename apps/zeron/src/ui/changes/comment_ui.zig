//! Shared inline review cards for diffs and file editors — port of zeron
//! `comment_ui.rs` (+ the editor overlay cards of `files/preview.rs`).
//!
//! - `adder`: the 16px solid `+` that opens a draft on a hovered line;
//! - `card`: a staged comment (chat icon, `path:line`, edit + remove revealed
//!   on hover, the body clipped to its analytic height);
//! - `draft`: the fixed-height composer card (input, Cancel, Comment/Save;
//!   Escape cancels);
//! - `editorCard` / `editorDraft`: the editor's floating popover variants.
//!
//! Views pass their own handlers (`fn(*T, …)`), so one renderer serves the
//! Changes pane and the file editor alike.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const zmodel = @import("zeron_model");
const input = @import("zeron_input");
const ui = @import("../components/root.zig");
const m = @import("model.zig");

const comments = zmodel.comments;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const AnyElement = zpui.AnyElement;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = zt.Theme;
const ReviewComment = comments.ReviewComment;

/// Align review controls with a centered document column while keeping the
/// card full width (`CommentContentColumn`).
pub const ContentColumn = struct { max_width: f32, gutter: f32 };

/// Editor overlay metrics (`files/preview.rs`).
pub const editor_card_width: f32 = 320;
pub const editor_card_margin: f32 = 8;
pub const editor_card_min_anchored_width: f32 = 220;
pub const editor_draft_height: f32 = 92;

fn stopDown(_: *const zpui.input.MouseDownEvent, _: *Window, cx: *zpui.App) void {
    cx.propagate_event = false;
}

/// `render_comment_adder`: `open(view, ctx, window, cx)` on click.
pub fn adder(comptime T: type, id: anytype, theme: *const Theme, cx: *Context(T), ctx: anytype, comptime open: fn (*T, @TypeOf(ctx), *Window, *Context(T)) void) zpui.StatefulDiv {
    const C = @TypeOf(ctx);
    const H = struct {
        fn click(view: *T, c: C, _: *const zpui.ClickEvent, window: *Window, vcx: *Context(T)) void {
            vcx.stopPropagation();
            open(view, c, window, vcx);
        }
    };
    return div().id(id).size(px(comments.comment_adder_size)).flex().itemsCenter().justifyCenter()
        .rounded(px(4)).bg(theme.solid).cursorPointer()
        .onMouseDown(.left, stopDown)
        .onClick(cx.listenerWith(ctx, H.click))
        .child(ui.icon.of(.plus, 11, theme.on_solid));
}

/// `positioned_adder`: the adder centered vertically at `left` over a row.
pub fn positioned(left: f32, el: anytype) zpui.Div {
    return div().absolute().left(px(left)).top(px(0)).hFull().flex().itemsCenter().child(el);
}

fn accentBar(color: zpui.Hsla) zpui.Div {
    return div().w(px(m.accent_bar_width)).hFull().flexNone().bg(color);
}

fn header(theme: *const Theme, location: []const u8) zpui.Div {
    return div().h(px(comments.card_header_height)).flexNone().flex().flexRow().itemsCenter().gap(px(6))
        .child(ui.icon.of(.chat_round_line, 12, theme.text_faint))
        .child(div().flex1().minW0().truncate().whitespaceNowrap().fontFamily(theme.font_mono).textSize(px(11))
        .textColor(theme.text_faint).child(location));
}

/// `render_comment_edit` (revealed on the card's group hover).
pub fn editButton(comptime T: type, comment_id: []const u8, group: []const u8, theme: *const Theme, cx: *Context(T), comptime edit: fn (*T, []const u8, *Window, *Context(T)) void) zpui.StatefulDiv {
    const H = struct {
        fn click(view: *T, id: []const u8, _: *const zpui.ClickEvent, window: *Window, vcx: *Context(T)) void {
            vcx.stopPropagation();
            edit(view, id, window, vcx);
        }
    };
    return div().id(zpui.fmt("cmt-edit-{s}", .{comment_id})).flexNone().size(px(16)).flex().itemsCenter().justifyCenter()
        .rounded(px(4)).cursorPointer().opacity(0).groupHover(group, sb.opacity(1))
        .onMouseDown(.left, stopDown)
        .onClick(cx.listenerWith(comment_id, H.click))
        .tooltipWith(@as([]const u8, "Edit comment"), ui.tooltip.build)
        .child(ui.icon.of(.pen, 12, theme.text_muted));
}

fn removeButton(comptime T: type, id_prefix: []const u8, comment_id: []const u8, group: []const u8, theme: *const Theme, cx: *Context(T), comptime remove: fn (*T, []const u8, *Context(T)) void) zpui.StatefulDiv {
    const H = struct {
        fn click(view: *T, id: []const u8, _: *const zpui.ClickEvent, _: *Window, vcx: *Context(T)) void {
            remove(view, id, vcx);
        }
    };
    return div().id(zpui.fmt("{s}{s}", .{ id_prefix, comment_id })).flexNone().size(px(16)).flex().itemsCenter().justifyCenter()
        .rounded(px(4)).cursorPointer().opacity(0).groupHover(group, sb.opacity(1))
        .onClick(cx.listenerWith(comment_id, H.click))
        .tooltipWith(@as([]const u8, "Remove comment"), ui.tooltip.build)
        .child(ui.icon.of(.close_circle, 12, theme.text_muted));
}

fn body(theme: *const Theme, text: []const u8) zpui.Div {
    // Height is analytic, so an over-long body clips inside the card.
    return div().flex1().minH0().overflowHidden().textSize(px(12)).lineHeight(px(comments.card_line_height))
        .textColor(theme.text_dim).child(text);
}

/// `render_comment_card`: a staged comment inline in the diff.
pub fn card(
    comptime T: type,
    comment: *const ReviewComment,
    theme: *const Theme,
    cx: *Context(T),
    comptime edit: fn (*T, []const u8, *Window, *Context(T)) void,
    comptime remove: fn (*T, []const u8, *Context(T)) void,
    column: ?ContentColumn,
) zpui.Div {
    const a = zpui.window.arena_mod.frameAllocator();
    const id = a.dupe(u8, comment.id) catch comment.id;
    const group = zpui.fmt("cmt-card-{s}", .{id});
    const location = comment.location(a) catch "";
    var row = div().group(group).h(px(comments.cardHeight(comment.body))).wFull().flexNone().flex().flexRow()
        .bg(theme.ink(0.05));
    var bar = accentBar(theme.solid.opacity(0.35));
    if (column) |c| {
        row = row.relative().justifyCenter().px(px(c.gutter));
        bar = bar.absolute().left(px(0)).top(px(0));
    }
    var inner = div().flex1().minW0().flex().flexCol().px(px(zt.layout.space_lg));
    if (column) |c| inner = inner.maxW(px(c.max_width)).px(px(0));
    inner = inner.py(px(comments.card_pad_v / 2))
        .child(header(theme, location)
        .child(editButton(T, id, group, theme, cx, edit))
        .child(removeButton(T, "cmt-remove-", id, group, theme, cx, remove)))
        .child(body(theme, a.dupe(u8, comment.body) catch ""));
    return row.child(bar).child(inner);
}

/// `comment_action`: Cancel (ghost, hover blend) / Comment-Save (solid).
fn action(comptime T: type, id: []const u8, label: []const u8, primary: bool, theme: *const Theme, cx: *Context(T)) zpui.StatefulDiv {
    var b = div().id(id).h(px(22)).px(px(10)).flex().itemsCenter().rounded(px(6)).textSize(px(11)).fontWeight(500).cursorPointer();
    if (primary) return b.bg(theme.solid).textColor(theme.on_solid).child(label);
    const H = struct {
        fn hover(_: *T, key: []const u8, hovered: *const bool, _: *Window, vcx: *Context(T)) void {
            ui.hover.set(vcx, key, hovered.*);
        }
    };
    b = b.textColor(ui.hover.blend(cx, id, theme.text_muted, theme.text))
        .bg(ui.hover.blend(cx, id, zpui.color.transparent_black, theme.element_hover))
        .onHover(cx.listenerWith(id, H.hover));
    return b.child(label);
}

fn draftHandlers(comptime T: type, comptime cancel: fn (*T, *Context(T)) void, comptime commit: fn (*T, *Context(T)) void) type {
    return struct {
        fn key(view: *T, ev: *const zpui.input.KeyDownEvent, _: *Window, vcx: *Context(T)) void {
            if (std.mem.eql(u8, ev.keystroke.key, "escape")) {
                vcx.stopPropagation();
                cancel(view, vcx);
            }
        }
        fn onCancel(view: *T, _: *const zpui.ClickEvent, _: *Window, vcx: *Context(T)) void {
            cancel(view, vcx);
        }
        fn onCommit(view: *T, _: *const zpui.ClickEvent, _: *Window, vcx: *Context(T)) void {
            commit(view, vcx);
        }
    };
}

/// `render_comment_draft`: fixed height, so an open draft never fights the
/// fold tween.
pub fn draft(
    comptime T: type,
    cite_path: []const u8,
    line: u32,
    text_input: Entity(input.TextInput),
    editing: bool,
    theme: *const Theme,
    cx: *Context(T),
    comptime cancel: fn (*T, *Context(T)) void,
    comptime commit: fn (*T, *Context(T)) void,
    column: ?ContentColumn,
) zpui.Div {
    const H = draftHandlers(T, cancel, commit);
    var row = div().onMouseDown(.left, stopDown).onKeyDown(cx.listener(H.key))
        .h(px(comments.draft_card_height)).wFull().flexNone().flex().flexRow().bg(theme.ink(0.08));
    var bar = accentBar(theme.solid.opacity(0.7));
    if (column) |c| {
        row = row.relative().justifyCenter().px(px(c.gutter));
        bar = bar.absolute().left(px(0)).top(px(0));
    }
    var inner = div().flex1().minW0().flex().flexCol().px(px(zt.layout.space_lg));
    if (column) |c| inner = inner.maxW(px(c.max_width)).px(px(0));
    inner = inner.py(px(10))
        .child(header(theme, zpui.fmt("{s}:{d}", .{ cite_path, line })))
        .child(div().h(px(46)).flexNone().overflowHidden().textSize(px(12)).child(text_input))
        .child(div().h(px(28)).flexNone().flex().flexRow().itemsCenter().justifyEnd().gap(px(6))
        .child(action(T, "cmt-cancel", "Cancel", false, theme, cx).onClick(cx.listener(H.onCancel)))
        .child(action(T, "cmt-commit", if (editing) "Save" else "Comment", true, theme, cx).onClick(cx.listener(H.onCommit))));
    return row.child(bar).child(inner);
}

// ---------------------------------------------------------------------------
// Editor overlays (`files/preview.rs`)
// ---------------------------------------------------------------------------

/// `editor_comment_overlay_top`: below the line, clamped into the viewport.
pub fn editorOverlayTop(row_top: f32, line_height: f32, viewport_height: f32, card_height: f32) f32 {
    return std.math.clamp(row_top + line_height, 0, @max(viewport_height - card_height, 0));
}

/// `editor_comment_overlay_horizontal`: anchored at the gutter when there is
/// room for a 220px card, else full width with margins.
pub fn editorOverlayHorizontal(gutter_width: f32, viewport_width: f32) struct { left: f32, width: f32 } {
    const anchored_left = @max(gutter_width - editor_card_margin, editor_card_margin);
    const anchored_width = @max(@min(viewport_width - anchored_left - editor_card_margin, editor_card_width), 0);
    if (anchored_width >= editor_card_min_anchored_width) return .{ .left = anchored_left, .width = anchored_width };
    return .{ .left = editor_card_margin, .width = @max(viewport_width - editor_card_margin * 2, 0) };
}

/// `render_editor_comment_card`: a frosted popover card under its line.
pub fn editorCard(
    comptime T: type,
    comment: *const ReviewComment,
    left: f32,
    width: f32,
    top: f32,
    base_theme: *const Theme,
    cx: *Context(T),
    comptime edit: fn (*T, []const u8, *Window, *Context(T)) void,
    comptime remove: fn (*T, []const u8, *Context(T)) void,
) AnyElement {
    const a = zpui.window.arena_mod.frameAllocator();
    const theme = zpui.window.arena_mod.current().create(Theme, base_theme.forPopup());
    const id = a.dupe(u8, comment.id) catch comment.id;
    const group = zpui.fmt("file-comment-card-{s}", .{id});
    const location = comment.location(a) catch "";
    const c = ui.popover.card(theme).p(px(0)).gap(px(0)).group(group).w(px(width)).h(px(comments.cardHeight(comment.body)))
        .flex().flexCol().fontFamily(theme.font_sans).px(px(zt.layout.space_lg)).py(px(comments.card_pad_v / 2))
        .child(header(theme, location)
        .child(editButton(T, id, group, theme, cx, edit))
        .child(removeButton(T, "file-comment-remove-", id, group, theme, cx, remove)))
        .child(body(theme, a.dupe(u8, comment.body) catch ""));
    return zpui.intoAnyElement(div().absolute().left(px(left)).top(px(top)).child(ui.popover.frostedCard(c)));
}

/// `render_editor_comment_draft`.
pub fn editorDraft(
    comptime T: type,
    text_input: Entity(input.TextInput),
    editing: bool,
    left: f32,
    width: f32,
    top: f32,
    base_theme: *const Theme,
    cx: *Context(T),
    comptime cancel: fn (*T, *Context(T)) void,
    comptime commit: fn (*T, *Context(T)) void,
) AnyElement {
    const theme = zpui.window.arena_mod.current().create(Theme, base_theme.forPopup());
    const H = draftHandlers(T, cancel, commit);
    const c = ui.popover.card(theme).p(px(0)).gap(px(0)).onKeyDown(cx.listener(H.key)).onMouseDown(.left, stopDown)
        .w(px(width)).h(px(editor_draft_height)).flex().flexCol().fontFamily(theme.font_sans).px(px(zt.layout.space_lg)).py(px(8))
        .child(div().h(px(48)).flexNone().overflowHidden().rounded(px(7)).border1().borderColor(theme.border)
        .bg(theme.inputGlassBg()).px(px(8)).py(px(5)).textSize(px(12)).child(text_input))
        .child(div().h(px(28)).flexNone().flex().flexRow().itemsCenter().justifyEnd().gap(px(6))
        .child(action(T, "file-comment-cancel", "Cancel", false, theme, cx).onClick(cx.listener(H.onCancel)))
        .child(action(T, "file-comment-commit", if (editing) "Save" else "Comment", true, theme, cx).onClick(cx.listener(H.onCommit))));
    return zpui.intoAnyElement(div().absolute().left(px(left)).top(px(top)).child(ui.popover.frostedCard(c)));
}

test "comment ui: editor overlay placement" {
    try std.testing.expectEqual(@as(f32, 30), editorOverlayTop(8, 22, 400, 100));
    try std.testing.expectEqual(@as(f32, 300), editorOverlayTop(390, 22, 400, 100));
    try std.testing.expectEqual(@as(f32, 0), editorOverlayTop(-50, 22, 400, 100));
    const wide = editorOverlayHorizontal(44, 800);
    try std.testing.expectEqual(@as(f32, 36), wide.left);
    try std.testing.expectEqual(@as(f32, 320), wide.width);
    const narrow = editorOverlayHorizontal(44, 250);
    try std.testing.expectEqual(@as(f32, 8), narrow.left);
    try std.testing.expectEqual(@as(f32, 234), narrow.width);
}
