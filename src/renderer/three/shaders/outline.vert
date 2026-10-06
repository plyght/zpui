#version 450
// zpui.three: inverted-hull outline (drawn with front faces culled). Pushes
// vertices out along their normals by a world width or a pixel width.
#include "three.glsl"

layout(location = 0) out float v_view_depth;

void main() {
  uint vi = uint(gl_VertexIndex);
  Instance inst = INSTANCES[gl_InstanceIndex];
  uint flags = DRAW.flags.x;
  vec4 world = inst.model * vec4(read_vec3(vi, 0u), 1.0);
  vec3 n = (flags & F_HAS_NORMALS) != 0u ? normalize(cofactor(mat3(inst.model)) * read_vec3(vi, 1u)) : vec3(0.0);
  float width = DRAW.outline.x;
  if ((flags & F_OUTLINE_PIXELS) == 0u) world.xyz += n * width;
  vec4 clip = FRAME.view_proj * world;
  if ((flags & F_OUTLINE_PIXELS) != 0u) {
    vec2 dir = (FRAME.view_proj * vec4(n, 0.0)).xy;
    float len = length(dir);
    if (len > 1e-6) clip.xy += dir / len * width * 2.0 * FRAME.viewport.zw * clip.w;
  }
  v_view_depth = -(FRAME.view * world).z;
  gl_Position = clip;
}
