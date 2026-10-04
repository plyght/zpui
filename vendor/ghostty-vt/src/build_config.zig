//! zpui vendor STUB (replaces upstream src/build_config.zig).
//! Upstream pulls in apprt/font/renderer; libghostty-vt only needs the
//! constants below. See vendor/ghostty-vt/PORTING.md.
const std = @import("std");
const builtin = @import("builtin");

pub const AppRuntime = enum { none, gtk };
pub const app_runtime: AppRuntime = .none;

pub const slow_runtime_safety = std.debug.runtime_safety and switch (builtin.mode) {
    .debug => true,
    .safe, .small, .fast => false,
};

pub const is_debug = switch (builtin.mode) {
    .debug, .safe => true,
    .fast, .small => false,
};
