//! zeron settings UI (port of `crates/ui/src/settings/`): the full-window
//! settings mode the shell mounts in place of sidebar + main.
//!
//! ```zig
//! const settings_ui = @import("../settings/root.zig");
//! const v = try cx.newWith(settings_ui.SettingsView, settings_ui.SettingsView.init, .{ state, fixtures_dir, io, window });
//! // event settings_ui.Close → unmount; theme/keymap changes apply live.
//! settings_ui.store.boot(app, io, appearance_override);   // at startup (main.zig)
//! ```
//!
//! - `view.zig`: `SettingsView` (nav, footer, page host, all listeners);
//! - `widgets.zig`: page scaffolding, switch, select trigger, option card;
//! - `select.zig`: dropdown + switch data (options, commit, flip);
//! - `store.zig`: SettingsStore access + live theme / keymap application;
//! - one file per page: general, appearance, notifications, voice,
//!   shortcuts, providers, devices, files, appshots, archived.

pub const view = @import("view.zig");
pub const store = @import("store.zig");
pub const widgets = @import("widgets.zig");
pub const select = @import("select.zig");

pub const SettingsView = view.SettingsView;
pub const Close = view.Close;
pub const Section = view.Section;

test {
    _ = @import("tests.zig");
    _ = @import("liquid_glass_tests.zig"); // [liquid-glass]
}
