//! Code taken from 0.15.2 `std.testing`. See README.md for license and
//! details.
const builtin = @import("builtin");
const std = @import("std");

/// Given a type, recursively references all the declarations inside, so that the semantic analyzer sees them.
/// For deep types, you may use `@setEvalBranchQuota`.
pub fn refAllDeclsRecursive(comptime T: type) void {
    if (!builtin.is_test) return;
    // zpui: 0.17 std.meta.declarations returns names, not Declaration structs.
    inline for (comptime std.meta.declarations(T)) |decl_name| {
        if (@TypeOf(@field(T, decl_name)) == type) {
            switch (@typeInfo(@field(T, decl_name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl_name)),
                else => {},
            }
        }
        _ = &@field(T, decl_name);
    }
}
