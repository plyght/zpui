//! zeron's Browser surface (port of `crates/ui/src/browser`): `BrowserPane` (pane.zig),
//! the shared page/URL model (model.zig), the macOS WKWebView host (mac.zig, a zpui
//! native child view) and the Linux WebKitGTK helper host (linux.zig, offscreen
//! frames from apps/zeron/native/linux-browser/helper.c).

const builtin = @import("builtin");

pub const model = @import("model.zig");
pub const pane = @import("pane.zig");
pub const waker = @import("waker.zig");
pub const BrowserPane = pane.BrowserPane;
pub const NewTab = pane.NewTab;
pub const CloseRequested = pane.CloseRequested;
pub const linux = if (builtin.os.tag == .linux) @import("linux.zig") else struct {};
pub const mac = if (builtin.os.tag == .macos) @import("mac.zig") else struct {};

test {
    _ = model;
    _ = pane;
    if (builtin.os.tag == .linux) _ = @import("linux.zig");
}
