#version 450
// zpui.three: lit mesh vertex stage (all shading models).
#include "three.glsl"

layout(location = 0) out vec3 v_world;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec2 v_uv;
layout(location = 3) out vec4 v_color;
layout(location = 4) flat out uint v_id;
layout(location = 5) flat out uint v_palette_row;
layout(location = 6) out vec3 v_shadow;
layout(location = 7) out float v_view_depth;

void main() {
  uint vi = uint(gl_VertexIndex);
  Instance inst = INSTANCES[gl_InstanceIndex];
  uint flags = DRAW.flags.x;
  vec4 world = inst.model * vec4(read_vec3(vi, 0u), 1.0);
  vec3 n = vec3(0.0, 1.0, 0.0);
  if ((flags & F_HAS_NORMALS) != 0u) n = normalize(cofactor(mat3(inst.model)) * read_vec3(vi, 1u));
  v_world = world.xyz;
  v_normal = n;
  v_uv = (flags & F_HAS_UVS) != 0u ? vec2(UVS[vi * 2u], UVS[vi * 2u + 1u]) : vec2(0.0);
  vec4 color = vec4(1.0);
  if ((flags & F_VERTEX_COLORS) != 0u) {
    vec4 c = unpackUnorm4x8(COLORS[vi]);
    color = vec4(srgb_to_linear(c.rgb), c.a);
  }
  v_color = color * inst.tint;
  v_id = read_id(vi, DRAW.flags.w);
  v_palette_row = inst.palette_row;
  // Shadow lookup position, offset along the normal against acne.
  vec4 ls = FRAME.light_view_proj * vec4(world.xyz + n * FRAME.shadow.y, 1.0);
  v_shadow = ls.xyz / ls.w;
  vec4 view = FRAME.view * world;
  v_view_depth = -view.z;
  gl_Position = FRAME.view_proj * world;
}
