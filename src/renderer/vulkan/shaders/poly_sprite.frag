#version 450
#include "poly_sprite.glsl"
layout(location = 0) flat in uint v_id;
layout(location = 1) in vec2 v_tile_position;
layout(location = 0) out vec4 out_color;

float image_mask_alpha(vec2 position, ImageAlphaMaskParams mask) {
  if (mask.feather <= 0.0) return 1.0;
  vec2 half_size = mask.bounds.size * 0.5;
  vec2 center = mask.bounds.origin + half_size;
  vec2 q = abs(position - center) - half_size + mask.radius;
  float distance = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - mask.radius;
  float alpha = smoothstep(0.0, mask.feather, distance - mask.clearance);
  if (mask.bottom_feather > 0.0)
    alpha = min(alpha, smoothstep(0.0, mask.bottom_feather, mask.bottom_y - position.y));
  return alpha;
}

// Port of Metal `polychrome_sprite_fragment` (M:264). Straight-alpha BGRA atlas.
void main() {
  PolychromeSprite sprite = pc.instances.items[v_id];
  vec2 frag = gl_FragCoord.xy;
  vec4 color = texture(atlas_texture, v_tile_position);
  float distance = quad_sdf(frag, sprite.bounds, sprite.corner_radii);
  if (sprite.grayscale != 0u) {
    float g = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
    color.rgb = vec3(g);
  }
  color.a *= sprite.opacity * clamp(0.5 - distance, 0.0, 1.0) *
             edge_fade_alpha(frag, sprite.fade) * image_mask_alpha(frag, sprite.alpha_mask);
  out_color = color;
}
