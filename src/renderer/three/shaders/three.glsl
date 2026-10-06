// zpui.three shared shader definitions (single source for Vulkan and Metal).
//
// Vulkan (default): buffers are pulled through buffer device addresses held in
// push constants, matching the 2D renderer. ZPUI_MSL (the variant SPIRV-Cross
// turns into src/renderer/metal/three/*.metal): the same data arrives as
// storage buffers at explicit bindings, which become [[buffer(N)]] slots.
// Bindings must match `gpu.Binding` in src/three/gpu.zig; structs must match
// src/three/gpu.zig byte for byte (only vec4/mat4/uvec4 members).

#extension GL_EXT_scalar_block_layout : require
#ifndef ZPUI_MSL
#extension GL_EXT_buffer_reference : require
#endif

#include "frame_data.glsl"

struct DrawData {
  vec4 base_color;
  vec4 emissive;
  vec4 pbr;
  vec4 toon;
  vec4 detail;
  vec4 outline_color;
  vec4 outline;
  vec4 highlight_color;
  uvec4 flags;
};

struct Instance {
  mat4 model;
  vec4 tint;
  uint pick_id;
  uint palette_row;
  uint user;
  uint pad;
};

const uint F_HAS_NORMALS = 1u << 0;
const uint F_HAS_UVS = 1u << 1;
const uint F_VERTEX_COLORS = 1u << 2;
const uint F_BASE_TEXTURE = 1u << 3;
const uint F_PALETTE = 1u << 4;
const uint F_RECEIVE_SHADOWS = 1u << 5;
const uint F_FOG = 1u << 6;
const uint F_ALPHA_MASK = 1u << 7;
const uint F_HIGHLIGHT = 1u << 8;
const uint F_DOUBLE_SIDED = 1u << 9;
const uint F_BLEND = 1u << 10;
const uint F_OUTLINE_PIXELS = 1u << 11;

const uint SHADING_PBR = 0u;
const uint SHADING_TOON = 1u;
const uint SHADING_FLAT = 2u;

#ifdef ZPUI_MSL
layout(set = 0, binding = 0, scalar) readonly buffer PositionsBuf { float v[]; } b_positions;
layout(set = 0, binding = 1, scalar) readonly buffer NormalsBuf { float v[]; } b_normals;
layout(set = 0, binding = 2, scalar) readonly buffer UvsBuf { float v[]; } b_uvs;
layout(set = 0, binding = 3, scalar) readonly buffer ColorsBuf { uint v[]; } b_colors;
layout(set = 0, binding = 4, scalar) readonly buffer IdsBuf { uint v[]; } b_ids;
layout(set = 0, binding = 5, scalar) readonly buffer InstancesBuf { Instance v[]; } b_instances;
layout(set = 0, binding = 6, scalar) readonly buffer FrameBuf { FrameData f; } b_frame;
layout(set = 0, binding = 7, scalar) readonly buffer DrawBuf { DrawData d; } b_draw;
#define POSITIONS b_positions.v
#define NORMALS b_normals.v
#define UVS b_uvs.v
#define COLORS b_colors.v
#define IDS b_ids.v
#define INSTANCES b_instances.v
#define FRAME b_frame.f
#define DRAW b_draw.d
#else
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer FloatsRef { float v[]; };
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer UintsRef { uint v[]; };
layout(buffer_reference, scalar, buffer_reference_align = 16) readonly buffer InstancesRef { Instance v[]; };
layout(buffer_reference, scalar, buffer_reference_align = 16) readonly buffer FrameRef { FrameData f; };
layout(buffer_reference, scalar, buffer_reference_align = 16) readonly buffer DrawRef { DrawData d; };
layout(push_constant, scalar) uniform MeshPush {
  FloatsRef positions;
  FloatsRef normals;
  FloatsRef uvs;
  UintsRef colors;
  UintsRef ids;
  InstancesRef instances;
  FrameRef frame;
  DrawRef draw;
} pc;
#define POSITIONS pc.positions.v
#define NORMALS pc.normals.v
#define UVS pc.uvs.v
#define COLORS pc.colors.v
#define IDS pc.ids.v
#define INSTANCES pc.instances.v
#define FRAME pc.frame.f
#define DRAW pc.draw.d
#endif

vec3 srgb_to_linear(vec3 c) {
  return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

// Inverse-transpose up to scale (cofactor matrix): correct normals under non-uniform scale.
mat3 cofactor(mat3 m) {
  return mat3(cross(m[1], m[2]), cross(m[2], m[0]), cross(m[0], m[1]));
}

vec3 read_vec3(uint base_index, uint which) {
  // which: 0 positions, 1 normals
  if (which == 0u) return vec3(POSITIONS[base_index * 3u], POSITIONS[base_index * 3u + 1u], POSITIONS[base_index * 3u + 2u]);
  return vec3(NORMALS[base_index * 3u], NORMALS[base_index * 3u + 1u], NORMALS[base_index * 3u + 2u]);
}

uint read_id(uint vi, uint fmt) {
  if (fmt == 1u) return (IDS[vi >> 2u] >> ((vi & 3u) * 8u)) & 0xffu;
  if (fmt == 2u) return (IDS[vi >> 1u] >> ((vi & 1u) * 16u)) & 0xffffu;
  if (fmt == 3u) return IDS[vi];
  return 0u;
}
