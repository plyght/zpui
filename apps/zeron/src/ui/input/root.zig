//! zeron's reusable text editor (the `zeron_input` module) — a port of the
//! Rust `ComposerInput` (`crates/ui/src/composer.rs`), which zeron reuses as
//! the generic text field in ~23 modules (session rename, palettes, picker
//! searches, browser URL bar, settings fields).
//!
//! - `segment`: grapheme / word (UAX #29 approximation) boundaries, UTF-16
//!   offset mapping;
//! - `editor`: `EditorState` — buffer, selection, IME marked text, undo/redo
//!   with coalescing, motions (pure, unit-tested);
//! - `text_input`: `TextInput`, the zpui view (multiline soft-wrapped or
//!   single-line, mouse selection, clipboard, IME, caret blink, autoscroll,
//!   placeholder) plus its custom text element.
//!
//! ```zig
//! const input = try cx.newWith(TextInput, TextInput.init, .{.{ .placeholder = "Session title", .single_line = true }});
//! try self.subs.add(cx.gpa(), try cx.subscribe(input, Self.onInputEvent));
//! div().child(input)
//! ```

pub const segment = @import("segment.zig");
pub const editor = @import("editor.zig");
pub const text_input = @import("text_input.zig");

pub const EditorState = editor.EditorState;
pub const Range = editor.Range;
pub const CaretAffinity = editor.CaretAffinity;
pub const TextInput = text_input.TextInput;
pub const TextInputEvent = text_input.TextInputEvent;
pub const Options = text_input.Options;
pub const Colors = text_input.Colors;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
