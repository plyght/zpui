//! The checkout's pull request badge — zeron `change_requests.rs`
//! (`pull_request_badge`, `pull_request_badge_preview`, `ChangeRequestTooltip`).
//!
//! `#N` in tabular mono digits with the PR glyph, tinted by state (open:
//! success, merged: code text, closed: danger) on the tone @0.08; hover
//! deepens to @0.16 with the full tone, a 350ms tooltip card says
//! `PR #N · Open` over the one-line title, and a click opens the PR in the
//! browser. The sidebar surface is 16px / 10px text, the composer's 20px / 11px.
//!
//! ```zig
//! const crb = @import("../components/change_request_badge.zig");
//! if (state.read(cx).change_requests.read(cx).forChat(chat)) |pr|
//!     row = row.child(crb.badge(.{ "chat-pr", ix }, pr, .sidebar, true, theme));
//! ```

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const theme_mod = @import("theme.zig");
const icon = @import("icon.zig");
const effects = @import("effects.zig");
const popover = @import("popover.zig");

const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = zt.Theme;
const Summary = engine.protocol.ChangeRequestSummary;
const cr = model.change_requests;

pub const Surface = cr.BadgeSurface;

/// `ChangeRequestBadgeTone::color`.
pub fn toneColor(tone: cr.BadgeTone, theme: *const Theme) zpui.Hsla {
    return switch (tone) {
        .open => theme.success,
        .merged => theme.code_text,
        .closed => theme.danger,
    };
}

/// `ChangeRequestTooltip`: owns its strings (it outlives the frame).
pub const Tooltip = struct {
    gpa: std.mem.Allocator,
    heading: []u8,
    title: []u8,
    tone: cr.BadgeTone,

    pub fn deinit(self: *Tooltip, _: *zpui.App) void {
        self.gpa.free(self.heading);
        self.gpa.free(self.title);
    }

    pub fn render(self: *Tooltip, _: *zpui.Window, cx: *zpui.Context(Tooltip)) zpui.AnyElement {
        const theme = theme_mod.get(cx);
        var card = div().maxW(px(320)).px(px(9)).py(px(7)).flex().flexCol().gap(px(3)).rounded(px(6))
            .border1().borderColor(theme.border_strong).bg(popover.surfaceBg(theme))
            .child(div().textSize(px(11)).fontWeight(500).textColor(toneColor(self.tone, theme)).child(self.heading))
            .child(div().minW0().truncate().whitespaceNowrap().textSize(px(11)).textColor(theme.text_muted).child(self.title));
        if (!theme.isFrost()) card = card.shadowMd();
        return zpui.intoAnyElement(effects.frosted(6, theme_mod.layout.menu_blur, card));
    }
};

const TipData = struct { summary: *const Summary };

fn buildTooltip(data: TipData, _: *zpui.Window, app: *zpui.App) zpui.Entity(Tooltip) {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const m = cr.BadgeModel.fromSummary(arena.allocator(), data.summary) catch @panic("OOM");
    return app.new(Tooltip, .{
        .gpa = app.gpa,
        .heading = std.fmt.allocPrint(app.gpa, "PR #{s} \u{00b7} {s}", .{ m.number, m.state_label }) catch @panic("OOM"),
        .title = app.gpa.dupe(u8, m.title) catch @panic("OOM"),
        .tone = m.tone,
    }) catch @panic("OOM");
}

const ClickListener = zpui.Listener(zpui.ClickEvent);

/// The click: open the PR in the browser (`cx.open_url`).
fn openListener(url: []const u8) ClickListener {
    const Gen = struct {
        fn call(ld: *const @FieldType(ClickListener, "data"), _: *const zpui.ClickEvent, _: ?*zpui.Window, app: *zpui.App) void {
            app.propagate_event = false;
            app.platform.vtable.openUrl(app.platform.ptr, ld.get([]const u8));
        }
    };
    var l: ClickListener = .{ .func = Gen.call };
    l.data.set(url);
    return l;
}

/// `render_pull_request_badge`. `interactive = false` is the drag-preview
/// variant (same geometry, no hover / tooltip / click). Strings are copied
/// into the frame; `summary` must outlive the frame.
pub fn badge(id: anytype, summary: *const Summary, surface: Surface, interactive: bool, theme: *const Theme) zpui.StatefulDiv {
    const a = zpui.window.arena_mod.frameAllocator();
    const m = cr.BadgeModel.fromSummary(a, summary) catch return div().id(id);
    const color = toneColor(m.tone, theme);
    const composer = surface == .composer;
    var b = div().id(id).h(px(if (composer) 20 else 16)).flexNone().flex().flexRow().itemsCenter()
        .gap(px(if (composer) 5 else 3)).px(px(if (composer) 7 else 4)).rounded(px(if (composer) 6 else 4))
        .bg(color.opacity(0.08)).textSize(px(if (composer) 11 else 10)).fontWeight(500).textColor(color.opacity(0.85));
    if (interactive) {
        const url = a.dupe(u8, summary.url) catch "";
        b = b.cursorPointer().hover(sb.bg(color.opacity(0.16)).textColor(color))
            .onClick(openListener(url))
            .tooltipWith(TipData{ .summary = summary }, buildTooltip)
            .tooltipShowDelay(350 * std.time.ns_per_ms);
    }
    // Monospace digits keep a stable tabular width as PR numbers change.
    return b.child(icon.of(.pull_request, if (composer) 11 else 10, color.opacity(0.85)).flexNone())
        .child(div().fontFamily(theme.font_mono).child(m.number));
}
