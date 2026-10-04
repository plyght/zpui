//! zpui vendor STUB (replaces upstream src/quirks.zig, which imports the
//! font stack for `disableDefaultFontFeatures`). Only `inlineAssert` is
//! used by the terminal core. See vendor/ghostty-vt/PORTING.md.
const std = @import("std");
const builtin = @import("builtin");

pub const inlineAssert = switch (builtin.mode) {
    .debug => std.debug.assert,
    .small, .safe, .fast => (struct {
        inline fn assert(ok: bool) void {
            if (!ok) unreachable;
        }
    }).assert,
};
