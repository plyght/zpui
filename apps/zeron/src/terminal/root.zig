//! zeron terminal panel core (Zig port of `crates/ui/src/terminal/`):
//! terminal emulation is Ghostty's VT core, vendored and ported to Zig 0.17
//! in `vendor/ghostty-vt` (see its PORTING.md).
//!
//! - `Emulator`  feed/resize/scrollback/selection/snapshot (emulator.rs)
//! - `snapshot`  render snapshot types (cells, colors, cursor, damage)
//! - `palette`   theme color resolution (view.rs `resolve_color`)
//! - `keys`      keystroke -> bytes (Ghostty key encoder, Kitty protocol)
//! - `input`     mouse / wheel / paste / focus encoding
//! - `session`   SubscribeTerminal data stream (base64 + seq), coalescer
//! - `paint`     renderer-agnostic paint plan (bg/selection quads, pinned
//!               text segments, cursor), from view.rs prepaint/shape_row
//! - `pty`       local forkpty runner for tests and examples
pub const vt = @import("ghostty-vt");
pub const Emulator = @import("Emulator.zig");
pub const snapshot = @import("snapshot.zig");
pub const palette = @import("palette.zig");
pub const keys = @import("keys.zig");
pub const input = @import("input.zig");
pub const session = @import("session.zig");
pub const pty = @import("pty.zig");
pub const paint = @import("paint.zig");

pub const Snapshot = snapshot.Snapshot;
pub const Cell = snapshot.Cell;
pub const CellColor = snapshot.CellColor;
pub const Palette = palette.Palette;
pub const DataStream = session.DataStream;

test {
    // Ghostty logs warnings for unsupported sequences (real captures contain
    // plenty); stderr output would fail the build runner's test step.
    @import("std").testing.log_level = .err;
    _ = @import("emulator_test.zig");
    _ = @import("capture_test.zig");
    _ = snapshot;
    _ = palette;
    _ = keys;
    _ = input;
    _ = session;
    _ = pty;
    _ = paint;
}
