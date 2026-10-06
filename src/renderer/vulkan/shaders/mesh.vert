#version 450
#include "three_common.glsl"
layout(location = 0) out vec3 v_world;
layout(location = 1) out vec3 v_normal;

void main() {
  uint index = pc.indices.i[gl_VertexIndex];
  Vertex3D vert = pc.vertices.v[index];
  mat4 model = pc.draw.d.model;
  vec4 world = model * vec4(vert.pos, 1.0);
  v_world = world.xyz;
  // Uniform scale assumed in the spike (no inverse-transpose).
  v_normal = mat3(model) * vert.normal;
  gl_Position = pc.frame.f.view_proj * world;
}
