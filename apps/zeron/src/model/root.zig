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
pub const types = @import("types.zig");
pub const engine_state = @import("engine_state.zig");
pub const workspace = @import("workspace.zig");
pub const transcript_store = @import("transcript_store.zig");
pub const queue_store = @import("queue_store.zig");
pub const status = @import("status.zig");
pub const app_state = @import("app_state.zig");
pub const attachments = @import("attachments.zig");

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

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("pure_tests.zig");
    _ = @import("store_test.zig");
    _ = @import("live_test.zig");
}
