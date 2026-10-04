#version 450
#include "sprite.glsl"
layout(location = 0) flat in uint v_id;
layout(location = 1) flat in vec4 v_color;
layout(location = 2) in vec2 v_tile_position;
layout(location = 0) out vec4 out_color;

// Without dual-source blending: grayscale coverage from the mean of the channels.
void main() {
  vec3 coverage = texture(atlas_texture, v_tile_position).rgb;
  float mean = (coverage.r + coverage.g + coverage.b) / 3.0;
  out_color = vec4(v_color.rgb, v_color.a * mean * edge_fade_alpha(gl_FragCoord.xy, pc.instances.items[v_id].fade));
}
