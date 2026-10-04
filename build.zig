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

    addZeronEngine(b, target, optimize, test_step);
    addZeronDesign(b, target, optimize, zpui, test_step);
}

/// zeron engine client library (apps/zeron/src/engine), its tests, and the
/// `zeron-probe` CLI (`zig build probe -- --help`).
fn addZeronEngine(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) void {
    const engine = b.addModule("zeron_engine", .{
        .root_source_file = b.path("apps/zeron/src/engine/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    const engine_tests = b.addTest(.{ .root_module = engine });
    test_step.dependOn(&b.addRunArtifact(engine_tests).step);

    const probe = b.addExecutable(.{
        .name = "zeron-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/zeron/examples/probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zeron_engine", .module = engine }},
        }),
    });
    b.installArtifact(probe);
    const run_probe = b.addRunArtifact(probe);
    run_probe.addPassthruArgs();
    const probe_step = b.step("probe", "Run zeron-probe against a local engine");
    probe_step.dependOn(&run_probe.step);
}

fn addZeronDesign(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zpui: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    const theme = b.addModule("zeron_theme", .{
        .root_source_file = b.path("apps/zeron/src/theme/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zpui", .module = zpui }},
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = theme })).step);

    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(b.path("apps/zeron/assets"), "assets", .{});
    const assets = b.addModule("zeron_assets", .{
        .root_source_file = files.addCopyFile(b.path("apps/zeron/src/assets.zig"), "assets.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = assets })).step);
}
