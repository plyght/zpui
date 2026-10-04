//! Search functionality for the terminal.

pub const options = @import("terminal_options");

pub const Active = @import("search/active.zig").ActiveSearch;
pub const PageList = @import("search/pagelist.zig").PageListSearch;
pub const Screen = @import("search/screen.zig").ScreenSearch;
pub const Terminal = @import("search/terminal.zig").TerminalSearch;
pub const Viewport = @import("search/viewport.zig").ViewportSearch;

// The search thread is not available in libghostty due to the xev dep
// for now.
// zpui: libghostty-vt only; upstream switches on artifact and imports
// search/Thread.zig (xev + app globals) for `.ghostty`.
pub const Thread = void;

test {
    @import("std").testing.refAllDecls(@This());

    // Non-public APIs
    _ = @import("search/sliding_window.zig");
}
