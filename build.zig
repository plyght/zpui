const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpui = b.addModule("zpui", .{
        .root_source_file = b.path("src/zpui.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = zpui });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zpui unit tests");
    test_step.dependOn(&run_tests.step);
}
