const std = @import("std");
pub fn build(b: *std.Build) void {
    const dep = b.dependency("uucode", .{ .target = b.graph.host, .build_config_path = b.path("uucode_config.zig") });
    const inst = b.addInstallFile(dep.namedLazyPath("tables.zig"), "tables.zig");
    b.getInstallStep().dependOn(&inst.step);
    const dep2 = b.dependency("uucode", .{ .target = b.graph.host, .build_config_path = b.path("uucode_runtime_config.zig") });
    b.getInstallStep().dependOn(&b.addInstallFile(dep2.namedLazyPath("tables.zig"), "runtime_tables.zig").step);
    inline for (.{ "props", "symbols" }) |n| {
        const exe = b.addExecutable(.{ .name = n, .root_module = b.createModule(.{ .root_source_file = b.path(n ++ "_uucode.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }), .use_llvm = true });
        exe.root_module.addImport("uucode", dep.module("uucode"));
        const run = b.addRunArtifact(exe);
        b.getInstallStep().dependOn(&b.addInstallFile(run.captureStdOut(.{}), n ++ ".zig").step);
    }
}
