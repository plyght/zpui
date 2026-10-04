//! The zeron Files surface (port of `crates/ui/src/files` + the shell's
//! `files_panel.rs`):
//!
//! - `protocol`: workspace file RPC shapes;
//! - `client`: `WorkspaceFiles`, the per-workspace service (engine RPCs or a
//!   local directory), change watching and git status.
//!
//! Hosting: `try cx.newWith(FilesPanel, FilesPanel.init, .{ files_client, .{} })`
//! and `div().child(panel)`; events: `FilesPanel.OpenFile{ .path }`, …

pub const protocol = @import("protocol.zig");
pub const client = @import("client.zig");
pub const model = @import("model.zig");
pub const decorations = @import("decorations.zig");
pub const icons = @import("icons.zig");
pub const search = @import("search.zig");
pub const panel = @import("panel.zig");

pub const FilesPanel = panel.FilesPanel;

pub const WorkspaceFiles = client.WorkspaceFiles;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("panel_test.zig");
}
