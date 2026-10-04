//! The right-pane Git History surface — port of zeron `history.rs`.
//!
//! - `types`: `GitHistoryPage` / `GitHistoryCommit` / refs (+ params);
//! - `graph`: pure lane layout, folding, compaction, geometry, ref
//!   budgeting, formatting, fuzzy match, stroke tessellation;
//! - `store`: `HistoryStore` (`ListGitHistory` pages, `FetchAll`,
//!   `SearchGitHistory`, fixture feed);
//! - `pane`: `HistoryPane`, the entity view (toolbar + columns + graph).
//!
//! Hosting: `try cx.newWith(HistoryPane, HistoryPane.init, .{app_state})`;
//! subscribe to `HistoryPane.OpenCommit` and open
//! `changes.ChangesPane.initCommit(state, .{ .sha, .subject })` as a tab.

pub const types = @import("types.zig");
pub const graph = @import("graph.zig");
pub const store = @import("store.zig");
pub const pane = @import("pane.zig");

pub const HistoryPane = pane.HistoryPane;
pub const HistoryStore = store.HistoryStore;
pub const OpenCommit = pane.OpenCommit;

test {
    @import("std").testing.refAllDecls(@This());
}
