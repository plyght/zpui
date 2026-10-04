#version 450
#include "quad.glsl"

layout(location = 0) flat out uint v_id;
layout(location = 1) flat out vec4 v_border_color;
layout(location = 2) flat out vec4 v_solid;
layout(location = 3) flat out vec4 v_color0;
layout(location = 4) flat out vec4 v_color1;
out gl_PerVertex { vec4 gl_Position; float gl_ClipDistance[4]; };

void main() {
  vec2 unit_vertex = UNIT_VERTICES[gl_VertexIndex];
  Quad quad = pc.instances.items[gl_InstanceIndex];
  vec2 p = unit_position(unit_vertex, quad.bounds);
  gl_Position = to_device_position_impl(p, pc.viewport_size);
  vec4 clip = distance_from_clip_rect_impl(p, quad.content_mask);
  gl_ClipDistance[0] = clip.x;
  gl_ClipDistance[1] = clip.y;
  gl_ClipDistance[2] = clip.z;
  gl_ClipDistance[3] = clip.w;
  v_id = gl_InstanceIndex;
  v_border_color = hsla_to_rgba(quad.border_color);
  GradientColor g = prepare_fill_color(quad.background);
  v_solid = g.solid;
  v_color0 = g.color0;
  v_color1 = g.color1;
}
