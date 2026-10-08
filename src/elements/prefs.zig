//! Preference-page building blocks that take each desktop's native look: write one
//! settings layout and get
//!   - GNOME / libadwaita: an `AdwPreferencesPage` — clamped column of
//!     `AdwPreferencesGroup`s (bold heading, dim description) over boxed lists (rounded
//!     cards of `AdwActionRow`s: title, subtitle, trailing control);
//!   - KDE Plasma / Breeze: a Kirigami `FormLayout` — centered form, right-aligned
//!     "Label:" column, controls in the second column, help text under the control,
//!     bold section headings;
//!   - macOS: a System Settings grouped inset form (rounded section boxes, title left,
//!     control right) — the controls stay real AppKit controls (`native*`).
//!
//! ```zig
//! const look = zpui.prefs.lookFor(window);
//! return zpui.prefs.page(window, look, &.{
//!     .{ .title = "Appearance", .rows = &.{
//!         zpui.prefs.row("Dark style", "Follow the system", zpui.nativeSwitch("dark", .{ .on = s.dark, .label = "Dark style" }, cx.listener(V.onDark), null)),
//!         zpui.prefs.row("Accent", "", zpui.nativePopup("accent", .{ .items = &accents, .selected = s.accent }, cx.listener(V.onAccent), null)),
//!     } },
//!     .{ .title = "Only show in these apps", .content = zpui.prefs.editableList(look, "apps", .{ .items = apps, .selected = s.sel }, cx.listener(V.onApps)) },
//! });
//! ```
//!
//! On Linux the window must opt in to drawn desktop controls
//! (`Window.setDesktopControls(true)`) for the `native*` controls inside to match;
//! `prefs.page` does not change that setting. Everything is built eagerly from the
//! given slices (they need only live for the call); strings must outlive the frame.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("../geometry.zig");
const platform = @import("../platform/platform.zig");
const style_mod = @import("../style.zig");
const StyleBuilder = @import("../style/builder.zig").StyleBuilder;
const App = @import("../app/app.zig").App;
const context = @import("../app/context.zig");
const Window = @import("../window/window.zig").Window;
const element = @import("../window/element.zig");
const arena_mod = @import("../window/arena.zig");
const events = @import("../window/events.zig");
const div_mod = @import("div.zig");
const dc = @import("desktop_controls.zig");
const theme = dc.theme;

const AnyElement = element.AnyElement;
const ElementId = element.ElementId;
const Pixels = geometry.Pixels;
const px = geometry.px;
const Hsla = theme.Hsla;
const BoxShadow = style_mod.BoxShadow;
const div = div_mod.div;
const Div = div_mod.Div;
const sb = StyleBuilder.init;
const ClickEvent = events.ClickEvent;

pub const Look = theme.Look;
pub const Family = theme.Family;

/// The page look for `window`: macOS System Settings on macOS, else the desktop the
/// drawn controls imitate (libadwaita when the platform names none).
pub fn lookFor(window: *Window) Look {
    const t = window.desktopTheme();
    // Platforms with real embedded controls (macOS AppKit, Windows common controls) use the
    // grouped-form layout around them.
    const family: Family = if ((builtin.os.tag == .macos or builtin.os.tag == .windows) and t.style == .none) .macos else Family.fromStyle(t.style) orelse .adwaita;
    return theme.look(family, dc.isDark(window, null), t.accent);
}

/// One preference row: title (+ subtitle) and a trailing control.
pub const Row = struct {
    title: []const u8 = "",
    subtitle: []const u8 = "",
    /// Leading icon / avatar (any element).
    icon: ?AnyElement = null,
    control: ?AnyElement = null,
};

/// `Row` from any element-like control (`nativeSwitch(...)`, a div, null).
pub fn row(title: []const u8, subtitle: []const u8, control: anytype) Row {
    return .{ .title = title, .subtitle = subtitle, .control = toAny(control) };
}

/// A group: heading, description, then rows (a boxed list / form section / grouped
/// box) or custom `content` (e.g. `editableList`, which brings its own frame).
pub const Group = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    rows: []const Row = &.{},
    content: ?AnyElement = null,
};

fn toAny(x: anytype) ?AnyElement {
    const X = @TypeOf(x);
    if (X == @TypeOf(null)) return null;
    if (X == ?AnyElement) return x;
    if (@typeInfo(X) == .optional) return if (x) |v| element.intoAnyElement(v) else null;
    return element.intoAnyElement(x);
}

fn black(a: f32) Hsla {
    return theme.rgbA(0x000006, a);
}

/// Card shadow of an Adwaita boxed list.
fn cardShadow(look: Look) []const BoxShadow {
    return if (look.dark) dc.shadows(&.{
        .{ .color = black(0.09), .offset = .{ .x = 0, .y = 0 }, .spread_radius = 1 },
        .{ .color = black(0.2), .offset = .{ .x = 0, .y = 1 }, .blur_radius = 3, .spread_radius = 1 },
        .{ .color = black(0.1), .offset = .{ .x = 0, .y = 2 }, .blur_radius = 6, .spread_radius = 2 },
    }) else dc.shadows(&.{
        .{ .color = black(0.03), .offset = .{ .x = 0, .y = 0 }, .spread_radius = 1 },
        .{ .color = black(0.07), .offset = .{ .x = 0, .y = 1 }, .blur_radius = 3, .spread_radius = 1 },
        .{ .color = black(0.03), .offset = .{ .x = 0, .y = 2 }, .blur_radius = 6, .spread_radius = 2 },
    });
}

/// The text column of a row: title and an optional dim subtitle.
fn titles(look: Look, title: []const u8, subtitle: []const u8) Div {
    var col = div().flex().flexCol().flex1().minW(px(0)).justifyCenter()
        .child(div().textColor(look.fg).child(title));
    if (subtitle.len > 0) col = col.child(div().textSize(px(look.small_font_size)).lineHeight(px(look.small_font_size + 4)).textColor(look.fg_dim).child(subtitle));
    return col;
}

/// Page root: font, text color and background of the family.
fn pageRoot(window: *Window, look: Look) Div {
    return div().flex().flexCol().wFull().fontFamily(dc.fontFamily(window, look)).textSize(px(look.font_size))
        .lineHeight(px(look.line_height)).textColor(look.fg);
}

/// A scrollable preferences page of `groups` (fills its parent).
pub fn page(window: *Window, look: Look, groups: []const Group) AnyElement {
    const body: AnyElement = switch (look.family) {
        .adwaita => adwaitaPage(window, look, groups),
        .breeze => breezePage(window, look, groups),
        .macos => macPage(window, look, groups),
    };
    return element.intoAnyElement(div().id("zpui-prefs-page").flex().flexCol().sizeFull().overflowYScroll().bg(look.window_bg)
        .child(body));
}

// ---- GNOME / libadwaita ----------------------------------------------------------------

fn adwaitaPage(window: *Window, look: Look, groups: []const Group) AnyElement {
    // AdwPreferencesPage: AdwClamp (max 600) with 24 px margins, groups 24 px apart.
    var col = pageRoot(window, look).maxW(px(600)).mxAuto().px(px(12)).pt(px(24)).pb(px(36)).gap(px(24));
    for (groups) |g| {
        var group = div().flex().flexCol().wFull();
        if (g.title.len > 0 or g.description.len > 0) {
            var head = div().flex().flexCol().gap(px(4)).pb(px(12)).px(px(2));
            if (g.title.len > 0) head = head.child(div().fontWeight(700).child(g.title));
            if (g.description.len > 0) head = head.child(div().textColor(look.fg_dim).child(g.description));
            group = group.child(head);
        }
        if (g.content) |c| group = group.child(c);
        if (g.rows.len > 0) group = group.child(boxedList(look, g.rows));
        col = col.child(group);
    }
    return element.intoAnyElement(col);
}

/// An Adwaita boxed list (`.boxed-list`) of `AdwActionRow`s.
pub fn boxedList(look: Look, rows: []const Row) Div {
    var list = div().flex().flexCol().wFull().rounded(px(look.card_radius)).bg(look.card_bg).shadow(cardShadow(look));
    for (rows, 0..) |r, i| {
        var item = div().flex().itemsCenter().gap(px(12)).minH(px(if (r.subtitle.len > 0) 58 else 50)).px(px(12)).py(px(8));
        if (i > 0) item = item.borderT1().borderColor(look.separator);
        if (r.icon) |ic| item = item.child(ic);
        item = item.child(titles(look, r.title, r.subtitle));
        if (r.control) |c| item = item.child(div().flex().flexNone().itemsCenter().child(c));
        list = list.child(item);
    }
    return list;
}

// ---- KDE Plasma / Breeze --------------------------------------------------------------

fn textWidth(window: *Window, look: Look, family: []const u8, text: []const u8, weight: f32) Pixels {
    if (text.len == 0) return 0;
    const runs = [_]@import("../text/types.zig").TextRun{.{ .len = text.len, .font = .{ .family = family, .weight = weight }, .color = look.fg }};
    const l = window.text_system.layoutLine(text, look.font_size, &runs, null) catch return @as(Pixels, @floatFromInt(text.len)) * look.font_size * 0.55;
    defer l.release();
    return l.layout.width;
}

fn breezePage(window: *Window, look: Look, groups: []const Group) AnyElement {
    // Kirigami FormLayout: one label column for the whole form, sized to the widest label.
    const family = dc.fontFamily(window, look);
    var label_w: Pixels = 0;
    for (groups) |g| for (g.rows) |r| {
        label_w = @max(label_w, textWidth(window, look, family, r.title, 400) + textWidth(window, look, family, ":", 400));
    };
    label_w = @ceil(label_w) + 2;
    const gap: Pixels = 12;
    // The form is centered as a whole; rows align on the shared label column.
    var form = div().flex().flexCol().itemsStart().gap(px(6));
    for (groups, 0..) |g, gi| {
        if (g.title.len > 0) {
            // Section heading: bold, slightly larger, spaced from the previous section.
            var head = div().flex().flexCol().wFull().itemsCenter().gap(px(2)).pb(px(6));
            if (gi > 0) head = head.pt(px(14));
            head = head.child(div().fontWeight(700).textSize(px(look.font_size * 1.15)).child(g.title));
            if (g.description.len > 0) head = head.child(div().textColor(look.fg_dim).textSize(px(look.small_font_size)).child(g.description));
            form = form.child(head);
        }
        for (g.rows) |r| {
            const label = if (r.title.len > 0) arena_mod.fmt("{s}:", .{r.title}) else "";
            var right = div().flex().flexCol().gap(px(2)).minW(px(0));
            var line = div().flex().itemsCenter().gap(px(8)).minH(px(look.control_height));
            if (r.icon) |ic| line = line.child(ic);
            if (r.control) |c| line = line.child(c);
            right = right.child(line);
            if (r.subtitle.len > 0) right = right.child(div().maxW(px(380)).textSize(px(look.small_font_size)).textColor(look.fg_dim).child(r.subtitle));
            form = form.child(div().flex().itemsStart().gap(px(gap))
                .child(div().flexNone().w(px(label_w)).h(px(look.control_height)).flex().itemsCenter().justifyEnd().whitespaceNowrap().child(label))
                .child(right));
        }
        if (g.content) |c| form = form.child(div().flex().gap(px(gap))
            .child(div().flexNone().w(px(label_w)))
            .child(div().w(px(380)).child(c)));
    }
    const col = pageRoot(window, look).px(px(24)).pt(px(18)).pb(px(30)).itemsCenter().child(form);
    return element.intoAnyElement(col);
}

// ---- macOS System Settings ------------------------------------------------------------

fn macPage(window: *Window, look: Look, groups: []const Group) AnyElement {
    var col = pageRoot(window, look).px(px(20)).pt(px(20)).pb(px(28)).gap(px(20));
    for (groups) |g| {
        var group = div().flex().flexCol().wFull().gap(px(6));
        if (g.title.len > 0 or g.description.len > 0) {
            var head = div().flex().flexCol().px(px(10)).gap(px(2));
            if (g.title.len > 0) head = head.child(div().fontWeight(600).child(g.title));
            if (g.description.len > 0) head = head.child(div().textSize(px(look.small_font_size)).textColor(look.fg_dim).child(g.description));
            group = group.child(head);
        }
        if (g.content) |c| group = group.child(c);
        if (g.rows.len > 0) {
            var box = div().flex().flexCol().wFull().rounded(px(look.card_radius)).bg(look.card_bg).border1().borderColor(look.outline).px(px(10));
            for (g.rows, 0..) |r, i| {
                var item = div().flex().itemsCenter().gap(px(10)).minH(px(if (r.subtitle.len > 0) 46 else 38)).py(px(6));
                if (i > 0) item = item.borderT1().borderColor(look.separator);
                if (r.icon) |ic| item = item.child(ic);
                item = item.child(titles(look, r.title, r.subtitle));
                if (r.control) |c| item = item.child(div().flex().flexNone().itemsCenter().child(c));
                box = box.child(item);
            }
            group = group.child(box);
        }
        col = col.child(group);
    }
    return element.intoAnyElement(col);
}

// ---- header bar -------------------------------------------------------------------------

/// A client-side title bar for a settings window: `AdwHeaderBar` (GNOME), a Breeze
/// (KWin) title bar (KDE), nothing on macOS (the system draws it). The close button
/// removes the window.
pub fn headerBar(window: *Window, look: Look, title: []const u8) AnyElement {
    const family = dc.fontFamily(window, look);
    switch (look.family) {
        .macos => return element.intoAnyElement(div()),
        .adwaita => {
            const bg = if (look.dark) theme.rgbA(0x2e2e32, 1) else theme.rgbA(0xffffff, 1);
            const shade = if (look.dark) black(0.36) else black(0.12);
            const btn_bg = if (look.dark) theme.rgbA(0xffffff, 0.1) else black(0.08);
            return element.intoAnyElement(div().id("zpui-headerbar").relative().flex().flexNone().itemsCenter().justifyCenter().wFull().h(px(47))
                .onMouseDown(.left, moveWindow)
                .bg(bg).borderB1().borderColor(shade).fontFamily(family).textSize(px(look.font_size)).textColor(look.fg)
                .child(div().fontWeight(700).child(title))
                .child(div().id("zpui-headerbar-close").absolute().right(px(12)).top(px(11.5)).w(px(24)).h(px(24)).roundedFull()
                .bg(btn_bg).hover(sb.bg(if (look.dark) theme.rgbA(0xffffff, 0.15) else black(0.12)))
                .flex().itemsCenter().justifyCenter().cursorPointer()
                .role(.button).ariaLabel("Close")
                .onClick(closeWindow)
                .child(dc.icon("zpui-close", dc.icons.close, 14, look.fg))));
        },
        .breeze => {
            // Breeze decoration: title bar in the header color, title centered, buttons right.
            const bg = if (look.dark) theme.rgbA(0x2a2e32, 1) else theme.rgbA(0xdee0e2, 1);
            return element.intoAnyElement(div().id("zpui-headerbar").relative().flex().flexNone().itemsCenter().justifyCenter().wFull().h(px(30))
                .onMouseDown(.left, moveWindow)
                .bg(bg).borderB1().borderColor(look.separator).fontFamily(family).textSize(px(look.font_size)).textColor(look.fg)
                .child(div().child(title))
                .child(div().id("zpui-headerbar-close").absolute().right(px(6)).top(px(6)).w(px(18)).h(px(18)).roundedFull()
                .hover(sb.bg(theme.rgbA(0xda4453, 1)).textColor(theme.rgbA(0xffffff, 1)))
                .flex().itemsCenter().justifyCenter().cursorPointer()
                .role(.button).ariaLabel("Close")
                .onClick(closeWindow)
                .child(dc.icon("zpui-close", dc.icons.close, 12, look.fg))));
        },
    }
}

/// Dragging the header bar moves the window (client-side decorations).
fn moveWindow(ev: *const @import("../input.zig").MouseDownEvent, window: *Window, _: *App) void {
    // The close button (right end) takes its own clicks.
    if (ev.position.x > window.viewportSize().width - 48) return;
    window.startWindowMove();
}

fn closeWindow(_: *const ClickEvent, window: *Window, _: *App) void {
    window.removeWindow();
}

// ---- editable list ----------------------------------------------------------------------

pub const ListItem = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    /// App icon (any element; drawn at the family's icon size).
    icon: ?AnyElement = null,
};

/// What the user did to an `editableList`.
pub const ListEvent = union(enum) {
    /// A row was selected (macOS / Breeze; GNOME rows are not selectable).
    select: u32,
    /// The + / "Add…" button.
    add,
    /// Remove this row (GNOME: its own remove button; elsewhere the selected row).
    remove: u32,
};

pub const ListListener = context.Listener(ListEvent);

pub const ListOptions = struct {
    items: []const ListItem,
    selected: ?u32 = null,
    /// GNOME's add row / Breeze's add button.
    add_label: []const u8 = "Add Application…",
    remove_label: []const u8 = "Remove",
    empty_text: []const u8 = "No Applications",
    /// Accessible name of the list.
    label: []const u8 = "",
};

const ListCap = extern struct { st: *ListState, kind: u32, index: u32 };

fn listClick(l: *ListState, ev: ListEvent) context.Listener(ClickEvent) {
    const Gen = struct {
        fn call(ld: *const context.ListenerData, _: *const ClickEvent, w: ?*Window, a: *App) void {
            const c = ld.get(ListCap);
            const e: ListEvent = switch (c.kind) {
                0 => .{ .select = c.index },
                1 => .add,
                else => .{ .remove = c.index },
            };
            const lis = c.st.listener orelse return;
            lis.callIn(&e, w orelse return, a);
        }
    };
    var ld: context.ListenerData = .{};
    ld.set(switch (ev) {
        .select => |i| ListCap{ .st = l, .kind = 0, .index = i },
        .add => ListCap{ .st = l, .kind = 1, .index = 0 },
        .remove => |i| ListCap{ .st = l, .kind = 2, .index = i },
    });
    return .{ .func = Gen.call, .data = ld };
}

/// A list of apps (icon + name) the user adds to and removes from: GNOME's boxed list
/// with per-row remove buttons and an "Add Application…" row; Breeze's framed list view
/// with Add / Remove buttons; macOS's bordered table with the +/− segmented buttons.
pub fn editableList(look: Look, id: anytype, opts: ListOptions, listener: anytype) AnyElement {
    return AnyElement.new(ListElement{ .d = arena_mod.current().create(ListData, .{
        .id = ElementId.from(id),
        .look = look,
        .opts = opts,
        .listener = ListListener.init(listener),
    }) });
}

/// Element state of an editable list: its listener, so row buttons can capture a stable
/// pointer (the frame arena is gone by the time events arrive).
const ListState = struct { listener: ?ListListener = null };

const ListData = struct {
    id: ElementId,
    look: Look,
    opts: ListOptions,
    listener: ListListener,
};

const ListElement = struct {
    d: *ListData,

    pub const RequestLayoutState = AnyElement;

    pub fn elementId(self: *ListElement) ?ElementId {
        return self.d.id;
    }

    pub fn requestLayout(self: *ListElement, gid: ?element.GlobalElementId, rl: *AnyElement, window: *Window, cx: *App) element.LayoutId {
        const d = self.d;
        const st = window.elementState(ListState, gid.?);
        st.listener = d.listener;
        const root = div().id("list").flex().flexCol().wFull().role(.list).ariaLabel(d.opts.label);
        const el = element.intoAnyElement(switch (d.look.family) {
            .adwaita => adwaitaList(d.look, root, d.opts, st),
            .breeze => breezeList(d.look, root, d.opts, st),
            .macos => macList(d.look, root, d.opts, st),
        });
        rl.* = el;
        return el.requestLayout(window, cx);
    }

    pub fn prepaint(_: *ListElement, _: ?element.GlobalElementId, _: geometry.Bounds(Pixels), rl: *AnyElement, _: *void, window: *Window, cx: *App) void {
        rl.prepaint(window, cx);
    }

    pub fn paint(_: *ListElement, _: ?element.GlobalElementId, _: geometry.Bounds(Pixels), rl: *AnyElement, _: *void, window: *Window, cx: *App) void {
        rl.paint(window, cx);
    }
};

const StatefulDiv = div_mod.StatefulDiv;

fn adwaitaList(look: Look, root: StatefulDiv, opts: ListOptions, l: *ListState) StatefulDiv {
    var card = div().flex().flexCol().wFull().rounded(px(look.card_radius)).bg(look.card_bg).shadow(cardShadow(look));
    const flat_hover = if (look.dark) theme.rgbA(0xffffff, 0.07) else black(0.07);
    for (opts.items, 0..) |it, ix| {
        const i: u32 = @intCast(ix);
        var item = div().id(.{ "item", ix }).flex().itemsCenter().gap(px(12)).minH(px(56)).px(px(12)).py(px(8))
            .role(.list_item).ariaLabel(it.title);
        if (ix > 0) item = item.borderT1().borderColor(look.separator);
        if (it.icon) |ic| item = item.child(div().flexNone().w(px(32)).h(px(32)).flex().itemsCenter().justifyCenter().child(ic));
        item = item.child(titles(look, it.title, it.subtitle))
            .child(div().id(.{ "remove", ix }).flexNone().w(px(34)).h(px(34)).roundedFull().flex().itemsCenter().justifyCenter()
            .cursorPointer().hover(sb.bg(flat_hover)).role(.button).ariaLabel(opts.remove_label)
            .onClick(listClick(l, .{ .remove = i }))
            .child(dc.icon("zpui-trash", dc.icons.trash, 16, look.fg)));
        card = card.child(item);
    }
    if (opts.items.len == 0) card = card.child(div().flex().itemsCenter().justifyCenter().minH(px(50)).textColor(look.fg_dim).child(opts.empty_text));
    // AdwButtonRow: a centered label with an icon.
    card = card.child(div().id("add").flex().itemsCenter().justifyCenter().gap(px(6)).minH(px(50)).borderT1().borderColor(look.separator)
        .roundedBl(px(look.card_radius)).roundedBr(px(look.card_radius))
        .cursorPointer().hover(sb.bg(flat_hover)).role(.button).ariaLabel(opts.add_label)
        .onClick(listClick(l, .add))
        .child(dc.icon("zpui-plus", dc.icons.plus, 16, look.fg))
        .child(div().fontWeight(600).child(opts.add_label)));
    return root.child(card);
}

fn breezeList(look: Look, root: StatefulDiv, opts: ListOptions, l: *ListState) StatefulDiv {
    var frame = div().flex().flexCol().wFull().minH(px(120)).bg(look.view_bg).border1().borderColor(look.outline).rounded(px(3)).p(px(2));
    for (opts.items, 0..) |it, ix| {
        const i: u32 = @intCast(ix);
        const sel = opts.selected == i;
        var item = div().id(.{ "item", ix }).flex().itemsCenter().gap(px(8)).h(px(32)).px(px(6)).rounded(px(3)).cursorPointer()
            .role(.list_item).ariaLabel(it.title).ariaSelected(sel)
            .onClick(listClick(l, .{ .select = i }));
        item = if (sel) item.bg(theme.mix(look.view_bg, look.accent, 0.3)).border1().borderColor(look.accent) else item.hover(sb.bg(theme.mix(look.view_bg, look.accent, 0.12)));
        if (it.icon) |ic| item = item.child(div().flexNone().w(px(22)).h(px(22)).flex().itemsCenter().justifyCenter().child(ic));
        frame = frame.child(item.child(div().child(it.title)));
    }
    if (opts.items.len == 0) frame = frame.child(div().flex().flex1().itemsCenter().justifyCenter().textColor(look.fg_dim).child(opts.empty_text));
    const buttons = div().flex().gap(px(6)).pt(px(6))
        .child(breezeButton(look, "add", opts.add_label, dc.icons.plus, "zpui-plus", true, listClick(l, .add)))
        .child(breezeButton(look, "remove", opts.remove_label, dc.icons.minus, "zpui-minus", opts.selected != null, listClick(l, .{ .remove = opts.selected orelse 0 })));
    return root.child(frame).child(buttons);
}

fn breezeButton(look: Look, id: []const u8, text: []const u8, icon_src: []const u8, icon_name: []const u8, enabled: bool, on_click: context.Listener(ClickEvent)) StatefulDiv {
    var b = div().id(id).flex().itemsCenter().gap(px(6)).h(px(look.control_height)).px(px(10)).rounded(px(look.button_radius))
        .bg(look.button_bg).border1().borderColor(look.outline).role(.button).ariaLabel(text).ariaDisabled(!enabled)
        .child(dc.icon(icon_name, icon_src, 16, look.fg))
        .child(div().child(text));
    if (enabled) b = b.cursorPointer().hover(sb.borderColor(look.accent)).active(sb.bg(look.button_active)).onClick(on_click) else b = b.opacity(look.disabled_opacity);
    return b;
}

fn macList(look: Look, root: StatefulDiv, opts: ListOptions, l: *ListState) StatefulDiv {
    var table = div().flex().flexCol().wFull().minH(px(120)).bg(look.view_bg).py(px(4));
    for (opts.items, 0..) |it, ix| {
        const i: u32 = @intCast(ix);
        const sel = opts.selected == i;
        var item = div().id(.{ "item", ix }).flex().itemsCenter().gap(px(6)).h(px(24)).mx(px(4)).px(px(6)).rounded(px(5))
            .role(.list_item).ariaLabel(it.title).ariaSelected(sel)
            .onClick(listClick(l, .{ .select = i }));
        if (sel) item = item.bg(look.accent).textColor(look.accent_fg);
        if (it.icon) |ic| item = item.child(div().flexNone().w(px(18)).h(px(18)).flex().itemsCenter().justifyCenter().child(ic));
        table = table.child(item.child(div().child(it.title)));
    }
    if (opts.items.len == 0) table = table.child(div().flex().flex1().itemsCenter().justifyCenter().textColor(look.fg_dim).child(opts.empty_text));
    // The +/− "gradient buttons" bar under the table.
    const bar_btn = struct {
        fn f(lk: Look, bid: []const u8, name: []const u8, src: []const u8, text: []const u8, enabled: bool, click: context.Listener(ClickEvent)) StatefulDiv {
            var b = div().id(bid).w(px(24)).h(px(22)).flex().itemsCenter().justifyCenter().borderR1().borderColor(lk.separator)
                .role(.button).ariaLabel(text).ariaDisabled(!enabled)
                .child(dc.icon(name, src, 12, lk.fg.alpha(if (enabled) lk.fg.a else lk.fg.a * 0.35)));
            if (enabled) b = b.active(sb.bg(lk.button_active)).onClick(click);
            return b;
        }
    }.f;
    const bar = div().flex().h(px(22)).borderT1().borderColor(look.separator).bg(look.card_bg)
        .child(bar_btn(look, "add", "zpui-plus", dc.icons.plus, opts.add_label, true, listClick(l, .add)))
        .child(bar_btn(look, "remove", "zpui-minus", dc.icons.minus, opts.remove_label, opts.selected != null, listClick(l, .{ .remove = opts.selected orelse 0 })));
    return root.rounded(px(6)).border1().borderColor(look.outline).overflowHidden().child(table).child(bar);
}

test "page look follows the desktop theme and pins" {
    const t = std.testing;
    const light = theme.look(.adwaita, false, null);
    try t.expectEqual(Family.adwaita, light.family);
    const kde = theme.look(.breeze, true, 0xff0000);
    try t.expect(kde.dark);
}
