//! zeron's message composer (the `zeron_composer` module) — a port of Rust
//! `Composer` (`crates/ui/src/composer.rs`) and the composer slice of
//! `pickers.rs` / `queue.rs` on zpui.
//!
//! - `ComposerView` (`composer.zig`): the frosted pill, compact ↔ expanded
//!   flip, attachments strip, model chip, mic / send / stop, queue tray,
//!   slash completions, submit → `TranscriptStore.queueCommand`;
//! - `ModelPicker` (`model_picker.zig`): chip + harness/model popover;
//! - `metrics`, `run_config`, `slash`: pure logic with Rust parity tests.
//!
//! ```zig
//! const composer = try cx.newWith(ComposerView, ComposerView.init, .{app_state});
//! composer.update(cx, ComposerView.setTheme, .{theme});
//! div().child(composer)
//! ```
//! The editor itself is `zeron_input.TextInput`.

pub const metrics = @import("metrics.zig");
pub const run_config = @import("run_config.zig");
pub const slash = @import("slash.zig");
pub const chrome = @import("chrome.zig");
pub const model_picker = @import("model_picker.zig");
pub const composer = @import("composer.zig");
pub const mentions = @import("mentions.zig");
pub const wizard = @import("wizard.zig");
pub const todo_panel = @import("todo_panel.zig");
pub const completions = @import("completions.zig");
pub const extras = @import("extras.zig");
pub const account_usage = @import("account_usage.zig"); // plan-usage ring + account switcher

pub const ComposerView = composer.ComposerView;
pub const ComposerEvent = composer.ComposerEvent;
pub const ModelPicker = model_picker.ModelPicker;
pub const TextInput = @import("zeron_input").TextInput;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tests.zig");
    _ = @import("extras_test.zig"); // [wiring]
    _ = @import("attachments_test.zig");
}
