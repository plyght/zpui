//! The right-pane Changes (diff) surface — port of zeron `changes.rs`.
//!
//! - `model`: pure scope/mode/labels, diff resolution, the line-granular row
//!   model, folds, sticky header logic;
//! - `store`: `ChangesStore` (`WatchCheckoutDiffs`, fixture feed);
//! - `rows`: row elements (file body, hunk header, unified/split lines);
//! - `highlight`: excerpt + full-document syntax highlighting per file;
//! - `pane`: `ChangesPane`, the entity view (toolbar + content).
//!
//! Hosting (shell right pane): `try cx.newWith(ChangesPane, ChangesPane.init,
//! .{app_state})`, then `div().child(pane)`; `ChangesPane.initCommit(state,
//! .{ .sha, .subject }, cx)` for a History row's per-commit tab. Tab chip:
//! `pane.read(cx).tabTitle()` / `.tabIcon()`.

pub const model = @import("model.zig");
pub const store = @import("store.zig");
pub const rows = @import("rows.zig");
pub const highlight = @import("highlight.zig");
pub const pane = @import("pane.zig");
pub const tabs = @import("tabs.zig");

pub const ChangesPane = pane.ChangesPane;
pub const ChangesStore = store.ChangesStore;
pub const CommitPin = pane.CommitPin;
pub const OpenFile = pane.OpenFile;
pub const DiscardRequested = pane.DiscardRequested;
pub const DiffScope = model.DiffScope;
pub const DiffMode = model.DiffMode;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("pane_test.zig");
}
