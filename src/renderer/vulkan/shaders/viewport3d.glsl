#include "common.glsl"
struct Viewport3DInstance { Bounds bounds; Bounds content_mask; Corners corner_radii; float exposure; uint pad0; uint pad1; uint pad2; };
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer Viewport3DInstances { Viewport3DInstance items[]; };
PUSH_CONSTANTS(Viewport3DInstances)
layout(set = 0, binding = 0) uniform sampler2D hdr_texture;
