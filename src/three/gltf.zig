//! glTF 2.0 loading for zpui.three (vendored cgltf). Loads `.glb` or `.gltf`
//! with embedded (data-URI or GLB) buffers and images into a `Gfx3D` store:
//! one mesh per triangle primitive (POSITION, NORMAL, TEXCOORD_0, COLOR_0,
//! indices), metallic-roughness materials with base-color textures (PNG/JPEG
//! via stb_image), and the default scene flattened into (mesh, material,
//! world transform) items.
//!
//! Not covered: external files (pass the bytes of a .glb, or embed buffers),
//! skins, morph targets, animations, KHR extensions, and normal / occlusion /
//! metallic-roughness textures (the factors are used).
//!
//! ```zig
//! var model = try gltf.load(gpa, &gfx, bytes, .{});
//! defer model.deinit(&gfx);
//! try model.draw(&scene, Mat4.translation(.new(0, 0, 0)), .{ .pick_id = 7 });
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("cgltf_c");
const math = @import("math.zig");
const gfx_mod = @import("gfx.zig");
const scene_mod = @import("scene3d.zig");
const image_c = @import("../image/c.zig");
const Mat4 = math.Mat4;
const Aabb = math.Aabb;
const Gfx3D = gfx_mod.Gfx3D;

pub const Item = struct {
    mesh: gfx_mod.MeshId,
    material: scene_mod.Material,
    /// World transform of the node in the model's space.
    transform: Mat4,
};

pub const Model = struct {
    gpa: Allocator,
    items: []Item,
    meshes: []gfx_mod.MeshId,
    textures: []gfx_mod.TextureId,
    /// Bounds of all items in model space.
    bounds: Aabb,

    /// Destroys the model's meshes and textures in `gfx`.
    pub fn deinit(self: *Model, gfx: *Gfx3D) void {
        for (self.meshes) |m| gfx.destroy(m);
        for (self.textures) |t| gfx.destroy(t);
        self.gpa.free(self.items);
        self.gpa.free(self.meshes);
        self.gpa.free(self.textures);
        self.* = undefined;
    }

    pub const DrawOpts = struct {
        tint: [4]f32 = .{ 1, 1, 1, 1 },
        pick_id: u32 = 0,
        /// Replace the shading model of every material (e.g. `.toon`).
        shading: ?scene_mod.Shading = null,
        outline: ?scene_mod.Outline = null,
    };

    /// Draw every item with `transform` applied on top of its node transform.
    pub fn draw(self: *const Model, scene: *scene_mod.Scene3D, transform: Mat4, opts: DrawOpts) Allocator.Error!void {
        for (self.items) |it| {
            var mat = it.material;
            if (opts.shading) |s| mat.shading = s;
            if (opts.outline) |o| mat.outline = o;
            try scene.draw(it.mesh, transform.mul(it.transform), .{ .material = mat, .tint = opts.tint, .pick_id = opts.pick_id });
        }
    }
};

pub const Options = struct {
    /// Keep CPU copies for triangle picking.
    keep_cpu: bool = true,
};

pub const Error = Allocator.Error || Gfx3D.MeshError || Gfx3D.TextureError || error{ InvalidGltf, UnsupportedGltf };

pub fn load(gpa: Allocator, gfx: *Gfx3D, bytes: []const u8, opts: Options) Error!Model {
    var options: c.cgltf_options = std.mem.zeroes(c.cgltf_options);
    var data: ?*c.cgltf_data = null;
    if (c.cgltf_parse(&options, bytes.ptr, bytes.len, &data) != c.cgltf_result_success) return error.InvalidGltf;
    defer c.cgltf_free(data);
    const d = data.?;
    // Embedded buffers only: data URIs (decoded by cgltf) and the GLB BIN chunk.
    for (slice(d.buffers, d.buffers_count)) |*buf| {
        if (buf.data != null) continue;
        if (buf.uri == null) return error.UnsupportedGltf;
        const uri = buf.uri;
        if (!std.mem.startsWith(u8, std.mem.span(uri), "data:")) return error.UnsupportedGltf;
        const comma = std.mem.indexOfScalar(u8, std.mem.span(uri), ',') orelse return error.InvalidGltf;
        if (c.cgltf_load_buffer_base64(&options, buf.size, uri + comma + 1, &buf.data) != c.cgltf_result_success) return error.InvalidGltf;
        buf.data_free_method = c.cgltf_data_free_method_memory_free;
    }
    if (c.cgltf_validate(d) != c.cgltf_result_success) return error.InvalidGltf;

    var textures: std.ArrayList(gfx_mod.TextureId) = .empty;
    errdefer {
        for (textures.items) |t| gfx.destroy(t);
        textures.deinit(gpa);
    }
    // glTF texture index -> TextureId (none if the image could not be decoded).
    const tex_map = try gpa.alloc(gfx_mod.TextureId, d.textures_count);
    defer gpa.free(tex_map);
    for (slice(d.textures, d.textures_count), 0..) |*t, i| {
        tex_map[i] = .none;
        const img = opt(t.image) orelse continue;
        const tex = loadImage(gpa, gfx, &options, img, opt(t.sampler)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.scoped(.gltf).warn("texture {d}: {t}; using the base color factor only", .{ i, err });
                continue;
            },
        };
        tex_map[i] = tex;
        try textures.append(gpa, tex);
    }

    var meshes: std.ArrayList(gfx_mod.MeshId) = .empty;
    errdefer {
        for (meshes.items) |m| gfx.destroy(m);
        meshes.deinit(gpa);
    }
    // Per glTF mesh: range of (mesh, material) primitives.
    const Prim = struct { mesh: gfx_mod.MeshId, material: scene_mod.Material, bounds: Aabb };
    var prims: std.ArrayList(Prim) = .empty;
    defer prims.deinit(gpa);
    const mesh_first = try gpa.alloc(usize, d.meshes_count + 1);
    defer gpa.free(mesh_first);
    for (slice(d.meshes, d.meshes_count), 0..) |*m, mi| {
        mesh_first[mi] = prims.items.len;
        for (slice(m.primitives, m.primitives_count)) |*p| {
            if (p.type != c.cgltf_primitive_type_triangles) continue;
            const id = try loadPrimitive(gpa, gfx, p, opts) orelse continue;
            try meshes.append(gpa, id);
            try prims.append(gpa, .{ .mesh = id, .material = material(opt(p.material), d, tex_map), .bounds = gfx.mesh(id).?.bounds });
        }
    }
    mesh_first[d.meshes_count] = prims.items.len;

    // Flatten the default scene (or every root node).
    var items: std.ArrayList(Item) = .empty;
    errdefer items.deinit(gpa);
    var bounds: Aabb = .empty;
    const Walk = struct {
        fn node(n: *c.cgltf_node, data_: *c.cgltf_data, first: []const usize, prims_: []const Prim, out: *std.ArrayList(Item), b: *Aabb, a: Allocator) Allocator.Error!void {
            if (opt(n.mesh)) |m| {
                var w: [16]f32 = undefined;
                c.cgltf_node_transform_world(n, &w);
                const transform: Mat4 = .{ .m = @bitCast(w) };
                const mi = (@intFromPtr(m) - @intFromPtr(data_.meshes)) / @sizeOf(c.cgltf_mesh);
                for (prims_[first[mi]..first[mi + 1]]) |p| {
                    try out.append(a, .{ .mesh = p.mesh, .material = p.material, .transform = transform });
                    b.* = b.merge(p.bounds.transform(transform));
                }
            }
            for (slice(n.children, n.children_count)) |child| try node(child, data_, first, prims_, out, b, a);
        }
    };
    if (opt(d.scene) orelse (if (d.scenes_count > 0) &d.scenes[0] else null)) |s| {
        for (slice(s.nodes, s.nodes_count)) |n| try Walk.node(n, d, mesh_first, prims.items, &items, &bounds, gpa);
    } else {
        for (slice(d.nodes, d.nodes_count)) |*n| if (n.parent == null) try Walk.node(n, d, mesh_first, prims.items, &items, &bounds, gpa);
    }
    // No nodes at all: draw every primitive at the origin.
    if (items.items.len == 0) for (prims.items) |p| {
        try items.append(gpa, .{ .mesh = p.mesh, .material = p.material, .transform = Mat4.identity });
        bounds = bounds.merge(p.bounds);
    };

    return .{
        .gpa = gpa,
        .items = try items.toOwnedSlice(gpa),
        .meshes = try meshes.toOwnedSlice(gpa),
        .textures = try textures.toOwnedSlice(gpa),
        .bounds = bounds,
    };
}

fn material(m: ?*c.cgltf_material, d: *c.cgltf_data, tex_map: []const gfx_mod.TextureId) scene_mod.Material {
    var out: scene_mod.Material = .{};
    const mat = m orelse return out;
    if (mat.has_pbr_metallic_roughness != 0) {
        const pbr = mat.pbr_metallic_roughness;
        out.base_color = pbr.base_color_factor;
        out.metallic = pbr.metallic_factor;
        out.roughness = pbr.roughness_factor;
        if (opt(pbr.base_color_texture.texture)) |t| {
            const ti = (@intFromPtr(t) - @intFromPtr(d.textures)) / @sizeOf(c.cgltf_texture);
            out.base_color_texture = tex_map[ti];
        }
    }
    out.emissive = mat.emissive_factor;
    out.double_sided = mat.double_sided != 0;
    out.alpha_cutoff = mat.alpha_cutoff;
    out.alpha_mode = switch (mat.alpha_mode) {
        c.cgltf_alpha_mode_mask => .mask,
        c.cgltf_alpha_mode_blend => .blend,
        else => .@"opaque",
    };
    if (mat.unlit != 0) out.shading = .flat;
    return out;
}

fn loadPrimitive(gpa: Allocator, gfx: *Gfx3D, p: *c.cgltf_primitive, opts: Options) Error!?gfx_mod.MeshId {
    var pos_acc: ?*c.cgltf_accessor = null;
    var nrm_acc: ?*c.cgltf_accessor = null;
    var uv_acc: ?*c.cgltf_accessor = null;
    var col_acc: ?*c.cgltf_accessor = null;
    for (slice(p.attributes, p.attributes_count)) |a| switch (a.type) {
        c.cgltf_attribute_type_position => pos_acc = opt(a.data),
        c.cgltf_attribute_type_normal => nrm_acc = opt(a.data),
        c.cgltf_attribute_type_texcoord => if (a.index == 0) {
            uv_acc = opt(a.data);
        },
        c.cgltf_attribute_type_color => if (a.index == 0) {
            col_acc = opt(a.data);
        },
        else => {},
    };
    const pa = pos_acc orelse return null;
    const n = pa.count;
    if (n == 0) return null;

    const positions = try gpa.alloc([3]f32, n);
    defer gpa.free(positions);
    _ = c.cgltf_accessor_unpack_floats(pa, @ptrCast(positions.ptr), n * 3);
    var normals: ?[][3]f32 = null;
    defer if (normals) |s| gpa.free(s);
    if (nrm_acc) |a| if (a.count == n) {
        normals = try gpa.alloc([3]f32, n);
        _ = c.cgltf_accessor_unpack_floats(a, @ptrCast(normals.?.ptr), n * 3);
    };
    var uvs: ?[][2]f32 = null;
    defer if (uvs) |s| gpa.free(s);
    if (uv_acc) |a| if (a.count == n) {
        uvs = try gpa.alloc([2]f32, n);
        _ = c.cgltf_accessor_unpack_floats(a, @ptrCast(uvs.?.ptr), n * 2);
    };
    var colors: ?[][4]u8 = null;
    defer if (colors) |s| gpa.free(s);
    if (col_acc) |a| if (a.count == n) {
        const comps: usize = if (a.type == c.cgltf_type_vec4) 4 else 3;
        const tmp = try gpa.alloc(f32, n * comps);
        defer gpa.free(tmp);
        _ = c.cgltf_accessor_unpack_floats(a, tmp.ptr, n * comps);
        colors = try gpa.alloc([4]u8, n);
        for (colors.?, 0..) |*col, i| {
            // glTF colors are linear; zpui vertex colors are sRGB-encoded bytes.
            for (0..3) |k| col[k] = @intFromFloat(@round(std.math.clamp(math.linearToSrgb(tmp[i * comps + k]), 0, 1) * 255));
            col[3] = if (comps == 4) @intFromFloat(@round(std.math.clamp(tmp[i * comps + 3], 0, 1) * 255)) else 255;
        }
    };
    const indices = if (opt(p.indices)) |ia| blk: {
        const idx = try gpa.alloc(u32, ia.count);
        for (idx, 0..) |*v, i| v.* = @intCast(c.cgltf_accessor_read_index(ia, i));
        break :blk idx;
    } else blk: {
        const idx = try gpa.alloc(u32, n);
        for (idx, 0..) |*v, i| v.* = @intCast(i);
        break :blk idx;
    };
    defer gpa.free(indices);
    if (indices.len < 3) return null;
    return try gfx.createMesh(.{
        .positions = positions,
        .normals = normals,
        .uvs = uvs,
        .colors = colors,
        .indices = indices[0 .. indices.len / 3 * 3],
        .keep_cpu = opts.keep_cpu,
    });
}

fn loadImage(gpa: Allocator, gfx: *Gfx3D, options: *c.cgltf_options, img: *c.cgltf_image, sampler: ?*c.cgltf_sampler) !gfx_mod.TextureId {
    var bytes: []const u8 = undefined;
    var decoded_uri: ?*anyopaque = null;
    defer if (decoded_uri) |p| std.c.free(p);
    if (opt(img.buffer_view)) |view| {
        const ptr = c.cgltf_buffer_view_data(view);
        if (ptr == null) return error.InvalidGltf;
        bytes = ptr[0..view.size];
    } else if (img.uri != null) {
        const uri_z = img.uri;
        const uri = std.mem.span(uri_z);
        if (!std.mem.startsWith(u8, uri, "data:")) return error.UnsupportedGltf;
        const comma = std.mem.indexOfScalar(u8, uri, ',') orelse return error.InvalidGltf;
        const b64 = uri[comma + 1 ..];
        const size = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return error.InvalidGltf;
        if (c.cgltf_load_buffer_base64(options, size, b64.ptr, &decoded_uri) != c.cgltf_result_success) return error.InvalidGltf;
        bytes = @as([*]const u8, @ptrCast(decoded_uri.?))[0..size];
    } else return error.InvalidGltf;

    var w: c_int = 0;
    var h: c_int = 0;
    const px = image_c.zpui_stbi_load_rgba(bytes.ptr, @intCast(bytes.len), &w, &h) orelse return error.UnsupportedGltf;
    defer image_c.zpui_decode_free(px);
    _ = gpa;
    var wrap: gfx_mod.Wrap = .repeat;
    var filter: gfx_mod.Filter = .linear;
    if (sampler) |s| {
        if (s.wrap_s == 33071) wrap = .clamp; // CLAMP_TO_EDGE
        if (s.mag_filter == 9728) filter = .nearest; // NEAREST
    }
    const len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    return gfx.createTexture(.{ .width = @intCast(w), .height = @intCast(h), .data = px[0..len], .wrap = wrap, .filter = filter });
}

/// A cgltf (pointer, count) pair as a slice (the pointer is null when empty).
fn slice(p: anytype, n: usize) []@typeInfo(@TypeOf(p)).pointer.child {
    if (n == 0) return &.{};
    return p[0..n];
}

/// cgltf's translated `[*c]T` fields as optionals.
fn opt(p: anytype) ?*@typeInfo(@TypeOf(p)).pointer.child {
    return p;
}

const testing = std.testing;

test "load an embedded glTF: two nodes sharing a mesh, material factors" {
    // One triangle (positions + normals) and u16 indices in a data-URI buffer.
    const positions = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const normals = [_]f32{ 0, 0, 1, 0, 0, 1, 0, 0, 1 };
    const indices = [_]u16{ 0, 1, 2, 0 }; // padded to 4 bytes
    var raw: [36 + 36 + 8]u8 = undefined;
    @memcpy(raw[0..36], std.mem.sliceAsBytes(&positions));
    @memcpy(raw[36..72], std.mem.sliceAsBytes(&normals));
    @memcpy(raw[72..80], std.mem.sliceAsBytes(&indices));
    var b64: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b64, &raw);
    const json = try std.fmt.allocPrint(testing.allocator,
        \\{{"asset":{{"version":"2.0"}},"scene":0,"scenes":[{{"nodes":[0,1]}}],
        \\"nodes":[{{"mesh":0}},{{"mesh":0,"translation":[5,0,0],"children":[2]}},{{"mesh":0,"scale":[2,2,2]}}],
        \\"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0,"NORMAL":1}},"indices":2,"material":0}}]}}],
        \\"materials":[{{"pbrMetallicRoughness":{{"baseColorFactor":[1,0.5,0.25,1],"metallicFactor":0.2,"roughnessFactor":0.4}},"doubleSided":true}}],
        \\"accessors":[
        \\{{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]}},
        \\{{"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"}},
        \\{{"bufferView":2,"componentType":5123,"count":3,"type":"SCALAR"}}],
        \\"bufferViews":[{{"buffer":0,"byteOffset":0,"byteLength":36}},{{"buffer":0,"byteOffset":36,"byteLength":36}},{{"buffer":0,"byteOffset":72,"byteLength":6}}],
        \\"buffers":[{{"byteLength":80,"uri":"data:application/octet-stream;base64,{s}"}}]}}
    , .{b64});
    defer testing.allocator.free(json);

    var g = Gfx3D.init(testing.allocator);
    defer g.deinit();
    var model = try load(testing.allocator, &g, json, .{});
    defer model.deinit(&g);
    try testing.expectEqual(@as(usize, 1), model.meshes.len);
    try testing.expectEqual(@as(usize, 3), model.items.len);
    const m = model.items[0].material;
    try testing.expectApproxEqAbs(@as(f32, 0.5), m.base_color[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.4), m.roughness, 1e-6);
    try testing.expect(m.double_sided);
    // Child of the translated node inherits its translation and adds its scale.
    try testing.expectApproxEqAbs(@as(f32, 5), model.items[2].transform.m[3][0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2), model.items[2].transform.m[0][0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 7), model.bounds.max.x, 1e-5);
    const mesh = g.mesh(model.meshes[0]).?;
    try testing.expect(mesh.has_normals and mesh.index_count == 3);

    var s = scene_mod.Scene3D.init(testing.allocator, &g);
    defer s.deinit();
    try model.draw(&s, Mat4.identity, .{ .pick_id = 4 });
    try testing.expectEqual(@as(usize, 3), s.draws.items.len);
    const hit = s.pickRay(.{ .origin = .new(5.2, 0.2, 3), .dir = .new(0, 0, -1) }).?;
    try testing.expectEqual(@as(u32, 4), hit.pick_id);

    try testing.expectError(error.InvalidGltf, load(testing.allocator, &g, "{not json", .{}));
}
