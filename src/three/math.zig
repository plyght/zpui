//! 3D math for zpui.three. Column-major `Mat4` (`m[col][row]`), matching the
//! GLSL/MSL `mat4`/`float4x4` memory layout. Right-handed world (+Y up), the
//! camera looks down -Z, clip depth is 0..1. Camera projections are reverse-Z
//! (near = 1, far = 0); shadow projections use standard Z.

const std = @import("std");

pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn new(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }
};

pub const Vec3 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const zero: Vec3 = .{};
    pub const one: Vec3 = .{ .x = 1, .y = 1, .z = 1 };
    pub const up: Vec3 = .{ .y = 1 };

    pub fn new(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }
    pub fn splat(v: f32) Vec3 {
        return .{ .x = v, .y = v, .z = v };
    }
    pub fn fromArray(a: [3]f32) Vec3 {
        return .{ .x = a[0], .y = a[1], .z = a[2] };
    }
    pub fn toArray(a: Vec3) [3]f32 {
        return .{ a.x, a.y, a.z };
    }
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn mulv(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }
    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    pub fn neg(a: Vec3) Vec3 {
        return .{ .x = -a.x, .y = -a.y, .z = -a.z };
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
    pub fn min(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y), .z = @min(a.z, b.z) };
    }
    pub fn max(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y), .z = @max(a.z, b.z) };
    }
    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return a.add(b.sub(a).scale(t));
    }
    pub fn get(a: Vec3, i: usize) f32 {
        return switch (i) {
            0 => a.x,
            1 => a.y,
            else => a.z,
        };
    }
    /// Unit direction from spherical angles in degrees: `azimuth` around +Y
    /// (0 = +Z, 90 = +X), `elevation` above the XZ plane.
    pub fn fromAzimuthElevation(azimuth_deg: f32, elevation_deg: f32) Vec3 {
        const az = std.math.degreesToRadians(azimuth_deg);
        const el = std.math.degreesToRadians(elevation_deg);
        return .{ .x = @cos(el) * @sin(az), .y = @sin(el), .z = @cos(el) * @cos(az) };
    }
};

pub const Vec4 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 0,

    pub fn new(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }
    pub fn xyz(a: Vec4) Vec3 {
        return .{ .x = a.x, .y = a.y, .z = a.z };
    }
};

/// Unit quaternion (x, y, z, w).
pub const Quat = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub const identity: Quat = .{};

    pub fn axisAngle(axis: Vec3, rad: f32) Quat {
        const n = axis.normalize();
        const s = @sin(rad / 2);
        return .{ .x = n.x * s, .y = n.y * s, .z = n.z * s, .w = @cos(rad / 2) };
    }
    pub fn mul(a: Quat, b: Quat) Quat {
        return .{
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        };
    }
    pub fn normalize(q: Quat) Quat {
        const l = @sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
        if (l == 0) return identity;
        return .{ .x = q.x / l, .y = q.y / l, .z = q.z / l, .w = q.w / l };
    }
    pub fn rotate(q: Quat, v: Vec3) Vec3 {
        const u: Vec3 = .{ .x = q.x, .y = q.y, .z = q.z };
        const t = u.cross(v).scale(2);
        return v.add(t.scale(q.w)).add(u.cross(t));
    }
    /// Normalized linear interpolation along the shorter arc.
    pub fn nlerp(a: Quat, b: Quat, t: f32) Quat {
        const d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
        const s: f32 = if (d < 0) -1 else 1;
        return normalize(.{
            .x = a.x + (b.x * s - a.x) * t,
            .y = a.y + (b.y * s - a.y) * t,
            .z = a.z + (b.z * s - a.z) * t,
            .w = a.w + (b.w * s - a.w) * t,
        });
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

    pub fn rotationX(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        var r = identity;
        r.m[1] = .{ 0, c, s, 0 };
        r.m[2] = .{ 0, -s, c, 0 };
        return r;
    }

    /// Counter-clockwise about +Y seen from above (+Z turns toward +X).
    pub fn rotationY(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        var r = identity;
        r.m[0] = .{ c, 0, -s, 0 };
        r.m[2] = .{ s, 0, c, 0 };
        return r;
    }

    pub fn rotationZ(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        var r = identity;
        r.m[0] = .{ c, s, 0, 0 };
        r.m[1] = .{ -s, c, 0, 0 };
        return r;
    }

    pub fn fromQuat(q: Quat) Mat4 {
        const x2 = q.x + q.x;
        const y2 = q.y + q.y;
        const z2 = q.z + q.z;
        const xx = q.x * x2;
        const yy = q.y * y2;
        const zz = q.z * z2;
        const xy = q.x * y2;
        const xz = q.x * z2;
        const yz = q.y * z2;
        const wx = q.w * x2;
        const wy = q.w * y2;
        const wz = q.w * z2;
        return .{ .m = .{
            .{ 1 - (yy + zz), xy + wz, xz - wy, 0 },
            .{ xy - wz, 1 - (xx + zz), yz + wx, 0 },
            .{ xz + wy, yz - wx, 1 - (xx + yy), 0 },
            .{ 0, 0, 0, 1 },
        } };
    }

    /// translation * rotation * scale.
    pub fn trs(t: Vec3, r: Quat, s: Vec3) Mat4 {
        var m = fromQuat(r);
        for (0..3) |row| {
            m.m[0][row] *= s.x;
            m.m[1][row] *= s.y;
            m.m[2][row] *= s.z;
        }
        m.m[3] = .{ t.x, t.y, t.z, 1 };
        return m;
    }

    pub fn transpose(a: Mat4) Mat4 {
        var r: Mat4 = undefined;
        for (0..4) |i| for (0..4) |j| {
            r.m[i][j] = a.m[j][i];
        };
        return r;
    }

    pub fn lookAt(eye: Vec3, target: Vec3, up_dir: Vec3) Mat4 {
        const f = target.sub(eye).normalize();
        var s = f.cross(up_dir);
        // Degenerate up vector (looking straight along it): pick another.
        if (s.dot(s) < 1e-12) s = f.cross(if (@abs(f.z) < 0.9) Vec3.new(0, 0, 1) else Vec3.new(1, 0, 0));
        s = s.normalize();
        const u = s.cross(f);
        return .{ .m = .{
            .{ s.x, u.x, -f.x, 0 },
            .{ s.y, u.y, -f.y, 0 },
            .{ s.z, u.z, -f.z, 0 },
            .{ -s.dot(eye), -u.dot(eye), f.dot(eye), 1 },
        } };
    }

    /// Reverse-Z perspective; `far = inf` gives the infinite variant.
    /// `flip_y` = Vulkan clip space (NDC +y down).
    pub fn perspectiveReverseZ(fov_y: f32, aspect: f32, near: f32, far: f32, flip_y: bool) Mat4 {
        const f = 1 / @tan(fov_y / 2);
        var r: Mat4 = .{ .m = .{
            .{ f / aspect, 0, 0, 0 },
            .{ 0, if (flip_y) -f else f, 0, 0 },
            .{ 0, 0, 0, -1 },
            .{ 0, 0, near, 0 },
        } };
        if (std.math.isFinite(far)) {
            // z_ndc = (near * (far - (-z)) ... ) mapped to near=1, far=0.
            r.m[2][2] = near / (far - near);
            r.m[3][2] = far * near / (far - near);
        }
        return r;
    }

    /// Reverse-Z orthographic: view-space z = -near maps to 1, z = -far to 0.
    pub fn orthographicReverseZ(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32, flip_y: bool) Mat4 {
        var r = orthographic(left, right, bottom, top, near, far, flip_y);
        // depth' = 1 - depth
        r.m[0][2] = -r.m[0][2];
        r.m[1][2] = -r.m[1][2];
        r.m[2][2] = -r.m[2][2];
        r.m[3][2] = 1 - r.m[3][2];
        return r;
    }

    /// Standard-Z orthographic (z = -near maps to 0, z = -far to 1).
    pub fn orthographic(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32, flip_y: bool) Mat4 {
        const sy: f32 = if (flip_y) -1 else 1;
        return .{ .m = .{
            .{ 2 / (right - left), 0, 0, 0 },
            .{ 0, sy * 2 / (top - bottom), 0, 0 },
            .{ 0, 0, -1 / (far - near), 0 },
            .{ -(right + left) / (right - left), sy * -(top + bottom) / (top - bottom), -near / (far - near), 1 },
        } };
    }

    /// Full homogeneous transform; returns (x, y, z, w).
    pub fn transformPoint(a: Mat4, p: Vec3) [4]f32 {
        var r: [4]f32 = undefined;
        for (0..4) |row| r[row] = a.m[0][row] * p.x + a.m[1][row] * p.y + a.m[2][row] * p.z + a.m[3][row];
        return r;
    }

    /// Affine transform of a point (ignores the projective row).
    pub fn transformPoint3(a: Mat4, p: Vec3) Vec3 {
        return .{
            .x = a.m[0][0] * p.x + a.m[1][0] * p.y + a.m[2][0] * p.z + a.m[3][0],
            .y = a.m[0][1] * p.x + a.m[1][1] * p.y + a.m[2][1] * p.z + a.m[3][1],
            .z = a.m[0][2] * p.x + a.m[1][2] * p.y + a.m[2][2] * p.z + a.m[3][2],
        };
    }

    /// Projective transform with the perspective divide.
    pub fn project(a: Mat4, p: Vec3) Vec3 {
        const r = a.transformPoint(p);
        const iw = if (r[3] != 0) 1 / r[3] else 0;
        return .{ .x = r[0] * iw, .y = r[1] * iw, .z = r[2] * iw };
    }

    pub fn transformDir(a: Mat4, d: Vec3) Vec3 {
        return .{
            .x = a.m[0][0] * d.x + a.m[1][0] * d.y + a.m[2][0] * d.z,
            .y = a.m[0][1] * d.x + a.m[1][1] * d.y + a.m[2][1] * d.z,
            .z = a.m[0][2] * d.x + a.m[1][2] * d.y + a.m[2][2] * d.z,
        };
    }

    pub fn getTranslation(a: Mat4) Vec3 {
        return .{ .x = a.m[3][0], .y = a.m[3][1], .z = a.m[3][2] };
    }

    /// General 4x4 inverse (cofactor expansion). Returns null if singular.
    pub fn inverse(a: Mat4) ?Mat4 {
        const m: [16]f32 = @bitCast(a.m);
        var inv: [16]f32 = undefined;
        inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
        inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
        inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
        inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
        inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
        inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
        inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
        inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
        inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
        inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
        inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
        inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
        inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
        inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
        inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
        inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
        const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
        if (det == 0 or !std.math.isFinite(det)) return null;
        const inv_det = 1 / det;
        for (&inv) |*v| v.* *= inv_det;
        return .{ .m = @bitCast(inv) };
    }

    pub fn approxEq(a: Mat4, b: Mat4, tol: f32) bool {
        for (0..4) |i| for (0..4) |j| {
            if (@abs(a.m[i][j] - b.m[i][j]) > tol) return false;
        };
        return true;
    }
};

/// Axis-aligned bounding box. `empty` has min > max and grows with `extend`.
pub const Aabb = extern struct {
    min: Vec3 = Vec3.splat(std.math.inf(f32)),
    max: Vec3 = Vec3.splat(-std.math.inf(f32)),

    pub const empty: Aabb = .{};

    pub fn isEmpty(b: Aabb) bool {
        return b.min.x > b.max.x or b.min.y > b.max.y or b.min.z > b.max.z;
    }
    pub fn extend(b: Aabb, p: Vec3) Aabb {
        return .{ .min = b.min.min(p), .max = b.max.max(p) };
    }
    pub fn merge(a: Aabb, b: Aabb) Aabb {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{ .min = a.min.min(b.min), .max = a.max.max(b.max) };
    }
    pub fn center(b: Aabb) Vec3 {
        return b.min.add(b.max).scale(0.5);
    }
    pub fn extent(b: Aabb) Vec3 {
        return b.max.sub(b.min);
    }
    pub fn radius(b: Aabb) f32 {
        return b.extent().length() * 0.5;
    }
    /// Distance from `p` to the box (0 inside).
    pub fn distanceTo(b: Aabb, p: Vec3) f32 {
        const q: Vec3 = .new(
            std.math.clamp(p.x, b.min.x, b.max.x),
            std.math.clamp(p.y, b.min.y, b.max.y),
            std.math.clamp(p.z, b.min.z, b.max.z),
        );
        return q.sub(p).length();
    }
    pub fn corner(b: Aabb, i: usize) Vec3 {
        return .{
            .x = if (i & 1 != 0) b.max.x else b.min.x,
            .y = if (i & 2 != 0) b.max.y else b.min.y,
            .z = if (i & 4 != 0) b.max.z else b.min.z,
        };
    }
    /// Bounds of the 8 transformed corners (affine `m`).
    pub fn transform(b: Aabb, m: Mat4) Aabb {
        if (b.isEmpty()) return b;
        var r: Aabb = .empty;
        for (0..8) |i| r = r.extend(m.transformPoint3(b.corner(i)));
        return r;
    }
};

/// Half-line `origin + t * dir`, t >= 0. `dir` need not be unit length.
pub const Ray = struct {
    origin: Vec3,
    dir: Vec3,

    pub fn at(r: Ray, t: f32) Vec3 {
        return r.origin.add(r.dir.scale(t));
    }

    pub fn transform(r: Ray, m: Mat4) Ray {
        return .{ .origin = m.transformPoint3(r.origin), .dir = m.transformDir(r.dir) };
    }

    /// Distance to the plane `dot(normal, p) = d`, or null if parallel/behind.
    pub fn intersectPlane(r: Ray, normal: Vec3, d: f32) ?f32 {
        const denom = normal.dot(r.dir);
        if (@abs(denom) < 1e-12) return null;
        const t = (d - normal.dot(r.origin)) / denom;
        return if (t >= 0) t else null;
    }

    /// Point where the ray meets the horizontal plane `y = height`.
    pub fn intersectGround(r: Ray, height: f32) ?Vec3 {
        const t = r.intersectPlane(Vec3.up, height) orelse return null;
        return r.at(t);
    }

    /// Slab test; returns the entry distance (0 if the origin is inside).
    pub fn intersectAabb(r: Ray, b: Aabb, max_t: f32) ?f32 {
        var t0: f32 = 0;
        var t1: f32 = max_t;
        inline for (.{ "x", "y", "z" }) |axis| {
            const o = @field(r.origin, axis);
            const d = @field(r.dir, axis);
            const lo = @field(b.min, axis);
            const hi = @field(b.max, axis);
            if (@abs(d) < 1e-20) {
                if (o < lo or o > hi) return null;
            } else {
                const inv = 1 / d;
                var ta = (lo - o) * inv;
                var tb = (hi - o) * inv;
                if (ta > tb) std.mem.swap(f32, &ta, &tb);
                t0 = @max(t0, ta);
                t1 = @min(t1, tb);
                if (t0 > t1) return null;
            }
        }
        return t0;
    }

    pub const TriangleHit = struct { t: f32, u: f32, v: f32 };

    /// Möller–Trumbore, two-sided.
    pub fn intersectTriangle(r: Ray, a: Vec3, b: Vec3, c: Vec3) ?TriangleHit {
        const e1 = b.sub(a);
        const e2 = c.sub(a);
        const p = r.dir.cross(e2);
        const det = e1.dot(p);
        if (@abs(det) < 1e-14) return null;
        const inv = 1 / det;
        const s = r.origin.sub(a);
        const u = s.dot(p) * inv;
        if (u < 0 or u > 1) return null;
        const q = s.cross(e1);
        const v = r.dir.dot(q) * inv;
        if (v < 0 or u + v > 1) return null;
        const t = e2.dot(q) * inv;
        if (t < 0) return null;
        return .{ .t = t, .u = u, .v = v };
    }
};

/// Six inward-facing planes (xyz normal, w distance) of a view-projection's frustum.
pub const Frustum = struct {
    planes: [6][4]f32,

    /// From a 0..1-depth projection (`m` = proj * view). Reverse-Z is fine:
    /// near/far planes come out swapped, which a containment test doesn't care about.
    pub fn fromMatrix(m: Mat4) Frustum {
        var f: Frustum = undefined;
        const row = struct {
            fn get(a: Mat4, r: usize) [4]f32 {
                return .{ a.m[0][r], a.m[1][r], a.m[2][r], a.m[3][r] };
            }
        }.get;
        const r0 = row(m, 0);
        const r1 = row(m, 1);
        const r2 = row(m, 2);
        const r3 = row(m, 3);
        for (0..4) |i| {
            f.planes[0][i] = r3[i] + r0[i];
            f.planes[1][i] = r3[i] - r0[i];
            f.planes[2][i] = r3[i] + r1[i];
            f.planes[3][i] = r3[i] - r1[i];
            f.planes[4][i] = r2[i]; // z >= 0
            f.planes[5][i] = r3[i] - r2[i]; // z <= w
        }
        return f;
    }

    pub fn intersectsAabb(f: Frustum, b: Aabb) bool {
        if (b.isEmpty()) return false;
        for (f.planes) |p| {
            // The box corner furthest along the plane normal.
            const x = if (p[0] >= 0) b.max.x else b.min.x;
            const y = if (p[1] >= 0) b.max.y else b.min.y;
            const z = if (p[2] >= 0) b.max.z else b.min.z;
            if (p[0] * x + p[1] * y + p[2] * z + p[3] < 0) return false;
        }
        return true;
    }
};

pub fn srgbToLinear(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

pub fn linearToSrgb(c: f32) f32 {
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

/// `#rrggbb` (or `rrggbb`) to linear RGB; null if malformed.
pub fn hexToLinear(hex: []const u8) ?[3]f32 {
    const s = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
    if (s.len != 6) return null;
    var out: [3]f32 = undefined;
    for (0..3) |i| {
        const v = std.fmt.parseInt(u8, s[i * 2 ..][0..2], 16) catch return null;
        out[i] = srgbToLinear(@as(f32, @floatFromInt(v)) / 255.0);
    }
    return out;
}

/// Linear RGBA from an sRGB `0xRRGGBB` literal with alpha.
pub fn rgb(hex: u24) [4]f32 {
    const r: f32 = @floatFromInt((hex >> 16) & 0xff);
    const g: f32 = @floatFromInt((hex >> 8) & 0xff);
    const b: f32 = @floatFromInt(hex & 0xff);
    return .{ srgbToLinear(r / 255), srgbToLinear(g / 255), srgbToLinear(b / 255), 1 };
}

const testing = std.testing;

test "reverse-Z maps near to 1 and far toward 0" {
    const p = Mat4.perspectiveReverseZ(std.math.pi / 3.0, 1, 0.1, std.math.inf(f32), false);
    const near = p.transformPoint(.new(0, 0, -0.1));
    try testing.expectApproxEqAbs(@as(f32, 1), near[2] / near[3], 1e-5);
    const far = p.transformPoint(.new(0, 0, -1000));
    try testing.expect(far[2] / far[3] < 0.001);
    const pf = Mat4.perspectiveReverseZ(std.math.pi / 3.0, 1, 0.1, 100, false);
    try testing.expectApproxEqAbs(@as(f32, 1), pf.project(.new(0, 0, -0.1)).z, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), pf.project(.new(0, 0, -100)).z, 1e-5);
}

test "orthographic depth ranges" {
    const o = Mat4.orthographic(-1, 1, -1, 1, 1, 11, false);
    try testing.expectApproxEqAbs(@as(f32, 0), o.project(.new(0, 0, -1)).z, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), o.project(.new(0, 0, -11)).z, 1e-6);
    const r = Mat4.orthographicReverseZ(-1, 1, -1, 1, 1, 11, true);
    try testing.expectApproxEqAbs(@as(f32, 1), r.project(.new(0, 0, -1)).z, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), r.project(.new(0, 0, -11)).z, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1), r.project(.new(0, 1, -5)).y, 1e-6);
}

test "lookAt puts the target on -Z" {
    const v = Mat4.lookAt(.new(3, 4, 5), .new(0, 0, 0), .new(0, 1, 0));
    const t = v.transformPoint(.new(0, 0, 0));
    try testing.expectApproxEqAbs(@as(f32, 0), t[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), t[1], 1e-5);
    try testing.expectApproxEqAbs(-@sqrt(@as(f32, 50)), t[2], 1e-4);
    // Straight down still produces a valid basis.
    const d = Mat4.lookAt(.new(0, 10, 0), .new(0, 0, 0), .new(0, 1, 0));
    try testing.expect(d.inverse() != null);
}

test "inverse round-trips" {
    const m = Mat4.trs(.new(1, 2, 3), Quat.axisAngle(.new(1, 1, 0), 0.7), .new(2, 0.5, 3));
    const inv = m.inverse().?;
    try testing.expect(m.mul(inv).approxEq(Mat4.identity, 1e-5));
    try testing.expect(Mat4.scaling(.new(0, 1, 1)).inverse() == null);
}

test "quaternion matrix matches rotationY" {
    const q = Quat.axisAngle(.up, 0.9);
    try testing.expect(Mat4.fromQuat(q).approxEq(Mat4.rotationY(0.9), 1e-6));
    const v = q.rotate(.new(0, 0, 1));
    const w = Mat4.rotationY(0.9).transformDir(.new(0, 0, 1));
    try testing.expectApproxEqAbs(v.x, w.x, 1e-6);
    try testing.expectApproxEqAbs(v.z, w.z, 1e-6);
}

test "aabb transform and ray tests" {
    const b: Aabb = .{ .min = .new(-1, -1, -1), .max = .new(1, 1, 1) };
    const t = b.transform(Mat4.translation(.new(10, 0, 0)).mul(Mat4.rotationY(std.math.pi / 4.0)));
    try testing.expectApproxEqAbs(@as(f32, 10 + std.math.sqrt2), t.max.x, 1e-5);
    const r: Ray = .{ .origin = .new(-5, 0, 0), .dir = .new(1, 0, 0) };
    try testing.expectApproxEqAbs(@as(f32, 4), r.intersectAabb(b, 1e9).?, 1e-6);
    try testing.expect(r.intersectAabb(.{ .min = .new(-1, 2, -1), .max = .new(1, 3, 1) }, 1e9) == null);
    const hit = r.intersectTriangle(.new(0, -1, -1), .new(0, 1, -1), .new(0, 0, 2)).?;
    try testing.expectApproxEqAbs(@as(f32, 5), hit.t, 1e-6);
    const down: Ray = .{ .origin = .new(1, 5, 2), .dir = .new(0, -2, 0) };
    const g = down.intersectGround(0.5).?;
    try testing.expectApproxEqAbs(@as(f32, 0.5), g.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), g.z, 1e-6);
}

test "frustum culls boxes outside the view" {
    const vp = Mat4.perspectiveReverseZ(std.math.pi / 2.0, 1, 0.1, 100, false).mul(Mat4.lookAt(.zero, .new(0, 0, -1), .up));
    const f = Frustum.fromMatrix(vp);
    try testing.expect(f.intersectsAabb(.{ .min = .new(-1, -1, -6), .max = .new(1, 1, -4) }));
    try testing.expect(!f.intersectsAabb(.{ .min = .new(-1, -1, 4), .max = .new(1, 1, 6) }));
    try testing.expect(!f.intersectsAabb(.{ .min = .new(20, -1, -6), .max = .new(22, 1, -4) }));
    try testing.expect(!f.intersectsAabb(.{ .min = .new(-1, -1, -300), .max = .new(1, 1, -200) }));
}

test "srgb helpers" {
    try testing.expectApproxEqAbs(@as(f32, 0.5), linearToSrgb(srgbToLinear(0.5)), 1e-6);
    const c = hexToLinear("#ffffff").?;
    try testing.expectApproxEqAbs(@as(f32, 1), c[0], 1e-6);
    try testing.expect(hexToLinear("#fff") == null);
}
