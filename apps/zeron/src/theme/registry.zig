//! The built-in theme registry (zeron `ThemeRegistry::builtin`), derived at
//! comptime from the generated seeds in `builtins.zig`.

const std = @import("std");
const model = @import("model.zig");
const builtins = @import("builtins.zig");

pub const Registry = model.Registry;

/// Zeron Light/Dark plus the 28 imported variants (19 families).
pub const builtin: Registry = .{ .families = &builtins.families };

/// A registry of the built-ins plus `custom` families (e.g. installed imports).
pub fn withCustom(custom: []const model.ThemeFamily) Registry {
    return .{ .families = &builtins.families, .custom = custom };
}

/// The installed custom families (`replace_custom_families`); the theme
/// library keeps the memory alive for the process.
var custom_families: []const model.ThemeFamily = &.{};

/// `replace_custom_families`.
pub fn setCustom(families: []const model.ThemeFamily) void {
    custom_families = families;
}

/// `ThemeRegistry::active`: built-ins plus the installed custom families.
pub fn active() Registry {
    return withCustom(custom_families);
}

/// Whether `variant` is an unmodified built-in (whose curated text colors are
/// trusted verbatim instead of being contrast-hardened).
pub fn isCuratedBuiltin(variant: *const model.ThemeVariant) bool {
    const b = builtin.variant(variant.id) orelse return false;
    return b == variant or b.eql(variant);
}

const testing = std.testing;

test "builtins have 30 variants in 19 families and no validation errors" {
    try testing.expectEqual(@as(usize, 19), builtin.families.len);
    var n: usize = 0;
    for (builtin.families) |f| n += f.variants.len;
    try testing.expectEqual(@as(usize, 30), n);
    try testing.expectEqual(builtins.variant_count, n);
    try testing.expect(builtin.variant("zeron-light") != null);
    try testing.expect(builtin.variant("zeron-dark") != null);

    var issues = try builtin.validate(testing.allocator);
    defer model.ValidationIssue.deinitList(&issues, testing.allocator);
    for (issues.items) |issue| {
        if (issue.severity == .err) {
            std.debug.print("{s}: {s}\n", .{ issue.variant_id, issue.message });
            return error.TestUnexpectedResult;
        }
    }
}

test "resolve falls back to the zeron variant" {
    const sel: model.ThemeSelection = .{ .light = "nope", .dark = "dracula" };
    try testing.expectEqualStrings("zeron-light", builtin.resolve(sel, .light).id);
    try testing.expectEqualStrings("dracula", builtin.resolve(sel, .dark).id);
    var it = builtin.variantsFor(.light);
    var lights: usize = 0;
    while (it.next()) |v| : (lights += 1) try testing.expectEqual(model.Appearance.light, v.appearance);
    try testing.expect(lights > 0 and lights < 30);
}

test "curated builtin detection" {
    const dark = builtin.variant("zeron-dark").?;
    try testing.expect(isCuratedBuiltin(dark));
    var copy = dark.*;
    try testing.expect(isCuratedBuiltin(&copy));
    copy.colors.text = .white;
    try testing.expect(!isCuratedBuiltin(&copy));
    const custom = [_]model.ThemeFamily{.{ .id = "mine", .name = "Mine", .variants = &.{copy} }};
    try testing.expect(withCustom(&custom).variant("zeron-dark") == dark);
}
