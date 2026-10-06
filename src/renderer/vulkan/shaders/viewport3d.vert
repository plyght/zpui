#version 450
#include "viewport3d.glsl"
layout(location = 0) out vec2 v_uv;
layout(location = 1) flat out uint v_instance;
layout(location = 2) out vec4 v_clip;

void main() {
  vec2 unit_vertex = UNIT_VERTICES[gl_VertexIndex];
  Viewport3DInstance vp = pc.instances.items[gl_InstanceIndex];
  vec2 p = unit_position(unit_vertex, vp.bounds);
  gl_Position = to_device_position_impl(p, pc.viewport_size);
  v_uv = unit_vertex;
  v_instance = gl_InstanceIndex;
  Bounds m = vp.content_mask;
  v_clip = vec4(p.x - m.origin.x, m.origin.x + m.size.x - p.x, p.y - m.origin.y, m.origin.y + m.size.y - p.y);
}
