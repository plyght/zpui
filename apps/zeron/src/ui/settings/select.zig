//! Settings dropdowns and switches as data (zeron `widgets::select` +
//! `SelectState`, the page toggles): every select is a `SelectId` whose
//! options, current index and commit are computed here from the live
//! settings, so the view's listeners only carry `(id, index)`.
//!
//! ```zig
//! row.child(select.render(view, .dark_theme, theme, cx))     // trigger (+ open menu)
//! row.child(view.toggle(.compact_mode, s.transcriptCompactMode, true, theme, cx))
//! ```
//!
//! The menu is a frosted popover card right-aligned under the trigger
//! (6px gap, flips above when it does not fit), optional uppercase heading,
//! a scrolling list (≤ 320px card) with 12px edge fades, check on the
//! selected row, keyboard highlight (↑/↓/Home/End/Enter/Esc in the view).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const store = @import("store.zig");
const w = @import("widgets.zig");
const view_mod = @import("view.zig");

const SettingsView = view_mod.SettingsView;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;
const rems = ui.rems;
const Theme = ui.Theme;
const UiSettings = model.UiSettings;
const typography = zt.typography;
const protocol = engine.protocol;

pub const SelectId = enum(u8) {
    send_behavior,
    light_theme,
    dark_theme,
    surface,
    reduce_motion,
    ui_font,
    ui_size,
    terminal_font,
    terminal_size,
    code_font,
    code_size,
    autosave_delay,
    appshot_destination,
    provider_device,
    thread_naming,
    /// The expanded provider's update policy (`view.policy_harness`).
    update_policy,
};

/// `UPDATE_POLICIES`: (policy, menu label, explanation).
pub const update_policies = [_]struct { model.types.HarnessUpdatePolicy, []const u8, []const u8 }{
    .{ .notify, "Notify", "Install only when you choose Update." },
    .{ .@"auto-when-idle", "Auto when idle", "Install automatically after active runs finish." },
    .{ .off, "Off", "Don't check for new versions." },
};

pub fn policyIndex(p: model.types.HarnessUpdatePolicy) usize {
    for (update_policies, 0..) |e, i| if (e[0] == p) return i;
    return 0;
}

pub const Toggle = enum(u8) {
    compact_mode,
    compact_model_picker,
    escape_stops,
    match_wallpaper,
    pause_animations,
    desktop_notifications,
    agent_updates,
    background_only,
    sound,
    sound_completion,
    sound_input,
    sound_attention,
    dictation,
    files_autosave,
    files_word_wrap,
    files_show_all,
    appshots_enabled,
    appshot_sound,
};

pub fn hoverKey(id: SelectId) []const u8 {
    return switch (id) {
        inline else => |t| "settings-select-" ++ @tagName(t),
    };
}

pub const Option = struct {
    label: []const u8,
    leading: w.Leading = .none,
    detail: ?[]const u8 = null,
};

pub const Spec = struct {
    label: []const u8,
    options: []const Option,
    selected: usize,
    width: ?f32 = null,
    menu_width: ?f32 = null,
    mono: bool = false,
    heading: ?[]const u8 = null,
};

/// Pixel ladder behind the terminal and code size dropdowns.
pub const mono_sizes = [_]f32{ 10, 11, 12, 12.5, 13, 14, 15, 16, 18, 20 };
pub const autosave_delays = [_]u64{ 300, 600, 900, 1_500, 3_000 };
const ui_families = [_]typography.UiFontFamily{ .geist, .geist_mono, .system };
const mono_families = [_]typography.UiFontFamily{ .geist_mono, .system };

fn nearestMono(size: f32) usize {
    var best: usize = 0;
    for (mono_sizes, 0..) |s, i| if (@abs(s - size) < @abs(mono_sizes[best] - size)) {
        best = i;
    };
    return best;
}

fn formatPx(size: f32) []const u8 {
    if (@abs(size - @round(size)) < 0.001) return zpui.fmt("{d:.0} px", .{size});
    return zpui.fmt("{d:.1} px", .{size});
}

fn familyIx(list: []const typography.UiFontFamily, f: typography.UiFontFamily) usize {
    for (list, 0..) |x, i| if (std.meta.activeTag(x) == std.meta.activeTag(f)) return i;
    return 0;
}

fn appearanceOf(id: SelectId) zt.Appearance {
    return if (id == .light_theme) .light else .dark;
}

pub fn modSendLabel() []const u8 {
    return if (builtin.os.tag == .macos) "⌘ Enter" else "Ctrl Enter";
}

/// The options + selection for `id` right now (labels live in the frame arena).
pub fn spec(v: *SettingsView, id: SelectId, cx: anytype) Spec {
    const a = zpui.window.arena_mod.frameAllocator();
    const s = store.current(cx);
    const t = s.theme;
    var list: std.ArrayList(Option) = .empty;
    switch (id) {
        .send_behavior => {
            list.append(a, .{ .label = "Enter" }) catch {};
            list.append(a, .{ .label = modSendLabel() }) catch {};
            return .{ .label = "Send messages with", .options = list.items, .selected = @intFromBool(s.composerSendBehavior != .enter), .width = 128, .mono = true };
        },
        .light_theme, .dark_theme => {
            const ap = appearanceOf(id);
            const current_id = t.theme_selection.variantId(ap);
            var it = zt.registry.builtin.variantsFor(ap);
            var sel: usize = 0;
            const page_theme = ui.theme.get(cx);
            while (it.next()) |variant| {
                if (std.mem.eql(u8, variant.id, current_id)) sel = list.items.len;
                const sample = a.create(Theme) catch break;
                sample.* = zt.Theme.forSelection(&zt.registry.builtin, .{ .appearance = ap, .variant_id = variant.id, .surface = page_theme.surface_preference });
                list.append(a, .{ .label = variant.name, .leading = w.paletteOf(sample) }) catch {};
            }
            return .{
                .label = if (ap == .light) "Light theme" else "Dark theme",
                .options = list.items,
                .selected = sel,
                .width = 218,
                .menu_width = 260,
                .heading = if (ap == .light) "Light themes" else "Dark themes",
            };
        },
        .surface => {
            // [liquid-glass] "Liquid Glass" only where native glass exists; a stored
            // `.liquid` elsewhere shows (and renders) as Frosted.
            const offered = zt.SurfacePreference.offered(store.liquidSupported(cx));
            for (offered) |p| list.append(a, .{ .label = surfaceLabel(p) }) catch {};
            const shown: zt.SurfacePreference = if (t.surface == .liquid and offered.len == zt.SurfacePreference.all.len) .frosted else t.surface;
            const sel = std.mem.indexOfScalar(zt.SurfacePreference, offered, shown) orelse 0;
            return .{ .label = "Glass", .options = list.items, .selected = sel, .width = 148 };
        },
        .reduce_motion => {
            for (zt.motion.ReduceMotion.all) |r| list.append(a, .{ .label = r.label() }) catch {};
            const sel = std.mem.indexOfScalar(zt.motion.ReduceMotion, &zt.motion.ReduceMotion.all, t.reduce_motion) orelse 0;
            return .{ .label = "Reduce motion", .options = list.items, .selected = sel, .width = 128 };
        },
        .ui_font, .terminal_font, .code_font => {
            const fams: []const typography.UiFontFamily = if (id == .terminal_font) &mono_families else &ui_families;
            for (fams) |f| list.append(a, .{ .label = f.label() }) catch {};
            const cur = switch (id) {
                .ui_font => t.ui_font_family,
                .terminal_font => t.terminal_font_family,
                else => t.code_font_family,
            };
            return .{ .label = "Font", .options = list.items, .selected = familyIx(fams, cur), .width = 168 };
        },
        .ui_size => {
            for (typography.UiFontSize.all) |sz| list.append(a, .{ .label = zpui.fmt("{d} px", .{sz.px}) }) catch {};
            var sel: usize = 0;
            for (typography.UiFontSize.all, 0..) |sz, i| if (sz.px == t.ui_font_size.normalized().px) {
                sel = i;
            };
            return .{ .label = "Interface font size", .options = list.items, .selected = sel, .width = 128 };
        },
        .terminal_size, .code_size => {
            for (mono_sizes) |sz| list.append(a, .{ .label = formatPx(sz) }) catch {};
            const cur = if (id == .terminal_size) t.terminal_font_size else t.code_font_size;
            return .{ .label = "Font size", .options = list.items, .selected = nearestMono(cur), .width = 128 };
        },
        .autosave_delay => {
            var sel: usize = 0;
            for (autosave_delays, 0..) |d, i| {
                list.append(a, .{ .label = if (d >= 1000) zpui.fmt("{d} s", .{@as(f32, @floatFromInt(d)) / 1000.0}) else zpui.fmt("{d} ms", .{d}) }) catch {};
                if (d == s.filesAutosaveDelayMs) sel = i;
            }
            return .{ .label = "Autosave delay", .options = list.items, .selected = sel, .width = 112 };
        },
        .appshot_destination => {
            const all = [_]model.settings.AppshotDestination{ .automatic, .@"last-session", .@"new-session" };
            for (all) |d| list.append(a, .{ .label = d.label() }) catch {};
            const sel = std.mem.indexOfScalar(model.settings.AppshotDestination, &all, s.appshotDestination) orelse 0;
            return .{ .label = "Destination", .options = list.items, .selected = sel, .width = 148 };
        },
        .provider_device => {
            const ws = v.state.read(cx).workspace.read(cx);
            const pt = ui.theme.get(cx);
            for (ws.devices()) |*d| {
                const glyph: ui.icon.Icon = if (std.mem.eql(u8, d.platform, "macos") or std.mem.eql(u8, d.platform, "darwin")) .laptop else if (std.mem.eql(u8, d.platform, "ios") or std.mem.eql(u8, d.platform, "android")) .smartphone else .monitor;
                const local = if (ws.local_device_id) |l| std.mem.eql(u8, l, d.id) else false;
                list.append(a, .{ .label = v.deviceName(d), .leading = .{ .icon = .{ .icon = glyph, .color = pt.text_muted } }, .detail = if (local) "You" else null }) catch {};
            }
            if (list.items.len == 0) list.append(a, .{ .label = "This device", .leading = .{ .icon = .{ .icon = .laptop, .color = pt.text_muted } } }) catch {};
            return .{ .label = "Device", .options = list.items, .selected = 0, .menu_width = 260, .heading = "Devices" };
        },
        .update_policy => {
            for (update_policies) |e| list.append(a, .{ .label = e[1] }) catch {};
            const sel = if (v.policy_harness) |h| policyIndex(v.harnessPolicy(h, cx)) else 0;
            return .{ .label = "Update policy", .options = list.items, .selected = sel, .width = 136 };
        },
        .thread_naming => {
            list.append(a, .{ .label = "Session agent", .leading = .{ .icon = .{ .icon = .chat_round_line, .color = ui.theme.get(cx).text_muted } } }) catch {};
            return .{ .label = "Thread naming", .options = list.items, .selected = 0, .menu_width = 220 };
        },
    }
}

pub fn surfaceLabel(p: zt.SurfacePreference) []const u8 {
    return switch (p) {
        .theme_default => "Theme default",
        .frosted => "Frosted",
        .opaque_ => "Opaque",
        .liquid => "Liquid Glass", // [liquid-glass]
    };
}

pub fn optionCount(v: *SettingsView, id: SelectId, cx: anytype) usize {
    return spec(v, id, cx).options.len;
}

pub fn selectedIndex(v: *SettingsView, id: SelectId, cx: anytype) usize {
    return spec(v, id, cx).selected;
}

/// Apply option `ix` of `id`.
pub fn commit(v: *SettingsView, id: SelectId, ix: usize, cx: *Context(SettingsView)) void {
    const T = struct {
        fn send(i: usize, s: *UiSettings, _: std.mem.Allocator) void {
            s.composerSendBehavior = if (i == 0) .enter else .@"mod-enter";
        }
        fn light(vid: []const u8, s: *UiSettings, _: std.mem.Allocator) void {
            s.theme.theme_selection.light = vid;
        }
        fn dark(vid: []const u8, s: *UiSettings, _: std.mem.Allocator) void {
            s.theme.theme_selection.dark = vid;
        }
        fn surface(i: usize, s: *UiSettings, _: std.mem.Allocator) void {
            s.theme.surface = zt.SurfacePreference.all_with_liquid[i]; // [liquid-glass] `all` is its prefix
        }
        fn motion(i: usize, s: *UiSettings, _: std.mem.Allocator) void {
            s.theme.reduce_motion = zt.motion.ReduceMotion.all[i];
        }
        fn uiFont(i: usize, s: *UiSettings, _: std.mem.Allocator) void {
            s.theme.ui_font_family = ui_families[i];
        }
        fn termFont(i: usize, s: *UiSettings, _: std.mem.Allocator) void {
            s.theme.terminal_font_family = mono_families[i];
        }
        fn codeFont(i: usize, s: *UiSettings, _: std.mem.Allocator) void {
            s.theme.code_font_family = ui_families[i];
        }
        fn uiSize(i: usize, s: *UiSettings, _: std.mem.Allocator) void {
            s.theme.ui_font_size = typography.UiFontSize.all[i];
        }
        fn termSize(i: usize, s: *UiSettings, _: std.mem.Allocator) void {
            s.theme.terminal_font_size = mono_sizes[i];
        }
        fn codeSize(i: usize, s: *UiSettings, _: std.mem.Allocator) void {
            s.theme.code_font_size = mono_sizes[i];
        }
        fn delay(i: usize, s: *UiSettings, _: std.mem.Allocator) void {
            s.filesAutosaveDelayMs = autosave_delays[i];
        }
        fn destination(i: usize, s: *UiSettings, _: std.mem.Allocator) void {
            const all = [_]model.settings.AppshotDestination{ .automatic, .@"last-session", .@"new-session" };
            s.appshotDestination = all[i];
        }
    };
    switch (id) {
        .send_behavior => {
            store.update(cx, .immediate, ix, T.send);
            store.applyKeymap(cx.app);
        },
        .light_theme, .dark_theme => {
            const ap = appearanceOf(id);
            var it = zt.registry.builtin.variantsFor(ap);
            var i: usize = 0;
            while (it.next()) |variant| : (i += 1) if (i == ix) {
                if (ap == .light) store.update(cx, .debounced, variant.id, T.light) else store.update(cx, .debounced, variant.id, T.dark);
                break;
            };
            store.applyTheme(cx.app);
        },
        .surface => {
            if (ix >= zt.SurfacePreference.offered(store.liquidSupported(cx)).len) return; // [liquid-glass]
            store.update(cx, .debounced, ix, T.surface);
            store.applyTheme(cx.app);
        },
        .reduce_motion => if (ix < zt.motion.ReduceMotion.all.len) store.update(cx, .debounced, ix, T.motion),
        .ui_font => if (ix < ui_families.len) {
            store.update(cx, .debounced, ix, T.uiFont);
            store.applyTheme(cx.app);
        },
        .terminal_font => if (ix < mono_families.len) {
            store.update(cx, .debounced, ix, T.termFont);
            store.applyTheme(cx.app);
        },
        .code_font => if (ix < ui_families.len) {
            store.update(cx, .debounced, ix, T.codeFont);
            store.applyTheme(cx.app);
        },
        .ui_size => if (ix < typography.UiFontSize.all.len) {
            store.update(cx, .debounced, ix, T.uiSize);
            store.applyTheme(cx.app);
        },
        .terminal_size => if (ix < mono_sizes.len) {
            store.update(cx, .debounced, ix, T.termSize);
            store.applyTheme(cx.app);
        },
        .code_size => if (ix < mono_sizes.len) {
            store.update(cx, .debounced, ix, T.codeSize);
            store.applyTheme(cx.app);
        },
        .autosave_delay => if (ix < autosave_delays.len) store.update(cx, .debounced, ix, T.delay),
        .appshot_destination => if (ix < 3) store.update(cx, .debounced, ix, T.destination),
        .update_policy => if (v.policy_harness) |h| if (ix < update_policies.len) {
            v.setHarnessPolicy(h, update_policies[ix][0], cx);
        },
        .provider_device, .thread_naming => {},
    }
}

/// Flip a settings switch.
pub fn flip(v: *SettingsView, which: Toggle, cx: *Context(SettingsView)) void {
    const F = struct {
        fn f(t: Toggle, s: *UiSettings, _: std.mem.Allocator) void {
            switch (t) {
                .compact_mode => s.transcriptCompactMode = !s.transcriptCompactMode,
                .compact_model_picker => s.compactModelPicker = !s.compactModelPicker,
                .escape_stops => s.escapeStopsActiveAgent = !s.escapeStopsActiveAgent,
                .match_wallpaper => s.theme.wallpaper_theme_colors = !s.theme.wallpaper_theme_colors,
                .pause_animations => s.theme.pause_animations_in_background = !s.theme.pause_animations_in_background,
                .desktop_notifications => s.notificationsEnabled = !s.notificationsEnabled,
                .agent_updates => s.agentUpdateNotifications = !s.agentUpdateNotifications,
                .background_only => s.notificationsBackgroundOnly = !s.notificationsBackgroundOnly,
                .sound => s.soundEnabled = !s.soundEnabled,
                .sound_completion => s.soundCompletionEnabled = !s.soundCompletionEnabled,
                .sound_input => s.soundInputEnabled = !s.soundInputEnabled,
                .sound_attention => s.soundAttentionEnabled = !s.soundAttentionEnabled,
                .dictation => s.dictationEnabled = !s.dictationEnabled,
                .files_autosave => s.filesAutosaveEnabled = !s.filesAutosaveEnabled,
                .files_word_wrap => s.filesWordWrap = !s.filesWordWrap,
                .files_show_all => s.filesShowAll = !s.filesShowAll,
                .appshots_enabled => s.appshotsEnabled = !s.appshotsEnabled,
                .appshot_sound => s.appshotSoundEnabled = !s.appshotSoundEnabled,
            }
        }
    };
    _ = v;
    const immediate = which == .dictation or which == .escape_stops;
    store.update(cx, if (immediate) .immediate else .debounced, which, F.f);
    if (which == .match_wallpaper) store.applyTheme(cx.app);
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// The trigger for `id` (+ its floating menu while open).
pub fn render(v: *SettingsView, id: SelectId, t: *const Theme, cx: *Context(SettingsView)) zpui.StatefulDiv {
    const sp = spec(v, id, cx);
    const open = v.open_select == id;
    const key = hoverKey(id);
    const fill = if (open) w.selectFill(t, true) else ui.hover.blend(cx, key, w.selectFill(t, false), w.selectFill(t, true));
    const current: ?Option = if (sp.selected < sp.options.len) sp.options[sp.selected] else null;
    var trigger = w.selectTrigger(t, fill).id(.{ "settings-select", @intFromEnum(id) })
        .onHover(cx.listenerWith(id, SettingsView.onSelectHover))
        .onClick(cx.listenerWith(id, SettingsView.onSelectTrigger));
    if (sp.width) |wd| trigger = trigger.w(px(wd));
    if (sp.mono) trigger = trigger.fontFamily(t.font_mono);
    if (current) |c| if (c.leading.element()) |el| {
        trigger = trigger.child(el);
    };
    trigger = trigger.child(div().flex1().minW0().truncate().child(if (current) |c| c.label else ""))
        .child(w.selectChevron(t, open));
    if (open) trigger = trigger.child(menu(v, sp, t, cx));
    return trigger;
}

/// The open menu for `id`, for custom triggers (mount inside a `relative` trigger).
pub fn menuFor(v: *SettingsView, id: SelectId, t: *const Theme, cx: *Context(SettingsView)) zpui.Div {
    return menu(v, spec(v, id, cx), t, cx);
}

fn menu(v: *SettingsView, sp: Spec, t: *const Theme, cx: *Context(SettingsView)) zpui.Div {
    const menu_w = @max(sp.menu_width orelse sp.width orelse 0, w.select_menu_min_width);
    var card = ui.popover.card(t).w(px(menu_w)).maxH(px(320)).onMouseDownOut(cx.listener(SettingsView.onSelectOutside));
    if (sp.mono) card = card.fontFamily(t.font_mono);
    if (sp.heading) |h| card = card.child(w.menuHeading(t, h));
    var rows = div().id("settings-select-list").maxH(px(listHeight(sp.heading != null))).overflowYScroll().trackScroll(v.menu_scroll)
        .flex().flexCol().gap(px(2));
    for (sp.options, 0..) |o, ix| {
        const active = ix == sp.selected or ix == v.highlighted;
        var row = ui.popover.menuRow(t, active).id(.{ "settings-select-option", ix })
            .onClick(cx.listenerWith(ix, SettingsView.onSelectOption));
        if (o.leading.element()) |el| row = row.child(el);
        row = row.child(div().flex1().minW0().truncate().child(o.label));
        if (o.detail) |d| row = row.child(div().flexNone().textSize(rems(10.5)).textColor(t.text_muted).child(d));
        rows = rows.child(row.child(w.selectCheck(t, ix == sp.selected)));
    }
    card = card.child(ui.effects.edgeFaded(rows, .{ .band = 12, .top = true, .bottom = true, .scroll = v.menu_scroll }));
    return div().absolute().top(zpui.relative(1)).right(px(0)).child(zpui.deferred(
        zpui.anchored().anchorCorner(.top_right).snapToWindowWithMargin(.all(8))
            .child(ui.anim.menuIn("settings-select-menu", div().occlude().pt(px(6)).child(ui.popover.frostedCard(card)), -2)),
    ).withPriority(1));
}

/// `dropdown_list_height` at the reference window (card ≤ 320px).
fn listHeight(heading: bool) f32 {
    return 320 - @as(f32, if (heading) 32 else 8);
}
