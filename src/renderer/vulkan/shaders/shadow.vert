#version 450
#include "shadow.glsl"
layout(location = 0) flat out uint v_id;
layout(location = 1) flat out vec4 v_color;
out gl_PerVertex { vec4 gl_Position; float gl_ClipDistance[4]; };

void main() {
  vec2 unit_vertex = UNIT_VERTICES[gl_VertexIndex];
  Shadow shadow = pc.instances.items[gl_InstanceIndex];
  Bounds bounds;
  if (shadow.inset != 0u) {
    bounds = shadow.element_bounds;
  } else {
    // Leave room for the gaussian tail outside the shadow rect.
    float margin = 3.0 * shadow.blur_radius;
    bounds = shadow.bounds;
    bounds.origin -= margin;
    bounds.size += 2.0 * margin;
  }
  vec2 p = unit_position(unit_vertex, bounds);
  gl_Position = to_device_position_impl(p, pc.viewport_size);
  vec4 clip = distance_from_clip_rect_impl(p, shadow.content_mask);
  gl_ClipDistance[0] = clip.x;
  gl_ClipDistance[1] = clip.y;
  gl_ClipDistance[2] = clip.z;
  gl_ClipDistance[3] = clip.w;
  v_id = gl_InstanceIndex;
  v_color = hsla_to_rgba(shadow.color);
}
