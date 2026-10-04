const std = @import("std");
const uucode = @import("uucode");
const lut = @import("lut.zig");

/// Runnable binary to generate the lookup tables and output to stdout.
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    const gen: lut.Generator(
        bool,
        struct {
            pub fn get(ctx: @This(), cp: u21) !bool {
                _ = ctx;
                return if (cp > uucode.config.max_code_point)
                    false
                else
                    uucode.get(.is_symbol, @intCast(cp));
            }

            pub fn eql(ctx: @This(), a: bool, b: bool) bool {
                _ = ctx;
                return a == b;
            }
        },
    ) = .{};

    const t = try gen.generate(alloc);
    defer alloc.free(t.stage1);
    defer alloc.free(t.stage2);
    defer alloc.free(t.stage3);

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    try t.writeZig(&stdout.interface);
    // Use flush instead of end because stdout is a pipe when captured by
    // the build system, and pipes cannot be truncated (Windows returns
    // INVALID_PARAMETER, Linux returns EINVAL).
    try stdout.interface.flush();

    // Uncomment when manually debugging to see our table sizes.
    // std.log.warn("stage1={} stage2={} stage3={}", .{
    //     t.stage1.len,
    //     t.stage2.len,
    //     t.stage3.len,
    // });
}
