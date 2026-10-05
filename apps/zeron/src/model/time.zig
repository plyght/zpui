//! UTC instants for the engine's RFC 3339 timestamps (`DateTime<Utc>` on the
//! Rust side). The wire carries strings; ordering and age math need instants,
//! because equal instants can be spelled differently (offsets, fraction
//! digits) and so never compare correctly as text.
//!
//! `parse` accepts what chrono's serde decode accepts (`parse_rfc3339_relaxed`):
//! `YYYY-MM-DD` + `T`/`t`/space + `HH:MM:SS[.frac]` + optional spaces +
//! `Z`/`z`/`±HH:MM`/`±HHMM`. Fraction digits beyond nanoseconds are
//! truncated; second 60 is a leap second (chrono keeps it as nanos ≥ 1e9).

const std = @import("std");

pub const Timestamp = struct {
    /// Seconds since the Unix epoch.
    secs: i64,
    /// Sub-second nanoseconds; ≥ 1e9 only inside a leap second (chrono).
    nanos: u32 = 0,

    pub const epoch: Timestamp = .{ .secs = 0 };

    pub fn fromUnixMillis(ms: i64) Timestamp {
        return .{ .secs = @divFloor(ms, 1000), .nanos = @intCast(@mod(ms, 1000) * std.time.ns_per_ms) };
    }

    pub fn fromNanos(ns: i128) Timestamp {
        return .{
            .secs = @intCast(@divFloor(ns, std.time.ns_per_s)),
            .nanos = @intCast(@mod(ns, std.time.ns_per_s)),
        };
    }

    /// Wall clock now.
    pub fn now(io: std.Io) Timestamp {
        return fromNanos(std.Io.Timestamp.now(io, .real).nanoseconds);
    }

    pub fn toNanos(t: Timestamp) i128 {
        return @as(i128, t.secs) * std.time.ns_per_s + t.nanos;
    }

    pub fn toUnixMillis(t: Timestamp) i64 {
        return @intCast(@divFloor(t.toNanos(), std.time.ns_per_ms));
    }

    pub fn order(a: Timestamp, b: Timestamp) std.math.Order {
        if (a.secs != b.secs) return std.math.order(a.secs, b.secs);
        return std.math.order(a.nanos, b.nanos);
    }

    pub fn eql(a: Timestamp, b: Timestamp) bool {
        return a.secs == b.secs and a.nanos == b.nanos;
    }

    /// `(a - b).num_milliseconds()`: truncated toward zero.
    pub fn millisSince(a: Timestamp, b: Timestamp) i64 {
        return @intCast(@divTrunc(a.toNanos() - b.toNanos(), std.time.ns_per_ms));
    }

    /// `(a - b).num_seconds()`: truncated toward zero.
    pub fn secondsSince(a: Timestamp, b: Timestamp) i64 {
        return @intCast(@divTrunc(a.toNanos() - b.toNanos(), std.time.ns_per_s));
    }

    pub fn addMillis(t: Timestamp, ms: i64) Timestamp {
        return fromNanos(t.toNanos() + @as(i128, ms) * std.time.ns_per_ms);
    }

    /// RFC 3339 with `Z` and as many fraction digits as needed (chrono's
    /// `to_rfc3339_opts(AutoSi, true)`, which is how the engine writes).
    pub fn format(t: Timestamp, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const leap = t.nanos >= std.time.ns_per_s;
        const nanos = if (leap) t.nanos - std.time.ns_per_s else t.nanos;
        const days = @divFloor(t.secs, 86_400);
        const sod: u32 = @intCast(@mod(t.secs, 86_400));
        const ymd = civilFromDays(days);
        const sec = sod % 60 + @as(u32, if (leap) 1 else 0);
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            @as(u32, @intCast(std.math.clamp(ymd.year, 0, 9999))), ymd.month, ymd.day, sod / 3600, sod / 60 % 60, sec, // wire data before year 0 must not panic
        });
        if (nanos != 0) {
            if (nanos % 1_000_000 == 0) {
                try w.print(".{d:0>3}", .{nanos / 1_000_000});
            } else if (nanos % 1000 == 0) {
                try w.print(".{d:0>6}", .{nanos / 1000});
            } else try w.print(".{d:0>9}", .{nanos});
        }
        try w.writeByte('Z');
    }
};

/// Parse an RFC 3339 timestamp; null when chrono would reject it.
pub fn parse(s: []const u8) ?Timestamp {
    var p: Parser = .{ .s = s };
    return p.run();
}

/// Parse an optional wire timestamp; malformed values read as null.
pub fn parseOpt(s: ?[]const u8) ?Timestamp {
    return parse(s orelse return null);
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn digits(p: *Parser, n: usize) ?u32 {
        if (p.i + n > p.s.len) return null;
        var v: u32 = 0;
        for (p.s[p.i .. p.i + n]) |c| {
            if (c < '0' or c > '9') return null;
            v = v * 10 + (c - '0');
        }
        p.i += n;
        return v;
    }

    fn expect(p: *Parser, c: u8) ?void {
        if (p.i >= p.s.len or p.s[p.i] != c) return null;
        p.i += 1;
    }

    fn run(p: *Parser) ?Timestamp {
        const year = p.digits(4) orelse return null;
        p.expect('-') orelse return null;
        const month = p.digits(2) orelse return null;
        p.expect('-') orelse return null;
        const day = p.digits(2) orelse return null;
        if (p.i >= p.s.len) return null;
        switch (p.s[p.i]) {
            'T', 't', ' ' => p.i += 1,
            else => return null,
        }
        const hour = p.digits(2) orelse return null;
        p.expect(':') orelse return null;
        const minute = p.digits(2) orelse return null;
        p.expect(':') orelse return null;
        const second = p.digits(2) orelse return null;
        var nanos: u32 = 0;
        if (p.i < p.s.len and p.s[p.i] == '.') {
            p.i += 1;
            const start = p.i;
            var scale: u32 = 100_000_000;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) : (p.i += 1) {
                nanos += (p.s[p.i] - '0') * scale;
                scale /= 10;
            }
            if (p.i == start) return null;
        }
        while (p.i < p.s.len and p.s[p.i] == ' ') p.i += 1;
        if (p.i >= p.s.len) return null;
        var offset: i64 = 0;
        switch (p.s[p.i]) {
            'Z', 'z' => p.i += 1,
            '+', '-' => |sign| {
                p.i += 1;
                const oh = p.digits(2) orelse return null;
                if (p.i < p.s.len and p.s[p.i] == ':') p.i += 1;
                const om = p.digits(2) orelse return null;
                if (oh >= 24 or om >= 60) return null;
                offset = @as(i64, oh) * 3600 + @as(i64, om) * 60;
                if (sign == '-') offset = -offset;
            },
            else => return null,
        }
        if (p.i != p.s.len) return null;

        if (month < 1 or month > 12) return null;
        if (day < 1 or day > daysInMonth(year, month)) return null;
        if (hour > 23 or minute > 59 or second > 60) return null;
        var sec = second;
        if (second == 60) {
            sec = 59;
            nanos += std.time.ns_per_s;
        }
        const days = daysFromCivil(year, month, day);
        const secs = days * 86_400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + sec - offset;
        return .{ .secs = secs, .nanos = nanos };
    }
};

fn isLeap(y: u32) bool {
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
}

fn daysInMonth(y: u32, m: u32) u32 {
    return switch (m) {
        2 => if (isLeap(y)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Howard Hinnant's days_from_civil.
fn daysFromCivil(year: u32, month: u32, day: u32) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

fn civilFromDays(z0: i64) struct { year: i64, month: u32, day: u32 } {
    const z = z0 + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = era * 400 + yoe + @intFromBool(m <= 2), .month = m, .day = d };
}

test "parse and format" {
    const t = parse("2026-01-01T05:31:00.090350+05:30").?;
    try std.testing.expectEqual(@as(i64, 1767225660), t.secs);
    try std.testing.expectEqual(@as(u32, 90_350_000), t.nanos);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try t.format(&w);
    try std.testing.expectEqualStrings("2026-01-01T00:01:00.090350Z", w.buffered());
    try std.testing.expect(parse("2026-02-29T00:00:00Z") == null);
    try std.testing.expectEqual(@as(i64, -1), parse("1969-12-31T23:59:59.999Z").?.secs);
    try std.testing.expectEqual(Timestamp.epoch, Timestamp.fromUnixMillis(0));
    try std.testing.expectEqual(@as(i64, -1500), Timestamp.fromUnixMillis(-1500).toUnixMillis());
}
