//! `Gfx3D`: the backend-agnostic resource store for zpui.three (like `Atlas`
//! for sprites). It owns CPU copies of meshes and textures until a renderer
//! uploads them to persistent GPU buffers; renderers mirror its slots by
//! index + generation and drain `pending`/`released` once per frame.
//!
//! Mesh input fits procedural geometry without repacking: every vertex
//! attribute is a separate tightly packed stream (positions, normals, uvs,
//! colors, ids), so buffers produced elsewhere (e.g. a binary geometry format
//! with `VPOS`/`VNRM`/`VUV0`/`VFEA` sections) can be passed as they are.
//!
//! Threading: a store is used from one thread (the UI thread), and drawn by one
//! renderer (one window). Handles stay valid until `destroy`; GPU objects are
//! released by the renderer after the frames that used them have completed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("math.zig");
const Vec3 = math.Vec3;
const Aabb = math.Aabb;

/// Generational handle: low 20 bits slot index + 1 (0 = none), high 12 bits generation.
fn Handle(comptime tag: @EnumLiteral()) type {
    return enum(u32) {
        none = 0,
        _,

        const Self = @This();
        pub const kind = tag;

        pub fn make(index: u32, gen: u32) Self {
            return @enumFromInt(((gen & 0xfff) << 20) | (index + 1));
        }
        pub fn slot(self: Self) ?u32 {
            const v = @intFromEnum(self) & 0xfffff;
            return if (v == 0) null else v - 1;
        }
        pub fn generation(self: Self) u32 {
            return @intFromEnum(self) >> 20;
        }
    };
}

pub const MeshId = Handle(.mesh);
pub const TextureId = Handle(.texture);

/// Per-vertex integer attribute (feature / part / object ids), read by the
/// shaders (palette lookup, highlight) and returned by picking.
pub const Ids = union(enum) {
    none,
    u8: []const u8,
    u16: []const u16,
    u32: []const u32,

    pub fn len(self: Ids) usize {
        return switch (self) {
            .none => 0,
            inline else => |s| s.len,
        };
    }
    pub fn get(self: Ids, i: usize) u32 {
        return switch (self) {
            .none => 0,
            inline else => |s| s[i],
        };
    }
    pub fn format(self: Ids) IdFormat {
        return switch (self) {
            .none => .none,
            .u8 => .u8,
            .u16 => .u16,
            .u32 => .u32,
        };
    }
};

pub const IdFormat = enum(u2) { none = 0, u8 = 1, u16 = 2, u32 = 3 };

pub const MeshDesc = struct {
    /// Required, `vertex_count` entries.
    positions: []const [3]f32,
    /// Unit normals. Without them shading uses flat (screen-derivative) normals.
    normals: ?[]const [3]f32 = null,
    uvs: ?[]const [2]f32 = null,
    /// sRGB-encoded RGBA8 per vertex; multiplies the material base color.
    colors: ?[]const [4]u8 = null,
    ids: Ids = .none,
    /// Triangle list, counter-clockwise seen from the front.
    indices: []const u32,
    /// Keep positions/indices/ids on the CPU after upload (needed for `Scene3D.pick`
    /// to test this mesh's triangles; otherwise picks use its bounds only).
    keep_cpu: bool = false,
    label: []const u8 = "",
};

pub const TextureFormat = enum(u8) {
    /// Color data (base color, palettes): sampled as linear.
    rgba8_srgb,
    /// Non-color data (roughness/metal maps, masks).
    rgba8_unorm,
};

pub const Filter = enum(u8) { linear, nearest };
pub const Wrap = enum(u8) { repeat, clamp };

pub const TextureDesc = struct {
    width: u32,
    height: u32,
    format: TextureFormat = .rgba8_srgb,
    /// Tightly packed RGBA8 rows, top row first.
    data: []const u8,
    /// Generate a full mip chain on the CPU (box filter, sRGB-aware).
    mipmaps: bool = true,
    filter: Filter = .linear,
    wrap: Wrap = .repeat,
    label: []const u8 = "",
};

/// A coarser stand-in for a mesh, used for instances that cover few pixels.
pub const Lod = struct {
    mesh: MeshId,
    /// Used while the instance's projected bounding-sphere diameter is at most
    /// this many pixels (device pixels; shadow-map texels in the shadow pass).
    max_pixels: f32,
};

pub const max_lods = 3;

pub const Mesh = struct {
    generation: u32 = 0,
    live: bool = false,
    vertex_count: u32 = 0,
    index_count: u32 = 0,
    bounds: Aabb = .empty,
    has_normals: bool = false,
    has_uvs: bool = false,
    has_colors: bool = false,
    id_format: IdFormat = .none,
    keep_cpu: bool = false,
    /// CPU data: present until uploaded (then freed unless `keep_cpu`).
    cpu: ?MeshData = null,
    uploaded: bool = false,
    /// Coarser levels, `max_pixels` descending (see `Gfx3D.setLods`).
    lods: [max_lods]Lod = undefined,
    lod_count: u8 = 0,

    pub fn lodSlice(self: *const Mesh) []const Lod {
        return self.lods[0..self.lod_count];
    }
};

/// Owned copies of a mesh's streams (one allocation).
pub const MeshData = struct {
    bytes: []align(16) u8,
    positions: []const [3]f32,
    normals: []const [3]f32,
    uvs: []const [2]f32,
    colors: []const [4]u8,
    /// Raw id stream (`id_format`-sized elements).
    ids: []const u8,
    indices: []const u32,

    pub fn id(self: *const MeshData, format: IdFormat, i: usize) u32 {
        return switch (format) {
            .none => 0,
            .u8 => self.ids[i],
            .u16 => std.mem.readInt(u16, self.ids[i * 2 ..][0..2], .little),
            .u32 => std.mem.readInt(u32, self.ids[i * 4 ..][0..4], .little),
        };
    }
};

pub const Texture = struct {
    generation: u32 = 0,
    live: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    format: TextureFormat = .rgba8_srgb,
    filter: Filter = .linear,
    wrap: Wrap = .repeat,
    mip_levels: u32 = 1,
    /// All mip levels back to back (level 0 first); freed after upload.
    cpu: ?[]u8 = null,
    uploaded: bool = false,

    pub fn mipSize(self: *const Texture, level: u32) [2]u32 {
        return .{ @max(self.width >> @intCast(level), 1), @max(self.height >> @intCast(level), 1) };
    }
};

pub const Released = union(enum) { mesh: u32, texture: u32 };

pub const Gfx3D = struct {
    gpa: Allocator,
    meshes: std.ArrayList(Mesh) = .empty,
    textures: std.ArrayList(Texture) = .empty,
    free_meshes: std.ArrayList(u32) = .empty,
    free_textures: std.ArrayList(u32) = .empty,
    /// Slots created or replaced since the renderer last synced.
    pending_meshes: std.ArrayList(u32) = .empty,
    pending_textures: std.ArrayList(u32) = .empty,
    /// Slots whose GPU objects the renderer should free (after in-flight frames).
    released: std.ArrayList(Released) = .empty,
    /// Bumped on every create/destroy (renderers use it to notice changes cheaply).
    revision: u64 = 0,

    pub fn init(gpa: Allocator) Gfx3D {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Gfx3D) void {
        for (self.meshes.items) |*m| if (m.cpu) |d| self.gpa.free(d.bytes);
        for (self.textures.items) |*t| if (t.cpu) |d| self.gpa.free(d);
        self.meshes.deinit(self.gpa);
        self.textures.deinit(self.gpa);
        self.free_meshes.deinit(self.gpa);
        self.free_textures.deinit(self.gpa);
        self.pending_meshes.deinit(self.gpa);
        self.pending_textures.deinit(self.gpa);
        self.released.deinit(self.gpa);
        self.* = undefined;
    }

    // -- meshes -----------------------------------------------------------

    pub const MeshError = Allocator.Error || error{ InvalidMesh, TooManyResources };

    /// Copy `desc` into the store and queue it for upload.
    pub fn createMesh(self: *Gfx3D, desc: MeshDesc) MeshError!MeshId {
        const n = desc.positions.len;
        if (n == 0 or desc.indices.len == 0 or desc.indices.len % 3 != 0) return error.InvalidMesh;
        if (desc.normals) |s| if (s.len != n) return error.InvalidMesh;
        if (desc.uvs) |s| if (s.len != n) return error.InvalidMesh;
        if (desc.colors) |s| if (s.len != n) return error.InvalidMesh;
        if (desc.ids != .none and desc.ids.len() != n) return error.InvalidMesh;
        for (desc.indices) |i| if (i >= n) return error.InvalidMesh;

        const data = try copyMesh(self.gpa, desc);
        errdefer self.gpa.free(data.bytes);
        var bounds: Aabb = .empty;
        for (desc.positions) |p| bounds = bounds.extend(.fromArray(p));

        const slot = try self.allocSlot(Mesh, &self.meshes, &self.free_meshes);
        const m = &self.meshes.items[slot];
        m.* = .{
            .generation = m.generation,
            .live = true,
            .vertex_count = @intCast(n),
            .index_count = @intCast(desc.indices.len),
            .bounds = bounds,
            .has_normals = desc.normals != null,
            .has_uvs = desc.uvs != null,
            .has_colors = desc.colors != null,
            .id_format = desc.ids.format(),
            .keep_cpu = desc.keep_cpu,
            .cpu = data,
        };
        try self.pending_meshes.append(self.gpa, slot);
        self.revision += 1;
        return .make(slot, m.generation);
    }

    pub fn mesh(self: *const Gfx3D, h: MeshId) ?*const Mesh {
        const slot = h.slot() orelse return null;
        if (slot >= self.meshes.items.len) return null;
        const m = &self.meshes.items[slot];
        if (!m.live or (m.generation & 0xfff) != h.generation()) return null;
        return m;
    }

    /// Give `h` up to `max_lods` coarser levels. Draws of `h` then pick a level
    /// per instance from its projected size; draws with an explicit index
    /// range always use `h`. LOD meshes should share `h`'s bounds and look.
    pub fn setLods(self: *Gfx3D, h: MeshId, lods: []const Lod) error{ InvalidMesh, TooManyLods }!void {
        const slot = h.slot() orelse return error.InvalidMesh;
        if (self.mesh(h) == null) return error.InvalidMesh;
        if (lods.len > max_lods) return error.TooManyLods;
        const m = &self.meshes.items[slot];
        @memcpy(m.lods[0..lods.len], lods);
        m.lod_count = @intCast(lods.len);
        std.mem.sort(Lod, m.lods[0..lods.len], {}, struct {
            fn gt(_: void, a: Lod, b: Lod) bool {
                return a.max_pixels > b.max_pixels;
            }
        }.gt);
        self.revision += 1;
    }

    pub fn destroyMesh(self: *Gfx3D, h: MeshId) void {
        const slot = h.slot() orelse return;
        if (self.mesh(h) == null) return;
        const m = &self.meshes.items[slot];
        if (m.cpu) |d| self.gpa.free(d.bytes);
        const was_uploaded = m.uploaded;
        m.* = .{ .generation = m.generation +% 1 };
        if (was_uploaded) self.released.append(self.gpa, .{ .mesh = slot }) catch {};
        removeValue(&self.pending_meshes, slot);
        self.free_meshes.append(self.gpa, slot) catch {};
        self.revision += 1;
    }

    /// Called by the renderer once a mesh's GPU buffers hold its data.
    pub fn markMeshUploaded(self: *Gfx3D, slot: u32) void {
        const m = &self.meshes.items[slot];
        m.uploaded = true;
        if (!m.keep_cpu) if (m.cpu) |d| {
            self.gpa.free(d.bytes);
            m.cpu = null;
        };
    }

    // -- textures ---------------------------------------------------------

    pub const TextureError = Allocator.Error || error{ InvalidTexture, TooManyResources };

    pub fn createTexture(self: *Gfx3D, desc: TextureDesc) TextureError!TextureId {
        if (desc.width == 0 or desc.height == 0 or desc.data.len != @as(usize, desc.width) * desc.height * 4) return error.InvalidTexture;
        const levels: u32 = if (desc.mipmaps) std.math.log2_int(u32, @max(desc.width, desc.height)) + 1 else 1;
        var total: usize = 0;
        for (0..levels) |l| total += @as(usize, @max(desc.width >> @intCast(l), 1)) * @max(desc.height >> @intCast(l), 1) * 4;
        const bytes = try self.gpa.alloc(u8, total);
        errdefer self.gpa.free(bytes);
        @memcpy(bytes[0..desc.data.len], desc.data);
        buildMips(bytes, desc.width, desc.height, levels, desc.format == .rgba8_srgb);

        const slot = try self.allocSlot(Texture, &self.textures, &self.free_textures);
        const t = &self.textures.items[slot];
        t.* = .{
            .generation = t.generation,
            .live = true,
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .filter = desc.filter,
            .wrap = desc.wrap,
            .mip_levels = levels,
            .cpu = bytes,
        };
        try self.pending_textures.append(self.gpa, slot);
        self.revision += 1;
        return .make(slot, t.generation);
    }

    pub fn texture(self: *const Gfx3D, h: TextureId) ?*const Texture {
        const slot = h.slot() orelse return null;
        if (slot >= self.textures.items.len) return null;
        const t = &self.textures.items[slot];
        if (!t.live or (t.generation & 0xfff) != h.generation()) return null;
        return t;
    }

    pub fn destroyTexture(self: *Gfx3D, h: TextureId) void {
        const slot = h.slot() orelse return;
        if (self.texture(h) == null) return;
        const t = &self.textures.items[slot];
        if (t.cpu) |d| self.gpa.free(d);
        const was_uploaded = t.uploaded;
        t.* = .{ .generation = t.generation +% 1 };
        if (was_uploaded) self.released.append(self.gpa, .{ .texture = slot }) catch {};
        removeValue(&self.pending_textures, slot);
        self.free_textures.append(self.gpa, slot) catch {};
        self.revision += 1;
    }

    pub fn markTextureUploaded(self: *Gfx3D, slot: u32) void {
        const t = &self.textures.items[slot];
        t.uploaded = true;
        if (t.cpu) |d| {
            self.gpa.free(d);
            t.cpu = null;
        }
    }

    /// Generic destroy for either handle type.
    pub fn destroy(self: *Gfx3D, h: anytype) void {
        switch (@TypeOf(h)) {
            MeshId => self.destroyMesh(h),
            TextureId => self.destroyTexture(h),
            else => @compileError("Gfx3D.destroy: expected a MeshId or TextureId"),
        }
    }

    // -- internals --------------------------------------------------------

    fn allocSlot(self: *Gfx3D, comptime T: type, list: *std.ArrayList(T), free: *std.ArrayList(u32)) error{ OutOfMemory, TooManyResources }!u32 {
        if (free.pop()) |s| return s;
        if (list.items.len >= (1 << 20) - 1) return error.TooManyResources;
        try list.append(self.gpa, .{});
        return @intCast(list.items.len - 1);
    }
};

fn removeValue(list: *std.ArrayList(u32), v: u32) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i] == v) _ = list.swapRemove(i) else i += 1;
    }
}

fn copyMesh(gpa: Allocator, desc: MeshDesc) Allocator.Error!MeshData {
    const n = desc.positions.len;
    const id_size: usize = switch (desc.ids) {
        .none => 0,
        .u8 => 1,
        .u16 => 2,
        .u32 => 4,
    };
    const sizes = [_]usize{
        n * 12,
        if (desc.normals != null) n * 12 else 0,
        if (desc.uvs != null) n * 8 else 0,
        if (desc.colors != null) n * 4 else 0,
        n * id_size,
        desc.indices.len * 4,
    };
    var offsets: [sizes.len]usize = undefined;
    var total: usize = 0;
    for (sizes, 0..) |s, i| {
        offsets[i] = total;
        total += std.mem.alignForward(usize, s, 16);
    }
    const bytes = try gpa.alignedAlloc(u8, .@"16", total);
    @memcpy(bytes[offsets[0]..][0..sizes[0]], std.mem.sliceAsBytes(desc.positions));
    if (desc.normals) |s| @memcpy(bytes[offsets[1]..][0..sizes[1]], std.mem.sliceAsBytes(s));
    if (desc.uvs) |s| @memcpy(bytes[offsets[2]..][0..sizes[2]], std.mem.sliceAsBytes(s));
    if (desc.colors) |s| @memcpy(bytes[offsets[3]..][0..sizes[3]], std.mem.sliceAsBytes(s));
    switch (desc.ids) {
        .none => {},
        inline else => |s| @memcpy(bytes[offsets[4]..][0..sizes[4]], std.mem.sliceAsBytes(s)),
    }
    @memcpy(bytes[offsets[5]..][0..sizes[5]], std.mem.sliceAsBytes(desc.indices));
    return .{
        .bytes = bytes,
        .positions = @alignCast(std.mem.bytesAsSlice([3]f32, bytes[offsets[0]..][0..sizes[0]])),
        .normals = @alignCast(std.mem.bytesAsSlice([3]f32, bytes[offsets[1]..][0..sizes[1]])),
        .uvs = @alignCast(std.mem.bytesAsSlice([2]f32, bytes[offsets[2]..][0..sizes[2]])),
        .colors = @alignCast(std.mem.bytesAsSlice([4]u8, bytes[offsets[3]..][0..sizes[3]])),
        .ids = bytes[offsets[4]..][0..sizes[4]],
        .indices = @alignCast(std.mem.bytesAsSlice(u32, bytes[offsets[5]..][0..sizes[5]])),
    };
}

/// Fill levels 1.. of a packed RGBA8 mip chain with a 2x2 box filter
/// (in linear space for sRGB data; alpha is always linear).
fn buildMips(bytes: []u8, width: u32, height: u32, levels: u32, srgb: bool) void {
    var src_off: usize = 0;
    var w = width;
    var h = height;
    var lut: [256]f32 = undefined;
    for (&lut, 0..) |*v, i| v.* = if (srgb) math.srgbToLinear(@as(f32, @floatFromInt(i)) / 255) else @as(f32, @floatFromInt(i)) / 255;
    for (1..levels) |_| {
        const nw = @max(w / 2, 1);
        const nh = @max(h / 2, 1);
        const dst_off = src_off + @as(usize, w) * h * 4;
        for (0..nh) |y| for (0..nw) |x| {
            var acc: [4]f32 = .{ 0, 0, 0, 0 };
            for (0..2) |dy| for (0..2) |dx| {
                const sx = @min(x * 2 + dx, w - 1);
                const sy = @min(y * 2 + dy, h - 1);
                const p = bytes[src_off + (sy * w + sx) * 4 ..][0..4];
                for (0..3) |k| acc[k] += lut[p[k]];
                acc[3] += @as(f32, @floatFromInt(p[3])) / 255;
            };
            const d = bytes[dst_off + (y * nw + x) * 4 ..][0..4];
            for (0..3) |k| {
                const v = acc[k] / 4;
                d[k] = @intFromFloat(@round(std.math.clamp(if (srgb) math.linearToSrgb(v) else v, 0, 1) * 255));
            }
            d[3] = @intFromFloat(@round(std.math.clamp(acc[3] / 4, 0, 1) * 255));
        };
        src_off = dst_off;
        w = nw;
        h = nh;
    }
}

const testing = std.testing;

test "mesh lifecycle: create, upload, destroy, slot reuse" {
    var g = Gfx3D.init(testing.allocator);
    defer g.deinit();
    const pos = [_][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 2, 0 } };
    const feats = [_]u8{ 7, 8, 9 };
    const a = try g.createMesh(.{ .positions = &pos, .ids = .{ .u8 = &feats }, .indices = &.{ 0, 1, 2 }, .keep_cpu = true });
    const m = g.mesh(a).?;
    try testing.expectEqual(@as(u32, 3), m.vertex_count);
    try testing.expectEqual(IdFormat.u8, m.id_format);
    try testing.expectApproxEqAbs(@as(f32, 2), m.bounds.max.y, 0);
    try testing.expectEqual(@as(u32, 9), m.cpu.?.id(.u8, 2));
    try testing.expectEqualSlices(u32, &.{0}, g.pending_meshes.items);

    g.markMeshUploaded(0);
    try testing.expect(g.mesh(a).?.cpu != null); // keep_cpu
    g.pending_meshes.clearRetainingCapacity();

    g.destroy(a);
    try testing.expect(g.mesh(a) == null);
    try testing.expectEqual(Released{ .mesh = 0 }, g.released.items[0]);

    const b = try g.createMesh(.{ .positions = &pos, .indices = &.{ 0, 2, 1 } });
    try testing.expectEqual(@as(?u32, 0), b.slot());
    try testing.expect(a != b);
    try testing.expect(g.mesh(a) == null);
    g.markMeshUploaded(0);
    try testing.expect(g.mesh(b).?.cpu == null);
}

test "mesh validation" {
    var g = Gfx3D.init(testing.allocator);
    defer g.deinit();
    const pos = [_][3]f32{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    try testing.expectError(error.InvalidMesh, g.createMesh(.{ .positions = &pos, .indices = &.{ 0, 1, 3 } }));
    try testing.expectError(error.InvalidMesh, g.createMesh(.{ .positions = &pos, .indices = &.{ 0, 1 } }));
    try testing.expectError(error.InvalidMesh, g.createMesh(.{ .positions = &pos, .normals = pos[0..2], .indices = &.{ 0, 1, 2 } }));
    try testing.expectError(error.InvalidMesh, g.createMesh(.{ .positions = &pos, .ids = .{ .u16 = &.{1} }, .indices = &.{ 0, 1, 2 } }));
}

test "texture mip chain" {
    var g = Gfx3D.init(testing.allocator);
    defer g.deinit();
    var px: [4 * 4 * 4]u8 = undefined;
    for (0..16) |i| px[i * 4 ..][0..4].* = if (i % 2 == 0) .{ 255, 255, 255, 255 } else .{ 0, 0, 0, 255 };
    const t = try g.createTexture(.{ .width = 4, .height = 4, .data = &px, .format = .rgba8_unorm });
    const tex = g.texture(t).?;
    try testing.expectEqual(@as(u32, 3), tex.mip_levels);
    try testing.expectEqual(@as(usize, (16 + 4 + 1) * 4), tex.cpu.?.len);
    // Level 1 averages black and white columns to mid grey.
    try testing.expectEqual(@as(u8, 128), tex.cpu.?[64]);
    try testing.expectEqual(@as(u8, 255), tex.cpu.?[67]);
    try testing.expectError(error.InvalidTexture, g.createTexture(.{ .width = 2, .height = 2, .data = px[0..4] }));
}
