//! New-session pickers (zeron `pickers.rs`): project, device, checkout and
//! branch popovers mounted on the composer's chip rows.
//!
//! - `menu`: pure reducers (row stepping, ranked filtering, key classes,
//!   adaptive menu geometry) with the Rust tests;
//! - `pickers`: `Pickers` (state + popovers) and `PickerRow` (the chip-row
//!   views the composer mounts through `ComposerView.target_row/git_row`);
//! - `add_project`: the "New project" palette (devices → locations →
//!   folders → `createSpace`), with `paths` (folder-browser path helpers).

pub const menu = @import("menu.zig");
pub const pickers = @import("pickers.zig");
pub const paths = @import("paths.zig");
pub const add_project = @import("add_project.zig");

pub const Pickers = pickers.Pickers;
pub const PickerRow = pickers.PickerRow;
pub const Kind = pickers.Kind;
pub const AddProject = add_project.AddProject;

test {
    @import("std").testing.refAllDecls(@This());
}
