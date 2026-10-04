#include "common.glsl"
struct PathSprite { Bounds bounds; };
layout(buffer_reference, scalar, buffer_reference_align = 4) readonly buffer PathSprites { PathSprite items[]; };
PUSH_CONSTANTS(PathSprites)
layout(set = 0, binding = 0) uniform sampler2D intermediate_texture;
