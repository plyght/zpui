#version 450
#include "sprite.glsl"
layout(location = 0) flat in uint v_id;
layout(location = 1) flat in vec4 v_color;
layout(location = 2) in vec2 v_tile_position;
layout(location = 0) out vec4 out_color;

// Port of Metal `monochrome_sprite_fragment` (M:199). The atlas is R8 here (A8 on Metal).
void main() {
  float coverage = texture(atlas_texture, v_tile_position).r;
  vec4 color = v_color;
  color.a *= coverage * edge_fade_alpha(gl_FragCoord.xy, pc.instances.items[v_id].fade);
  out_color = color;
}
