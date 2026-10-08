//! Compile-only check of the macOS platform backend for cross builds without
//! a macOS SDK: `zig build mac-check -Dtarget=aarch64-macos` emits an object
//! file (no framework linking). Taking `main`'s address forces analysis and
//! codegen of the demo and, through it, the AppKit window/platform code and
//! the CoreText text system.

const std = @import("std");
const zpui = @import("zpui");
const mac_window = @import("mac_window.zig");
const prefs_demo = @import("prefs_demo.zig");

export fn zpui_mac_check() callconv(.c) usize {
    var sum: usize = @intFromPtr(&mac_window.main);
    sum +%= @intFromPtr(&prefs_demo.main);
    sum +%= @intFromPtr(&zpui.mac_platform.create);
    sum +%= @intFromPtr(&zpui.mac_platform.MacWindow.open);
    return sum;
}

test {
    std.testing.refAllDecls(zpui.mac_platform);
}
