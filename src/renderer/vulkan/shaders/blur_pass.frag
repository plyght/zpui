#version 450
#include "common.glsl"
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer Unused { uint items[]; };
PUSH_CONSTANTS(Unused)
layout(set = 0, binding = 0) uniform sampler2D source_texture;
layout(location = 0) out vec4 out_color;

// One separable gaussian pass (zui wgpu `fs_blur_pass`, W:1491), weights
// computed in-shader and normalized.
//   params0 = (direction.xy, sigma in destination texels, source texels per destination texel)
//   params1 = (destination texel -> source texel scale, source valid extent in texels xy, unused)
//   texture_size = source texture size in texels.
void main() {
  vec2 direction = pc.params0.xy;
  float sigma = max(pc.params0.z, 0.5);
  float stride = pc.params0.w;
  float scale = pc.params1.x;
  vec2 valid = pc.params1.yz;
  int radius = int(ceil(sigma * 3.0));
  vec2 base = gl_FragCoord.xy * scale;
  vec4 sum = vec4(0.0);
  float total = 0.0;
  for (int k = -radius; k <= radius; k++) {
    float w = exp(-float(k * k) / (2.0 * sigma * sigma));
    vec2 p = clamp(base + float(k) * stride * direction, vec2(0.5), valid - 0.5);
    sum += textureLod(source_texture, p / pc.texture_size, 0.0) * w;
    total += w;
  }
  out_color = sum / total;
}
