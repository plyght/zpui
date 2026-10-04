#version 450
#include "path.glsl"
layout(location = 0) flat out uint v_id;
layout(location = 1) out vec2 v_st;
out gl_PerVertex { vec4 gl_Position; float gl_ClipDistance[4]; };

// One invocation per path vertex (non-indexed triangle list).
void main() {
  PathRasterizationVertex v = pc.instances.items[gl_VertexIndex];
  gl_Position = to_device_position_impl(v.xy_position, pc.viewport_size);
  vec4 clip = distance_from_clip_rect_impl(v.xy_position, v.bounds);
  gl_ClipDistance[0] = clip.x;
  gl_ClipDistance[1] = clip.y;
  gl_ClipDistance[2] = clip.z;
  gl_ClipDistance[3] = clip.w;
  v_id = gl_VertexIndex;
  v_st = v.st_position;
}
