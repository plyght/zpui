#version 450
// zpui.three: shadow-map depth pass (light orthographic camera, standard Z).
#include "three.glsl"

void main() {
  uint vi = uint(gl_VertexIndex);
  Instance inst = INSTANCES[gl_InstanceIndex];
  gl_Position = FRAME.light_view_proj * (inst.model * vec4(read_vec3(vi, 0u), 1.0));
}
