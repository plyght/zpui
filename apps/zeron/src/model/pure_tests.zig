//! The zpui-free part of the model (`zig build zeron-view-test`): view logic,
//! timestamps, settings, and the Rust parity fixtures.

test {
    _ = @import("time.zig");
    _ = @import("view.zig");
    _ = @import("view_parity_test.zig");
}

test {
    _ = @import("settings.zig");
    _ = @import("composer_defaults.zig");
    _ = @import("eql.zig");
}
