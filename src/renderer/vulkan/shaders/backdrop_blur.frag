#version 450
#include "backdrop_blur.glsl"
layout(location = 0) flat in uint v_id;
layout(location = 0) out vec4 out_color;

// Port of Metal `backdrop_blur_fragment` (M:886). Blending is disabled, so
// fragments outside the rounded rect must discard.
//   params0.x = downsample factor, params0.yz = valid blurred extent in texels.
void main() {
  BackdropBlur blur = pc.instances.items[v_id];
  if (quad_sdf(gl_FragCoord.xy, blur.bounds, blur.corner_radii) > 0.0) discard;
  vec2 p = clamp(gl_FragCoord.xy / pc.params0.x, vec2(0.5), pc.params0.yz - 0.5);
  out_color = textureLod(blurred_texture, p / pc.texture_size, 0.0);
}
