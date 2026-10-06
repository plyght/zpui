// zpui.three: lit mesh fragment stage. Shading models: glTF metallic-roughness
// (GGX), N-band toon ramp, flat (unlit). Output: linear HDR, premultiplied.
// Included by mesh.frag and (with ZPUI_ALPHA_MASK) mesh_mask.frag: only that
// variant may discard, so opaque draws keep early depth / hidden-surface removal.
#include "three.glsl"
#include "lighting.glsl"

layout(location = 0) in vec3 v_world;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec2 v_uv;
layout(location = 3) in vec4 v_color;
layout(location = 4) flat in uint v_id;
layout(location = 5) flat in uint v_palette_row;
layout(location = 6) in vec3 v_shadow;
layout(location = 7) in float v_view_depth;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 8) uniform sampler2DShadow shadow_map;
layout(set = 0, binding = 9) uniform sampler2D base_texture;
layout(set = 0, binding = 10) uniform sampler2D palette;

void main() {
  uint flags = DRAW.flags.x;
  vec4 base = DRAW.base_color * v_color;
  if ((flags & F_BASE_TEXTURE) != 0u) base *= texture(base_texture, v_uv);
  if ((flags & F_PALETTE) != 0u) base.rgb *= texelFetch(palette, ivec2(int(v_id), int(v_palette_row)), 0).rgb;
  if (DRAW.detail.y != 0.0) base.rgb *= 1.0 + DRAW.detail.y * (value_noise(v_world.xz * DRAW.detail.x) - 0.5) * 2.0;
#ifdef ZPUI_ALPHA_MASK
  if ((flags & F_ALPHA_MASK) != 0u) {
    if (base.a < DRAW.pbr.z) discard;
    base.a = 1.0;
  }
#endif
  if ((flags & F_BLEND) == 0u) base.a = 1.0;

  vec3 v = view_vector(v_world);
  vec3 n = (flags & F_HAS_NORMALS) != 0u ? normalize(v_normal) : normalize(cross(dFdx(v_world), dFdy(v_world)));
  if ((flags & F_HAS_NORMALS) == 0u && dot(n, v) < 0.0) n = -n;
  if ((flags & F_DOUBLE_SIDED) != 0u && dot(n, v) < 0.0) n = -n;

  // PBR surfaces facing away from the sun get no direct light: skip the PCF.
  uint model = DRAW.flags.z;
  float shadow = 1.0;
  if ((flags & F_RECEIVE_SHADOWS) != 0u && model != SHADING_FLAT && (model == SHADING_TOON || dot(n, FRAME.sun_dir.xyz) > 0.0))
    shadow = sample_shadow(shadow_map, v_shadow);

  vec3 color;
  if (model == SHADING_FLAT) {
    color = base.rgb;
  } else if (model == SHADING_TOON) {
    color = shade_toon(base.rgb, n, shadow);
  } else {
    color = shade_pbr(base.rgb, DRAW.pbr.x, DRAW.pbr.y, n, v, shadow);
  }
  color += DRAW.emissive.rgb;
  if ((flags & F_HIGHLIGHT) != 0u && v_id == DRAW.flags.y) color = mix(color, DRAW.highlight_color.rgb, DRAW.highlight_color.a);
  if ((flags & F_FOG) != 0u) color = apply_fog(color, v_view_depth);
  out_color = vec4(color * base.a, base.a);
}
