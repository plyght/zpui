//! zeron transcript UI (the `zeron_ui_transcript` module) — port of zeron
//! `crates/ui/src/transcript.rs` + `rail.rs`.
//!
//! - `view`: `TranscriptView` (zpui entity; follows `AppState`'s selected
//!   chat or shows one `TranscriptStore`), plus fixture loaders;
//! - `rows`: the pure row model (block-granular rows, tool groups, parse
//!   wiring, gaps, diffing, formatting);
//! - `tools`: the tool-group accordion and chips; `diff_view`: inline diffs;
//! - `thought`: reasoning flattening; `file_icons`: polychrome file icons.
//!
//! Embedding: `TranscriptView.init(app_state, cx)`; set
//! `view.theme_provider` to the shell's theme getter, and `bottom_clearance`
//! / `content_width` / `top_inset` from the shell's layout.

pub const view = @import("view.zig");
pub const rows = @import("rows.zig");
pub const tools = @import("tools.zig");
pub const diff_view = @import("diff_view.zig");
pub const thought = @import("thought.zig");
pub const file_icons = @import("zeron_ui_markdown").file_icons;
pub const workspace_links = @import("workspace_links.zig");
pub const subagents = @import("subagents.zig");
pub const blobs = @import("blobs.zig");

pub const TranscriptView = view.TranscriptView;
pub const parseFixture = view.parseFixture;
pub const loadEntries = view.loadEntries;
pub const applyFrame = view.applyFrame;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("view_test.zig");
    _ = @import("wiring_test.zig"); // [wiring]
}
