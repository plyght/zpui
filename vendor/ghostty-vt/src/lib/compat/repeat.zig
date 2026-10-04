//! zpui port helper: Zig 0.17 removed the `**` array/string repetition
//! operator. `"ab" ** n` is rewritten to `repeat.str("ab", n)` (same type:
//! `*const [len:0]u8`). See vendor/ghostty-vt/PORTING.md.

/// Comptime string repetition, equivalent to the removed `s ** n`.
pub fn str(comptime s: []const u8, comptime n: usize) *const [s.len * n:0]u8 {
    return comptime blk: {
        @setEvalBranchQuota(n * 4 + 1000);
        var buf: [s.len * n:0]u8 = undefined;
        for (0..n) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
        buf[s.len * n] = 0;
        const final = buf;
        break :blk &final;
    };
}
