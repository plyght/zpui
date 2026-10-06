# zpui.three: native 3D (`src/three/`, `src/renderer/*/three.zig`)

`zpui.three` draws lit 3D scenes inside zpui windows on both backends, Vulkan
(Linux) and Metal (macOS). A `Scene3D` renders offscreen before the UI pass
(linear HDR, depth, MSAA, shadow map, post) and is composited by a
`viewport3d` element in draw order. UI painted after it sits on top: tooltips,
HUD chips, and frosted panels whose backdrop blur blurs the 3D image. Rounded
corners and clipping work like any other primitive.

```zig
const three = zpui.three;

// Once (keep both alive as long as the view): the resource store and a scene.
var gfx = three.Gfx3D.init(gpa);
var scene = three.Scene3D.init(gpa, &gfx);
var cube = try three.shapes.box(gpa, .{ 1, 1, 1 });
defer cube.deinit(gpa);
const box = try gfx.createMesh(cube.desc()); // uploaded on the next frame

// Every render (or animation tick): rebuild the draw list.
scene.clearDraws();
scene.camera = orbit.camera();
try scene.draw(box, three.Mat4.translation(.new(0, 0.5, 0)), .{
    .material = .{ .base_color = three.rgb(0xd0261c), .roughness = 0.4 },
    .pick_id = 1,
});

// In the element tree:
div().flex1().child(zpui.viewport3dRounded(&scene, 12).sizeFull())
```

`examples/three_demo.zig` (`zig build three-demo`) is a complete app with an
orbit camera, instancing, hover picking, a toon toggle and quality tiers.
`examples/render_test_3d.zig` covers every feature in small scenes.

## 1. Concepts

| Type | What | Lifetime |
|---|---|---|
| `Gfx3D` | Store of meshes and textures. CPU copies are kept until a renderer uploads them; renderers mirror the slots on the GPU. | One per window; outlives every scene that uses it |
| `MeshId`, `TextureId` | Generational handles (`gfx.destroy(h)`) | Until destroyed |
| `Scene3D` | Camera, sun + shadow, ambient (hemisphere, SH9), fog, post settings, background, and a draw list | App-owned; must outlive the frames that show it |
| `Material` | A value (no handle): shading model, factors, textures, flags | Per draw |
| `Instance` | 96-byte per-instance record: transform, tint, pick id, palette row | Copied into the draw list |
| `viewport3d(&scene)` | Element that paints the scene at its bounds | Per frame |

### Meshes fit procedural formats as they are

`MeshDesc` takes separate tightly packed streams, so binary geometry produced
elsewhere is passed without repacking:

| Field | Type | Notes |
|---|---|---|
| `positions` | `[]const [3]f32` | required |
| `normals` | `?[]const [3]f32` | without them shading uses flat (screen-derivative) normals |
| `uvs` | `?[]const [2]f32` | base-color texture coordinates |
| `colors` | `?[]const [4]u8` | sRGB RGBA8; multiplies the base color (`Material.vertex_colors`) |
| `ids` | `Ids = none / u8 / u16 / u32` | per-vertex integer: palette column, highlight, picking |
| `indices` | `[]const u32` | triangle list, counter-clockwise from the front |
| `keep_cpu` | `bool` | keep positions/indices/ids after upload for triangle picking |

Example with a Carcassonne `CGEO` 3D buffer: `VPOS`, `VNRM`, `VUV0` and `INDX`
are passed as slices, `VFEA` as `.ids = .{ .u8 = vfea[0..count] }`, and each
`GRUP` becomes one draw with `first_index`/`index_count` and its own material.

Textures are RGBA8 (`rgba8_srgb` for colors, `rgba8_unorm` for data), with a
mip chain built on the CPU, nearest or linear filtering, and repeat or clamp
wrapping.

### Materials

| Shading | Model |
|---|---|
| `.pbr` | glTF metallic-roughness: GGX, height-correlated Smith, Schlick; Lambert diffuse; analytic split-sum ambient specular |
| `.toon` | N-band ramp of N·L (`toon.bands`, `toon.min`, `toon.softness`); the shadow scales the light, as in three.js `MeshToonMaterial` |
| `.flat` | Unlit base color |

Fields applying to every model:

- **Color:** `base_color` (linear RGBA), `base_color_texture`, `vertex_colors`, and `palette`. The palette is an RGBA8 texture sampled at (vertex id, instance `palette_row`), so one prop mesh with part ids can be recolored per instance.
- **Surface noise:** `detail`, a world-space value noise that modulates the color.
- **Light:** `emissive`.
- **Outline:** an inverted-hull outline drawn after opaque draws; its width is in world units or pixels.
- **Transparency:** `alpha_mode` (opaque, mask with `alpha_cutoff`, or blend, sorted back to front) and `double_sided`.
- **Depth and passes:** `depth_write`, `depth_bias` (pulls coplanar overlays toward the camera), `cast_shadows`, `receive_shadows` and `fog`.

`DrawOpts.highlight = .{ .id = feature, .color = ... }` blends a color over
the vertices whose id equals `feature`, for example the hovered tile feature.
`Instance.tint` multiplies the color per instance (player colors). Its alpha
multiplies opacity.

### Lighting

- **Sun:** `Sun` is a directional light (`direction` is the direction the light travels; `Sun.fromAngles(azimuth, elevation)` builds it).
  - Its shadow map is fitted to the scene bounds or `shadow.bounds`, snapped to texels, standard Z, with 12-tap Poisson PCF.
  - `softness` sets the PCF radius in texels; `bias` and `normal_bias` are also configurable.
- **Ambient:** `Hemisphere` (sky/ground blend by the normal's Y) plus optional `Environment` SH9 irradiance.
  - `Environment.uniform(radiance)` and `Environment.gradient(sky, ground)` build common environments exactly.
- **three.js parity:** the conventions match three.js physically based lights, so style values port directly. Diffuse is `albedo / PI * (sun * N·L * shadow + hemisphere + SH9)`.
  - A three.js `environment` intensity of `e` on a neutral room is roughly `Environment.uniform(.{ e, e, e })`.
- **Fog:** exponential-squared over view depth, `1 - exp(-(density·d)²)` (three.js `FogExp2`).

### Post and quality tiers

`Post` controls:

- `exposure`;
- `tonemap`: Khronos PBR Neutral (default), ACES fitted, or none;
- `saturation` and `vignette`;
- `msaa`: 1 or 4;
- `fxaa`;
- `ssao`: radius, intensity, samples. It runs at half resolution from the resolved depth and is blurred;
- `tilt_shift`: `focus` (0 is the top of the viewport, 1 the bottom), `range`, `blur`. It is a half-resolution gaussian mixed by screen Y, and skipped for orthographic cameras.

`scene.setTier(.low / .medium / .high)` applies the presets:

| Tier | Shadows | AA | SSAO | Tilt-shift |
|---|---|---|---|---|
| low | off | FXAA | off | off |
| medium | 2048² PCF | 4× MSAA | off | off |
| high | 2048² PCF | 4× MSAA | on | on |

### Cameras and picking

`Camera` is perspective (reverse-Z, infinite or finite far plane) or
orthographic (reverse-Z). `Orbit` is a yaw/pitch/distance rig with `rotate`
and `zoom`. `camera.ray(viewport_rect, point)` gives a world ray and
`camera.worldToScreen` the inverse.

- `ray.intersectGround(y)` handles table-plane picks (board cell = `floor(x)`, `floor(z)`).
- `scene.pick(viewport, point)` or `scene.pickAt(window_point)` returns the nearest instance with a nonzero `pick_id`:
  - `Hit = { pick_id, vertex_id, instance_index, draw_index, triangle, distance, position, normal }`.
  - Meshes created with `keep_cpu` are tested per triangle and report the id attribute of the nearest vertex (`vertex_id`, the tile feature). Other meshes are tested against their bounds.
  - `pickAt` uses the bounds where the scene was last painted, so call it from a mouse handler on the viewport or a parent element.

### glTF

`three.gltf.load(gpa, &gfx, bytes, .{})` loads `.glb`, or `.gltf` with embedded
buffers and images, through vendored cgltf:

- Triangle primitives with POSITION, NORMAL, TEXCOORD_0, COLOR_0 and indices.
- Metallic-roughness factors and the base-color texture (PNG/JPEG); unlit materials become `.flat`.
- The default scene, flattened into `(mesh, material, transform)` items.

`model.draw(&scene, transform, .{ .pick_id, .tint, .shading, .outline })`
draws it, and `model.deinit(&gfx)` frees its resources.

Not supported yet: external files, skins, morph targets, animations, normal or occlusion textures, and KHR extensions.

## 2. Frame model and threading

1. During `render`, the app updates `Scene3D` (usually `clearDraws` followed by `draw` / `drawInstanced`) and paints `viewport3d(&scene)`. Animating scenes call `window.requestAnimationFrame()`.
2. When the frame is drawn, the renderer, per viewport (keyed by scene and occurrence, sized to the snapped device-pixel bounds):
   - **syncs the store:** uploads pending meshes and textures, then frees CPU copies unless `keep_cpu` is set;
   - **plans the frame** (`src/three/plan.zig`, shared by both backends):
     - culls instances against the camera frustum, and against the light frustum for the shadow pass;
     - sorts opaque draws by state and mesh, and blended draws back to front;
     - fits the shadow camera and packs the GPU structs;
     - hashes everything;
   - **skips the 3D passes when the hash matches the last rendered one** and re-composites the cached image. A static board costs only the composite. `scene.stats.cached` reports this;
   - otherwise **renders**, in order:
     1. shadow;
     2. main pass: opaque, outlines, blended;
     3. SSAO and blur;
     4. tilt-shift blur;
     5. resolve: AO, tilt-shift mix, exposure, tonemap, saturation, vignette, sRGB encode into premultiplied RGBA8;
     6. FXAA.
3. The UI pass composites the final image at the primitive's draw order, with the content-mask clip, rounded corners and element opacity.

Everything runs on the UI thread. A `Gfx3D` must be drawn by **one renderer
(one window)**: the renderer mirrors it and frees CPU copies after upload. A
second window needs its own store, unless every mesh in it uses `keep_cpu`.

`scene.stats` (from the frame shown) reports draws, instances, triangles,
shadow draws, `cached`, and GPU milliseconds. On Vulkan it gives totals plus
shadow, main and post split from timestamp queries; on Metal, the command
buffer's GPU time.

## 3. Resource lifetimes

- `createMesh` / `createTexture` copy the input. The caller's slices may be freed immediately.
- `gfx.destroy(handle)` invalidates the handle at once. GPU objects are released after the frames that used them complete (Vulkan: a retire list two frames deep; Metal: command buffers retain them).
- Reusing a slot bumps its 12-bit generation, so stale handles never alias.
- Offscreen targets belong to the renderer and are released 120 frames after their scene was last shown.

## 4. Backends

| | Vulkan (`src/renderer/vulkan/three.zig`) | Metal (`src/renderer/metal/three.zig`) |
|---|---|---|
| Vertex data | Buffer device addresses in push constants, no vertex-input state (as the 2D pipelines) | Buffers at fixed `[[buffer(n)]]` slots (`gpu.Binding`) |
| Mesh storage | One device-local buffer per mesh, all streams + indices | One shared/managed `MTLBuffer` per mesh |
| HDR target | `R16G16B16A16_SFLOAT`, 4× MSAA resolved in-pass | `rgba16Float`, MSAA memoryless on Apple GPUs |
| Depth | `D32_SFLOAT`, reverse-Z, `SAMPLE_ZERO` depth resolve for SSAO | `depth32Float`, depth resolve for SSAO |
| Dynamic state | cull mode, depth write, depth bias (Vulkan 1.3 core) | encoder state |
| Shaders | `glslc -O` SPIR-V | SPIRV-Cross output compiled at runtime |
| GPU timing | timestamp queries per pass | command-buffer GPU time per viewport |

**Shaders are written once**, in GLSL (`src/renderer/three/shaders/`).
`three.glsl` defines the buffers through macros:

- **Vulkan** reads buffers through device addresses.
- **`-DZPUI_MSL`** uses storage buffers at explicit bindings instead.

`zig build gen-msl` compiles that variant without `-O`, so names survive, and
runs `spirv-cross --msl --msl-decoration-binding --flip-vert-y`. That
regenerates `src/renderer/metal/three/*.metal`, which are checked in, so
macOS builds need no shader toolchain and `metal-check` still cross-compiles
from Linux. CI job `three-msl` fails when the checked-in MSL drifts.

Both backends consume the same Vulkan-style clip-space matrices. The flipped
Y lets the same winding (counter-clockwise front faces) and texture origin
(top-left) hold on both.

## 5. Performance notes

- **Draws:** each draw costs one descriptor/state setup plus a push. Instance everything repeated (props, figures).
- **Static boards:** cost nothing on the GPU after the first frame thanks to the plan hash. Animate only what moves, and request frames only while animating.
- **Culling:** instances are frustum-culled on the CPU. Large meshes are culled as a whole by their bounds.
- **Shadow map:** use 2048² (`map_size`) and tighten `shadow.bounds` to the board when the scene includes a large table plane.
- **CPU copies:** keep them (`keep_cpu`) only for meshes you pick.
- **Measured numbers:** `zig build render-test-3d -Doptimize=ReleaseFast -- --bench` renders a Carcassonne-sized board (80 relief tiles at 48², slabs, about 1,800 instanced props, 25 figures; 0.57M triangles; 157 draws) at 2560×1440 per tier and prints GPU times. CI runs it on the `macos-15-intel` Metal runner (informational step).

| Tier | lavapipe, 4 CPU cores (software) | macos-15-intel CI, Metal (paravirtual GPU) |
|---|---|---|
| low | 164 ms (main 118, post 46) | 22.5 ms |
| medium | 453 ms (shadow 85, main 349, post 18) | 52.9 ms |
| high | 532 ms (shadow 57, main 362, post 114) | 59.8 ms |

Lavapipe rasterizes on the CPU, so its numbers are relative tier costs only
(MSAA dominates there). The Metal column is GPU time on the CI runner's
virtual GPU, with wall time within 1.5 ms of it, so CPU-side planning is not
the bottleneck. Real GPUs should be much faster, but the 60 fps target at
1440p on an M1 or a recent Intel iGPU (medium tier) still has to be confirmed
on that hardware with the same bench.

## 6. Tests

- `zig build test`: math, store, picking (rays, AABB, triangles, ranges, ids), planner (culling, passes, hash, shadow fit), shapes, SH9, glTF.
- `zig build render-test-3d`: six golden cases per backend (`tests/golden/render-test-3d-*.png`, `-metal` on macOS):
  - PBR with shadows and a blended box;
  - toon with outlines;
  - instanced/tint/palette/highlight/texture, orthographic;
  - post on: SSAO, tilt-shift, vignette, saturation, fog, FXAA;
  - post off: MSAA;
  - UI over 3D.
  Each case also checks the cache path. The test additionally checks picking against the rendered camera, zero Vulkan validation errors, and a 30-frame resizing swapchain spin. `--update-golden` rewrites the goldens.
- The 2D `render-test` is unchanged and must still match exactly.

## 7. Not done yet

- Point lights.
- Image-based specular (prefiltered cubemaps).
- Normal and occlusion maps.
- Skinning and glTF animation.
- Particles.
- GPU id-buffer picking (CPU picking covers the game's needs).
- Texture arrays and BC7.
- Per-pass GPU timing on Metal (it needs `MTLCounterSampleBuffer`).
