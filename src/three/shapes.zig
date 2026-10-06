//! Procedural meshes (boxes, planes, spheres, cylinders) for demos, tests and
//! simple props. Each returns owned streams; `desc()` feeds `Gfx3D.createMesh`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("math.zig");
const gfx = @import("gfx.zig");
const Vec3 = math.Vec3;

pub const Shape = struct {
    positions: [][3]f32,
    normals: [][3]f32,
    uvs: [][2]f32,
    indices: []u32,

    pub fn deinit(self: *Shape, gpa: Allocator) void {
        gpa.free(self.positions);
        gpa.free(self.normals);
        gpa.free(self.uvs);
        gpa.free(self.indices);
        self.* = undefined;
    }

    pub fn desc(self: *const Shape) gfx.MeshDesc {
        return .{ .positions = self.positions, .normals = self.normals, .uvs = self.uvs, .indices = self.indices };
    }

    fn alloc(gpa: Allocator, vertices: usize, indices: usize) Allocator.Error!Shape {
        const p = try gpa.alloc([3]f32, vertices);
        errdefer gpa.free(p);
        const n = try gpa.alloc([3]f32, vertices);
        errdefer gpa.free(n);
        const t = try gpa.alloc([2]f32, vertices);
        errdefer gpa.free(t);
        return .{ .positions = p, .normals = n, .uvs = t, .indices = try gpa.alloc(u32, indices) };
    }
};

/// Box centered at the origin; faces in the order +X, -X, +Y, -Y, +Z, -Z
/// (4 vertices each, so vertex `i` belongs to face `i / 4`).
pub fn box(gpa: Allocator, size: [3]f32) Allocator.Error!Shape {
    var s = try Shape.alloc(gpa, 24, 36);
    const faces = [6][2][3]f32{
        .{ .{ 1, 0, 0 }, .{ 0, 1, 0 } },  .{ .{ -1, 0, 0 }, .{ 0, 1, 0 } },
        .{ .{ 0, 1, 0 }, .{ 0, 0, -1 } }, .{ .{ 0, -1, 0 }, .{ 0, 0, 1 } },
        .{ .{ 0, 0, 1 }, .{ 0, 1, 0 } },  .{ .{ 0, 0, -1 }, .{ 0, 1, 0 } },
    };
    const half = Vec3.new(size[0] / 2, size[1] / 2, size[2] / 2);
    for (faces, 0..) |f, i| {
        const n = Vec3.fromArray(f[0]);
        const up = Vec3.fromArray(f[1]);
        const right = up.cross(n);
        const corners = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
        for (corners, 0..) |cr, j| {
            const p = n.add(right.scale(cr[0])).add(up.scale(cr[1])).mulv(half);
            s.positions[i * 4 + j] = p.toArray();
            s.normals[i * 4 + j] = f[0];
            s.uvs[i * 4 + j] = .{ (cr[0] + 1) / 2, (1 - cr[1]) / 2 };
        }
        const b: u32 = @intCast(i * 4);
        // right x up = n, so (corner order) is counter-clockwise seen from outside.
        s.indices[i * 6 ..][0..6].* = .{ b, b + 1, b + 2, b, b + 2, b + 3 };
    }
    return s;
}

/// `width` x `depth` plane in XZ facing +Y, centered, `segments` quads per side.
/// uv (0,0) at (-x, -z).
pub fn plane(gpa: Allocator, width: f32, depth: f32, segments: u32) Allocator.Error!Shape {
    const n = @max(segments, 1);
    const verts = (n + 1) * (n + 1);
    var s = try Shape.alloc(gpa, verts, n * n * 6);
    for (0..n + 1) |i| for (0..n + 1) |j| {
        const u = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const v = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(n));
        const k = i * (n + 1) + j;
        s.positions[k] = .{ -width / 2 + width * u, 0, -depth / 2 + depth * v };
        s.normals[k] = .{ 0, 1, 0 };
        s.uvs[k] = .{ u, v };
    };
    var o: usize = 0;
    for (0..n) |i| for (0..n) |j| {
        const a: u32 = @intCast(i * (n + 1) + j);
        const b = a + 1;
        const c: u32 = @intCast((i + 1) * (n + 1) + j + 1);
        const d = c - 1;
        s.indices[o..][0..6].* = .{ a, b, c, a, c, d };
        o += 6;
    };
    return s;
}

/// UV sphere of `radius`.
pub fn sphere(gpa: Allocator, radius: f32, rings: u32, sectors: u32) Allocator.Error!Shape {
    const r = @max(rings, 2);
    const sc = @max(sectors, 3);
    var s = try Shape.alloc(gpa, (r + 1) * (sc + 1), r * sc * 6);
    for (0..r + 1) |i| for (0..sc + 1) |j| {
        const v = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(r));
        const u = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(sc));
        const theta = v * std.math.pi;
        const phi = u * 2 * std.math.pi;
        const nrm = Vec3.new(@sin(theta) * @sin(phi), @cos(theta), @sin(theta) * @cos(phi));
        const k = i * (sc + 1) + j;
        s.positions[k] = nrm.scale(radius).toArray();
        s.normals[k] = nrm.toArray();
        s.uvs[k] = .{ u, v };
    };
    var o: usize = 0;
    for (0..r) |i| for (0..sc) |j| {
        const a: u32 = @intCast(i * (sc + 1) + j);
        const b: u32 = @intCast((i + 1) * (sc + 1) + j);
        s.indices[o..][0..6].* = .{ a, b, b + 1, a, b + 1, a + 1 };
        o += 6;
    };
    return s;
}

/// Capped cylinder along +Y from y = 0 to `height`.
pub fn cylinder(gpa: Allocator, radius: f32, height: f32, sectors: u32) Allocator.Error!Shape {
    const sc = @max(sectors, 3);
    // side: 2 rings of (sc+1); caps: center + ring each
    const side_v = 2 * (sc + 1);
    const cap_v = sc + 2;
    var s = try Shape.alloc(gpa, side_v + 2 * cap_v, sc * 6 + 2 * sc * 3);
    for (0..sc + 1) |j| {
        const u = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(sc));
        const phi = u * 2 * std.math.pi;
        const nrm = Vec3.new(@sin(phi), 0, @cos(phi));
        for (0..2) |k| {
            const idx = k * (sc + 1) + j;
            const y: f32 = if (k == 0) 0 else height;
            s.positions[idx] = .{ nrm.x * radius, y, nrm.z * radius };
            s.normals[idx] = nrm.toArray();
            s.uvs[idx] = .{ u, if (k == 0) 1 else 0 };
        }
    }
    var o: usize = 0;
    for (0..sc) |j| {
        const a: u32 = @intCast(j);
        const b: u32 = @intCast(sc + 1 + j);
        s.indices[o..][0..6].* = .{ a, a + 1, b + 1, a, b + 1, b };
        o += 6;
    }
    for (0..2) |cap| {
        const base: u32 = @intCast(side_v + cap * cap_v);
        const y: f32 = if (cap == 0) 0 else height;
        const ny: f32 = if (cap == 0) -1 else 1;
        s.positions[base] = .{ 0, y, 0 };
        s.normals[base] = .{ 0, ny, 0 };
        s.uvs[base] = .{ 0.5, 0.5 };
        for (0..sc + 1) |j| {
            const phi = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(sc)) * 2 * std.math.pi;
            const k = base + 1 + j;
            s.positions[k] = .{ @sin(phi) * radius, y, @cos(phi) * radius };
            s.normals[k] = .{ 0, ny, 0 };
            s.uvs[k] = .{ 0.5 + 0.5 * @sin(phi), 0.5 + 0.5 * @cos(phi) };
        }
        for (0..sc) |j| {
            const r0: u32 = base + 1 + @as(u32, @intCast(j));
            s.indices[o..][0..3].* = if (cap == 0) .{ base, r0 + 1, r0 } else .{ base, r0, r0 + 1 };
            o += 3;
        }
    }
    return s;
}

const testing = std.testing;

fn expectOutwardWinding(s: Shape) !void {
    var i: usize = 0;
    while (i < s.indices.len) : (i += 3) {
        const a = Vec3.fromArray(s.positions[s.indices[i]]);
        const b = Vec3.fromArray(s.positions[s.indices[i + 1]]);
        const c = Vec3.fromArray(s.positions[s.indices[i + 2]]);
        const n = b.sub(a).cross(c.sub(a));
        if (n.length() < 1e-6) continue; // degenerate pole triangles
        const avg = Vec3.fromArray(s.normals[s.indices[i]]).add(.fromArray(s.normals[s.indices[i + 1]])).add(.fromArray(s.normals[s.indices[i + 2]]));
        try testing.expect(n.dot(avg) > 0);
    }
}

test "shapes wind counter-clockwise seen from outside" {
    const gpa = testing.allocator;
    for (0..4) |k| {
        var s = switch (k) {
            0 => try box(gpa, .{ 1, 2, 3 }),
            1 => try plane(gpa, 2, 2, 3),
            2 => try sphere(gpa, 1, 6, 8),
            else => try cylinder(gpa, 0.5, 1, 8),
        };
        defer s.deinit(gpa);
        expectOutwardWinding(s) catch |err| {
            std.debug.print("shape {d} winds inward\n", .{k});
            return err;
        };
    }
}
