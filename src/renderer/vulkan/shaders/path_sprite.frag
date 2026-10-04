#version 450
#include "path_sprite.glsl"
layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

void main() {
  out_color = texture(intermediate_texture, v_uv);
}
