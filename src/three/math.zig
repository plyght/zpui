//! Minimal 3D math for zpui.three (spike). Column-major `Mat4` (m[col][row]),
//! matching GLSL/MSL `float4x4` memory layout. Right-handed world, camera looks
//! down -Z, clip depth 0..1 with reverse-Z (near = 1, far/infinity = 0).

const std = @import("std");

pub const Vec3 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.y * b.z - a.z * b.y, .y = a.z * b.x - a.x * b.z, .z = a.x * b.y - a.y * b.x };
    }
    pub fn length(a: Vec3) f32 {
        return @sqrt(a.dot(a));
    }
    pub fn normalize(a: Vec3) Vec3 {
        const l = a.length();
        return if (l == 0) a else a.scale(1 / l);
    }
};

pub const Mat4 = extern struct {
    m: [4][4]f32,

    pub const identity: Mat4 = .{ .m = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } } };

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var r: Mat4 = undefined;
        for (0..4) |col| for (0..4) |row| {
            var s: f32 = 0;
            for (0..4) |k| s += a.m[k][row] * b.m[col][k];
            r.m[col][row] = s;
        };
        return r;
    }

    pub fn translation(t: Vec3) Mat4 {
        var r = identity;
        r.m[3] = .{ t.x, t.y, t.z, 1 };
        return r;
    }

    pub fn scaling(s: Vec3) Mat4 {
        var r = identity;
        r.m[0][0] = s.x;
        r.m[1][1] = s.y;
        r.m[2][2] = s.z;
        return r;
    }

    pub fn rotationY(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        var r = identity;
        r.m[0] = .{ c, 0, -s, 0 };
        r.m[2] = .{ s, 0, c, 0 };
        return r;
    }

    pub fn rotationX(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        var r = identity;
        r.m[1] = .{ 0, c, s, 0 };
        r.m[2] = .{ 0, -s, c, 0 };
        return r;
    }

    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = target.sub(eye).normalize();
        const s = f.cross(up).normalize();
        const u = s.cross(f);
        return .{ .m = .{
            .{ s.x, u.x, -f.x, 0 },
            .{ s.y, u.y, -f.y, 0 },
            .{ s.z, u.z, -f.z, 0 },
            .{ -s.dot(eye), -u.dot(eye), f.dot(eye), 1 },
        } };
    }

    /// Infinite reverse-Z perspective. `flip_y` for Vulkan (NDC +y down).
    pub fn perspectiveReverseZ(fov_y: f32, aspect: f32, near: f32, flip_y: bool) Mat4 {
        const f = 1 / @tan(fov_y / 2);
        return .{ .m = .{
            .{ f / aspect, 0, 0, 0 },
            .{ 0, if (flip_y) -f else f, 0, 0 },
            .{ 0, 0, 0, -1 },
            .{ 0, 0, near, 0 },
        } };
    }

    pub fn transformPoint(a: Mat4, p: Vec3) [4]f32 {
        var r: [4]f32 = undefined;
        for (0..4) |row| r[row] = a.m[0][row] * p.x + a.m[1][row] * p.y + a.m[2][row] * p.z + a.m[3][row];
        return r;
    }
};

test "reverse-Z maps near to 1 and far toward 0" {
    const p = Mat4.perspectiveReverseZ(std.math.pi / 3.0, 1, 0.1, false);
    const near = p.transformPoint(.new(0, 0, -0.1));
    try std.testing.expectApproxEqAbs(@as(f32, 1), near[2] / near[3], 1e-5);
    const far = p.transformPoint(.new(0, 0, -1000));
    try std.testing.expect(far[2] / far[3] < 0.001);
}

test "lookAt puts the target on -Z" {
    const v = Mat4.lookAt(.new(3, 4, 5), .new(0, 0, 0), .new(0, 1, 0));
    const t = v.transformPoint(.new(0, 0, 0));
    try std.testing.expectApproxEqAbs(@as(f32, 0), t[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), t[1], 1e-5);
    try std.testing.expectApproxEqAbs(-@sqrt(@as(f32, 50)), t[2], 1e-4);
}
