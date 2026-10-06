//! zpui.three: native 3D for zpui (Vulkan + Metal).
//!
//! A `Scene3D` renders offscreen (linear HDR, depth, MSAA, shadow map, post)
//! before the UI pass and is composited in draw order by a `viewport3d`
//! element, so 2D UI above and below it (backdrop blurs included) just works.
//! Meshes and textures live in a `Gfx3D` store and are uploaded once. See
//! docs/THREE.md.

pub const math = @import("math.zig");
pub const gfx = @import("gfx.zig");
pub const scene3d = @import("scene3d.zig");
pub const shapes = @import("shapes.zig");
pub const gpu = @import("gpu.zig");
pub const plan = @import("plan.zig");

pub const Vec2 = math.Vec2;
pub const Vec3 = math.Vec3;
pub const Vec4 = math.Vec4;
pub const Quat = math.Quat;
pub const Mat4 = math.Mat4;
pub const Aabb = math.Aabb;
pub const Ray = math.Ray;
pub const rgb = math.rgb;

pub const Gfx3D = gfx.Gfx3D;
pub const MeshId = gfx.MeshId;
pub const TextureId = gfx.TextureId;
pub const MeshDesc = gfx.MeshDesc;
pub const TextureDesc = gfx.TextureDesc;
pub const Ids = gfx.Ids;

pub const Scene3D = scene3d.Scene3D;
pub const Camera = scene3d.Camera;
pub const Orbit = scene3d.Orbit;
pub const Projection = scene3d.Projection;
pub const Rect = scene3d.Rect;
pub const Sun = scene3d.Sun;
pub const Shadow = scene3d.Shadow;
pub const Hemisphere = scene3d.Hemisphere;
pub const Environment = scene3d.Environment;
pub const Fog = scene3d.Fog;
pub const Post = scene3d.Post;
pub const Ssao = scene3d.Ssao;
pub const TiltShift = scene3d.TiltShift;
pub const Tonemap = scene3d.Tonemap;
pub const Tier = scene3d.Tier;
pub const Material = scene3d.Material;
pub const Shading = scene3d.Shading;
pub const AlphaMode = scene3d.AlphaMode;
pub const Outline = scene3d.Outline;
pub const Toon = scene3d.Toon;
pub const Detail = scene3d.Detail;
pub const Instance = scene3d.Instance;
pub const Highlight = scene3d.Highlight;
pub const DrawOpts = scene3d.DrawOpts;
pub const Hit = Scene3D.Hit;

test {
    _ = math;
    _ = gfx;
    _ = scene3d;
    _ = shapes;
    _ = gpu;
    _ = plan;
}
