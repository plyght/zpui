// zpui.three post/composite interface: 64 bytes of parameters (Vulkan push
// constants, Metal set*Bytes at buffer 0), up to three sampled textures, and
// (SSAO only) the viewport's FrameData.
#extension GL_EXT_scalar_block_layout : require
#ifndef ZPUI_MSL
#extension GL_EXT_buffer_reference : require
#endif

#include "frame_data.glsl"

#ifdef ZPUI_MSL
layout(set = 0, binding = 0, std140) uniform PostParams { vec4 p0; vec4 p1; vec4 p2; vec4 p3; } P;
layout(set = 0, binding = 6, scalar) readonly buffer FrameBuf { FrameData f; } b_frame;
#define FRAME b_frame.f
#else
layout(buffer_reference, scalar, buffer_reference_align = 16) readonly buffer FrameRef { FrameData f; };
layout(push_constant, scalar) uniform PostParams { vec4 p0; vec4 p1; vec4 p2; vec4 p3; FrameRef frame; } P;
#define FRAME P.frame.f
#endif

layout(set = 0, binding = 1) uniform sampler2D tex0;
layout(set = 0, binding = 2) uniform sampler2D tex1;
layout(set = 0, binding = 3) uniform sampler2D tex2;

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
