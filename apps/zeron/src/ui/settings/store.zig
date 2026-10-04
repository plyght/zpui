//! Settings plumbing for the settings UI: the `SettingsStore` accessors the
//! pages bind to, and the live side effects of a change — the theme global
//! (appearance, theme variants, accent, glass, wallpaper tint, fonts), the
//! rem size and the app keymap — so edits re-theme / rebind the whole app
//! instantly (zeron `appearance::set_*`, `shell::apply_keymap`).
//!
//! ```zig
//! const s = store.current(cx);                         // *const UiSettings (never null)
//! store.update(cx, .debounced, value, Mut.set);        // fn(ctx, *UiSettings, Allocator)
//! store.applyTheme(cx.app);                            // after any theme-subset change
//! store.applyKeymap(cx.app);                           // after keymap / send-behavior changes
//! ```
//!
//! Fixture mode (no data dir) runs on an in-memory store: everything stays
//! live, nothing is written (`settings_store.initMemory`).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");

const App = zpui.App;
const UiSettings = model.UiSettings;
const settings_store = model.settings_store;

pub const SavePolicy = settings_store.SavePolicy;

fn appOf(cx: anytype) *App {
    if (@TypeOf(cx) == *App) return cx;
    return cx.app;
}

var empty_defaults: UiSettings = .{};
var boot_io: ?std.Io = null;

/// Make sure a store exists (an in-memory one when nothing was loaded).
pub fn ensure(app: *App) void {
    if (app.hasGlobal(model.SettingsStore)) return;
    // An in-memory store never saves, so its `io` is never used.
    settings_store.initMemory(app, boot_io orelse undefined) catch {};
}

/// The live settings (defaults when no store could be installed).
pub fn current(cx: anytype) *const UiSettings {
    const app = appOf(cx);
    ensure(app);
    return settings_store.current(app) orelse &empty_defaults;
}

/// Mutate through the store (`mutate(ctx, *UiSettings, arena)`); redraws.
pub fn update(cx: anytype, policy: SavePolicy, ctx: anytype, comptime mutate: anytype) void {
    const app = appOf(cx);
    ensure(app);
    if (settings_store.update(app, policy, ctx, mutate)) app.refreshWindows();
}

/// The OS appearance as the window reports it (the platform's before any
/// window exists; light when unknown).
pub fn systemAppearance(app: *App) zt.Appearance {
    const native = blk: {
        for (app.windows.items) |w| if (w) |win| break :blk win.windowAppearance();
        break :blk app.platform.vtable.windowAppearance(app.platform.ptr);
    };
    return switch (native) {
        .dark, .vibrant_dark => .dark,
        .light, .vibrant_light => .light,
    };
}

/// The appearance the settings resolve to right now.
pub fn effectiveAppearance(app: *App) zt.Appearance {
    return current(app).theme.appearance.resolve(systemAppearance(app));
}

/// Build the UI theme for `appearance` from the settings' theme subset.
pub fn themeFor(s: *const UiSettings, appearance: zt.Appearance) zt.Theme {
    const t = s.theme;
    var theme = zt.Theme.forSelection(&zt.registry.builtin, .{
        .appearance = appearance,
        .variant_id = t.theme_selection.variantId(appearance),
        .accent = t.accent,
        .surface = t.surface,
        .wallpaper_color = t.effectiveWallpaperColor(s.newThreadComposerBackground != null),
    });
    theme.font_sans = t.ui_font_family.familyName();
    theme.font_mono = t.code_font_family.familyName();
    theme.font_terminal = t.terminal_font_family.familyName();
    theme.code_font_size = t.code_font_size;
    theme.terminal_font_size = t.terminal_font_size;
    if (t.ui_font_family == .system) theme.font_sans = zt.typography.system_sans;
    if (t.code_font_family == .system) theme.font_mono = zt.typography.system_mono;
    if (t.terminal_font_family == .system) theme.font_terminal = zt.typography.system_mono;
    return theme;
}

/// Install the theme the settings describe and redraw every window.
pub fn applyTheme(app: *App) void {
    const s = current(app);
    ui.theme.set(app, themeFor(s, effectiveAppearance(app)));
    const rem = s.theme.ui_font_size.normalized().pixels();
    for (app.windows.items) |w| if (w) |win| win.setRemSize(rem);
}

/// Re-apply the app keymap from the settings (shortcut edits, send key).
pub fn applyKeymap(app: *App) void {
    const s = current(app);
    actions.keymap.applyKeymap(app, &s.keymap, s.composerSendBehavior) catch {};
}

/// Startup: install an in-memory store when none was loaded (seeding its
/// appearance from a `--light/--dark` override: light reads as "System",
/// the reference machine's system appearance, dark as "Dark") and apply the
/// settings theme. An override never rewrites a persisted store; it only
/// forces the appearance of this run.
pub fn boot(app: *App, io: std.Io, override: ?zt.Appearance) void {
    boot_io = io;
    const had_store = app.hasGlobal(model.SettingsStore);
    ensure(app);
    if (!had_store) {
        const Set = struct {
            fn f(mode: zt.settings.AppearanceMode, s: *UiSettings, _: std.mem.Allocator) void {
                s.theme.appearance = mode;
            }
        };
        const mode: zt.settings.AppearanceMode = if ((override orelse .dark) == .dark) .dark else .system;
        _ = settings_store.update(app, .debounced, mode, Set.f);
        return applyTheme(app);
    }
    if (override) |a| {
        ui.theme.set(app, themeFor(current(app), a));
        return;
    }
    applyTheme(app);
}
