//! zeron's non-visual app state for the Zig client (the `zeron_model`
//! module) — a port of the state/model layer of zeron `crates/ui`
//! (`state.rs`, `settings.rs`) and of `crates/proto/src/view.rs`.
//!
//! - `view`, `time`: pure view logic (sorting, 45s session staleness, gate
//!   phase, chip text, relative times) with Rust parity fixtures;
//! - `settings` (+ `settings_store` global): `ui-settings.json`, shortcut
//!   combos, data-dir resolution; `composer_defaults`: the sticky
//!   `composer-defaults.json` picks (model picker / canvas data source);
//! - `engine_state`: the engine connection entity (connect / spawn,
//!   reconnect with backoff, reader-thread wake → main-thread pump, unary
//!   request callbacks, `Watch` stream handles);
//! - `workspace`: chats / spaces / devices / sessions / sidebar preferences +
//!   selection and the sidebar queries;
//! - `transcript_store`, `queue_store`: per-chat transcript (delta apply,
//!   desync → resubscribe, opening tail, echoes) and message queue;
//! - `status`: auth, sync/connectivity, app update status, harness/model
//!   catalog;
//! - `app_state`: the root entity wiring all of the above.
//!
//! Every store is a zpui entity that emits typed events and calls
//! `cx.notify()` when its presentation changes.

pub const time = @import("time.zig");
pub const view = @import("view.zig");
pub const eql = @import("eql.zig");
pub const settings = @import("settings.zig");
pub const settings_store = @import("settings_store.zig");
pub const composer_defaults = @import("composer_defaults.zig");
/// The composer-defaults global (+ explicit new-thread defaults).
pub const composer_store = @import("composer_store.zig");
pub const background_fade = @import("background_fade.zig");
/// Settings → Appearance → Native menus (macOS; its own native-menus.json).
pub const native_menus = @import("native_menus.zig");
/// Settings → Appearance → Use SF Symbols (macOS; its own sf-symbols.json).
pub const sf_symbols = @import("sf_symbols.zig");
/// Whether the interface font size was ever chosen (`ui-font-size-chosen.json`).
pub const ui_font_size_choice = @import("ui_font_size_choice.zig");
pub const types = @import("types.zig");
pub const engine_state = @import("engine_state.zig");
pub const workspace = @import("workspace.zig");
pub const transcript_store = @import("transcript_store.zig");
pub const queue_store = @import("queue_store.zig");
pub const status = @import("status.zig");
pub const app_state = @import("app_state.zig");
pub const attachments = @import("attachments.zig");
/// Appshots: capture staging, prompt context, queue restore (appshots.zig).
pub const appshots = @import("appshots.zig");
pub const comments = @import("comments.zig");
pub const review_comments = @import("review_comments.zig");
pub const change_requests = @import("change_requests.zig");
/// Test-only loopback WebSocket engine (UI tests drive real RPC through it).
pub const fake_server = @import("fake_server.zig");

pub const Timestamp = time.Timestamp;
pub const UiSettings = settings.UiSettings;
pub const KeymapConfig = settings.KeymapConfig;
pub const ShortcutId = settings.ShortcutId;
pub const SettingsStore = settings_store.SettingsStore;
pub const EngineState = engine_state.EngineState;
pub const EngineEvent = engine_state.EngineEvent;
pub const WorkspaceStore = workspace.WorkspaceStore;
pub const TranscriptStore = transcript_store.TranscriptStore;
pub const QueueStore = queue_store.QueueStore;
pub const AuthStore = status.AuthStore;
pub const SyncStore = status.SyncStore;
pub const UpdateStore = status.UpdateStore;
pub const CatalogStore = status.CatalogStore;
pub const AppState = app_state.AppState;
pub const ReviewCommentStore = review_comments.ReviewCommentStore;
pub const ChangeRequestStore = change_requests.ChangeRequestStore;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("pure_tests.zig");
    _ = @import("store_test.zig");
    _ = @import("live_test.zig");
}
