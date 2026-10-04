#version 450
#include "path_sprite.glsl"
layout(location = 0) out vec2 v_uv;

void main() {
  vec2 unit_vertex = UNIT_VERTICES[gl_VertexIndex];
  PathSprite sprite = pc.instances.items[gl_InstanceIndex];
  // No content mask: it was applied while rasterizing.
  vec2 p = unit_position(unit_vertex, sprite.bounds);
  gl_Position = to_device_position_impl(p, pc.viewport_size);
  v_uv = p / pc.viewport_size;
}
