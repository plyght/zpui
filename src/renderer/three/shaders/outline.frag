#version 450
#include "three.glsl"
#include "lighting.glsl"

layout(location = 0) in float v_view_depth;
layout(location = 0) out vec4 out_color;

void main() {
  vec4 c = DRAW.outline_color;
  vec3 rgb = (DRAW.flags.x & F_FOG) != 0u ? apply_fog(c.rgb, v_view_depth) : c.rgb;
  out_color = vec4(rgb * c.a, c.a);
}
