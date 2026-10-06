#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct fullscreen_vert_out
{
    float4 gl_Position [[position]];
};

vertex fullscreen_vert_out fullscreen_vert(uint gl_VertexIndex [[vertex_id]])
{
    fullscreen_vert_out out = {};
    float2 p = float2(float((int(gl_VertexIndex) << 1) & 2), float(int(gl_VertexIndex) & 2));
    out.gl_Position = float4((p * 2.0) - float2(1.0), 0.0, 1.0);
    out.gl_Position.y = -(out.gl_Position.y);    // Invert Y-axis for Metal
    return out;
}

