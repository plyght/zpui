#version 450
#include "sprite.glsl"
layout(location = 0) flat in uint v_id;
layout(location = 1) flat in vec4 v_color;
layout(location = 2) in vec2 v_tile_position;
// Dual-source blending (WS:28-58): color blends with Src1 / OneMinusSrc1.
layout(location = 0, index = 0) out vec4 out_color;
layout(location = 0, index = 1) out vec4 out_alpha;

// params0.x != 0: the atlas stores BGR coverage.
void main() {
  vec3 coverage = texture(atlas_texture, v_tile_position).rgb;
  if (pc.params0.x != 0.0) coverage = coverage.bgr;
  vec3 alpha = v_color.a * coverage * edge_fade_alpha(gl_FragCoord.xy, pc.instances.items[v_id].fade);
  float mean = (alpha.r + alpha.g + alpha.b) / 3.0;
  out_color = vec4(v_color.rgb, mean);
  out_alpha = vec4(alpha, mean);
}
