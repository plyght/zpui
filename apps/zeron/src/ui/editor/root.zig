//! The zeron file editor (port of the gpui-component `Editor` zeron hosts in
//! `files/editor.rs` / `files/preview.rs`):
//!
//! - `buffer`: chunked rope for files of tens of MB;
//! - `core`: editing semantics (selection, undo/redo, motions, indent, IME,
//!   find / replace) — pure and unit-tested;
//! - `wrap`: display rows for soft wrap (monospace columns);
//! - `highlight`: tree-sitter spans per line with edit-shifting and
//!   background re-highlighting;
//! - `view`: `FileEditor`, the right-pane surface (breadcrumb toolbar,
//!   virtualized gutter + text, find bar, go-to-line, save / conflict UI).
//!
//! Hosting (shell right pane), like `ChangesPane`:
//! `try cx.newWith(FileEditor, FileEditor.init, .{ files_client, "src/main.rs", .{} })`,
//! then `div().child(editor)`; tab chip: `editor.read(cx).tabTitle()` /
//! `.tabIcon()` / `.hasUnsavedChanges()`.

pub const buffer = @import("buffer.zig");
pub const core = @import("core.zig");
pub const wrap = @import("wrap.zig");
pub const highlight = @import("highlight.zig");
pub const actions = @import("actions.zig");
pub const view = @import("view.zig");
pub const FileEditor = view.FileEditor;

pub const Buffer = buffer.Buffer;
pub const EditorCore = core.EditorCore;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("view_test.zig");
}
