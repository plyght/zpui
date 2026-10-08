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
const builtin = @import("builtin");
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
    const reg = zt.registry.active(); // built-ins + the custom theme library
    var theme = zt.Theme.forSelection(&reg, .{
        .appearance = appearance,
        .variant_id = t.theme_selection.variantId(appearance),
        .accent = t.accent,
        .surface = t.surface,
        .wallpaper_color = t.effectiveWallpaperColor(s.newThreadComposerBackground != null),
    });
    // A family the device no longer has resolves to its fallback (`resolve_effective*`).
    const fonts = @import("fonts.zig");
    const ui_family = fonts.effective(.ui, t.ui_font_family);
    const code_family = fonts.effective(.code, t.code_font_family);
    const terminal_family = fonts.effective(.terminal, t.terminal_font_family);
    theme.font_sans = ui_family.familyName();
    theme.font_mono = code_family.familyName();
    theme.font_terminal = terminal_family.familyName();
    theme.code_font_size = t.code_font_size;
    theme.terminal_font_size = t.terminal_font_size;
    // The system font renders as itself (".SystemUIFont": SF Pro with its optical sizes on
    // macOS), as in Rust; `system_sans` (Helvetica) is only the fallback family.
    if (code_family == .system) theme.font_mono = zt.typography.system_mono;
    if (terminal_family == .system) theme.font_terminal = zt.typography.system_mono;
    return theme;
}

// ---- [liquid-glass] -------------------------------------------------------------------

/// Force the Liquid Glass preference for this run without persisting it
/// (`ZERON_LIQUID_GLASS=1`; set before `boot`). Unsupported machines fall back to frost.
pub var force_liquid: bool = false;

/// Native Liquid Glass can be shown here (macOS 26+; tests pretend yes).
pub fn liquidSupported(cx: anytype) bool {
    return zpui.platformSupportsLiquidGlass(appOf(cx));
}

/// [liquid-glass] `ZERON_LIQUID_GLASS=0`: keep "Theme default" frosted on macOS 26+.
pub var default_liquid_disabled: bool = false;

/// [liquid-glass] Whether "Theme default" means Liquid Glass: on a real macOS 26+
/// (never on the headless test platform, which only pretends to support glass, and
/// never on Linux / older macOS). Explicit Frosted / Opaque choices are respected.
pub fn defaultIsLiquid(app: *App) bool {
    return defaultLiquidPolicy(builtin.os.tag == .macos, app.test_platform == null, liquidSupported(app), default_liquid_disabled);
}

pub fn defaultLiquidPolicy(is_macos: bool, real_platform: bool, supported: bool, disabled: bool) bool {
    return is_macos and real_platform and supported and !disabled;
}

/// The UI theme with the Liquid Glass flag resolved against the platform.
pub fn themeWithGlass(app: *App, s: *const UiSettings, appearance: zt.Appearance) zt.Theme {
    var theme = themeFor(s, appearance);
    // [liquid-glass] "Theme default" resolves to Liquid Glass where it is native (only
    // for themes that recommend glass: `isLiquid` still requires the frosted treatment).
    if (s.theme.surface == .theme_default and !force_liquid and defaultIsLiquid(app)) {
        theme.liquid_glass = true;
        return theme;
    }
    const wants = force_liquid or s.theme.surface == .liquid;
    if (!wants) return theme;
    if (force_liquid and s.theme.surface != .liquid) {
        var forced = s.*;
        forced.theme.surface = .liquid;
        theme = themeFor(&forced, appearance);
    }
    theme.liquid_glass = liquidSupported(app);
    return theme;
}

/// Install the theme the settings describe and redraw every window.
pub fn applyTheme(app: *App) void {
    const s = current(app);
    ui.theme.set(app, themeWithGlass(app, s, effectiveAppearance(app))); // [liquid-glass] was themeFor
    const rem = effectiveUiFontSize(app, s).pixels();
    for (app.windows.items) |w| if (w) |win| win.setRemSize(rem);
    @import("motion.zig").applyAll(app); // reduce motion / pause in background
}

/// The interface base size that renders (`typography.effectiveUiFontSize`): 14 px for the
/// system font while the size was never chosen (`model.ui_font_size_choice`).
pub fn effectiveUiFontSize(app: *App, s: *const UiSettings) zt.typography.UiFontSize {
    const family = @import("fonts.zig").effective(.ui, s.theme.ui_font_family);
    return zt.typography.effectiveUiFontSize(s.theme.ui_font_size, family, model.ui_font_size_choice.current(app));
}

/// Re-apply the app keymap from the settings (shortcut edits, send key).
pub fn applyKeymap(app: *App) void {
    const s = current(app);
    actions.keymap.applyKeymap(app, &s.keymap, s.composerSendBehavior) catch {};
    // [lifecycle] menu key equivalents follow the bindings (rendered at setMenus time).
    if (app.lifecycle.menus.len > 0) @import("../../lifecycle/app_menus.zig").refresh(app);
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
        ui.theme.set(app, themeWithGlass(app, current(app), a)); // [liquid-glass] was themeFor
        return;
    }
    applyTheme(app);
}
