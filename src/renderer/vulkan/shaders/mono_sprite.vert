#version 450
#include "sprite.glsl"
layout(location = 0) flat out uint v_id;
layout(location = 1) flat out vec4 v_color;
layout(location = 2) out vec2 v_tile_position;
out gl_PerVertex { vec4 gl_Position; float gl_ClipDistance[4]; };

// Shared by the monochrome and subpixel sprite pipelines.
void main() {
  vec2 unit_vertex = UNIT_VERTICES[gl_VertexIndex];
  MonochromeSprite sprite = pc.instances.items[gl_InstanceIndex];
  vec2 p = apply_transform(unit_position(unit_vertex, sprite.bounds), sprite.transformation);
  gl_Position = to_device_position_impl(p, pc.viewport_size);
  vec4 clip = distance_from_clip_rect_impl(p, sprite.content_mask);
  gl_ClipDistance[0] = clip.x;
  gl_ClipDistance[1] = clip.y;
  gl_ClipDistance[2] = clip.z;
  gl_ClipDistance[3] = clip.w;
  v_id = gl_InstanceIndex;
  v_color = hsla_to_rgba(sprite.color);
  // A blurred sprite's quad is inflated by 3*sigma per side (the CPU and this derivation must
  // agree); map uv so the content keeps its size and the margin addresses past the tile — the
  // fragment zeroes those taps. Tile pixels scale by tile/quad (SVGs rasterize oversampled), so
  // with zero blur this is exactly to_tile_position. Subpixel sprites always carry blur = 0.
  float blur_pad = 3.0 * sprite.blur;
  vec2 quad_size = sprite.bounds.size;
  vec2 unpadded_size = max(quad_size - 2.0 * blur_pad, vec2(1e-6));
  vec2 tile_size = vec2(sprite.tile.size);
  vec2 tile_px = (unit_vertex * quad_size - blur_pad) * (tile_size / unpadded_size);
  v_tile_position = (vec2(sprite.tile.origin) + tile_px) / pc.texture_size;
}
