//! zeron's design system for the Zig client (the `zeron_theme` module).
//!
//! - `model`: source-neutral theme data (8-bit `Color`, `ThemeVariant`,
//!   accent roles, selection, validation, serde-compatible JSON);
//! - `derive` + `builtins` + `registry`: the 30 built-in variants, derived at
//!   comptime from seeds generated out of zeron's Rust sources
//!   (`scripts/gen_themes.py`);
//! - `theme`: the UI `Theme` (zpui `Hsla` semantic tokens, glass math, paint helpers);
//! - `colorspace`: OKLCH / HSL / WCAG helpers;
//! - `layout`, `typography`: numeric design tokens;
//! - `motion`: cubic-bezier easing, motion catalog, hover fades, reduced motion;
//! - `pulse`: the throttled 30/15 Hz redraw clock for loaders and cosmetic motion;
//! - `settings`: the theme subset of ui-settings.json;
//! - `wallpaper`: wallpaper-derived tints.
//!
//! ```
//! const zt = @import("zeron_theme");
//! const theme = zt.Theme.forSelection(&zt.registry.builtin, .{
//!     .appearance = .dark, .variant_id = settings.theme_selection.dark,
//!     .accent = settings.accent, .surface = settings.surface,
//! });
//! ```
//! - `vscode`: the VS Code / TextMate theme importer (`crates/theme/src/vscode.rs`);
//! - `library`: the durable custom theme library (`library.rs`), surfaced
//!   through `registry.active()`.

pub const model = @import("model.zig");
pub const derive = @import("derive.zig");
pub const builtins = @import("builtins.zig");
pub const registry = @import("registry.zig");
pub const colorspace = @import("colorspace.zig");
pub const theme = @import("theme.zig");
pub const layout = @import("layout.zig");
pub const typography = @import("typography.zig");
pub const motion = @import("motion.zig");
pub const pulse = @import("pulse.zig");
pub const settings = @import("settings.zig");
pub const wallpaper = @import("wallpaper.zig");
pub const vscode = @import("vscode.zig");
pub const library = @import("library.zig");

pub const Color = model.Color;
pub const Appearance = model.Appearance;
pub const ThemeVariant = model.ThemeVariant;
pub const ThemeSelection = model.ThemeSelection;
pub const AccentSelection = model.AccentSelection;
pub const AccentPreset = model.AccentPreset;
pub const SurfacePreference = model.SurfacePreference;
pub const SurfaceTreatment = model.SurfaceTreatment;
pub const Registry = model.Registry;
pub const Theme = theme.Theme;
pub const ThemeSettings = settings.ThemeSettings;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("parity_test.zig");
}
