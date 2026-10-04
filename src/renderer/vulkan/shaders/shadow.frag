#version 450
#include "shadow.glsl"
layout(location = 0) flat in uint v_id;
layout(location = 1) flat in vec4 v_color;
layout(location = 0) out vec4 out_color;

float gaussian(float x, float sigma) {
  return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * M_PI_F) * sigma);
}

vec2 erf_approx(vec2 x) {
  vec2 s = sign(x);
  vec2 a = abs(x);
  vec2 r1 = 1.0 + (0.278393 + (0.230389 + (0.000972 + 0.078108 * a) * a) * a) * a;
  vec2 r2 = r1 * r1;
  return s - s / (r2 * r2);
}

float blur_along_x(float x, float y, float sigma, float corner, vec2 half_size) {
  float delta = min(half_size.y - corner - abs(y), 0.0);
  float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
  vec2 integral = 0.5 + 0.5 * erf_approx((x + vec2(-curved, curved)) * (sqrt(0.5) / sigma));
  return integral.y - integral.x;
}

// Port of Metal `shadow_fragment` (M:504): Evan Wallace's rounded-rect blur.
void main() {
  Shadow shadow = pc.instances.items[v_id];
  vec2 frag = gl_FragCoord.xy;
  vec2 half_size = shadow.bounds.size / 2.0;
  vec2 center = shadow.bounds.origin + half_size;
  vec2 point = frag - center;
  float corner_radius = pick_corner_radius(point, shadow.corner_radii);

  float alpha;
  if (shadow.blur_radius == 0.0) {
    alpha = clamp(0.5 - quad_sdf(frag, shadow.bounds, shadow.corner_radii), 0.0, 1.0);
  } else {
    float low = point.y - half_size.y;
    float high = point.y + half_size.y;
    float start = clamp(-3.0 * shadow.blur_radius, low, high);
    float end = clamp(3.0 * shadow.blur_radius, low, high);
    float step_size = (end - start) / 4.0;
    float y = start + step_size * 0.5;
    alpha = 0.0;
    for (int i = 0; i < 4; i++) {
      alpha += blur_along_x(point.x, point.y - y, shadow.blur_radius, corner_radius, half_size) *
               gaussian(y, shadow.blur_radius) * step_size;
      y += step_size;
    }
  }

  if (shadow.inset != 0u) {
    alpha = 1.0 - alpha;
    float element_distance = quad_sdf(frag, shadow.element_bounds, shadow.element_corner_radii);
    alpha *= clamp(0.5 - element_distance, 0.0, 1.0);
  }
  out_color = v_color * vec4(1.0, 1.0, 1.0, alpha);
}
