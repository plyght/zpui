#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct PositionsBuf
{
    float v[1];
};

struct NormalsBuf
{
    float v[1];
};

struct IdsBuf
{
    uint v[1];
};

struct Instance
{
    float4x4 model;
    float4 tint;
    uint pick_id;
    uint palette_row;
    uint user;
    uint pad;
};

struct Instance_1
{
    float4x4 model;
    float4 tint;
    uint pick_id;
    uint palette_row;
    uint user;
    uint pad;
};

struct InstancesBuf
{
    Instance_1 v[1];
};

struct DrawData
{
    float4 base_color;
    float4 emissive;
    float4 pbr;
    float4 toon;
    float4 detail;
    float4 outline_color;
    float4 outline;
    float4 highlight_color;
    uint4 flags;
};

struct DrawBuf
{
    DrawData d;
};

struct UvsBuf
{
    float v[1];
};

struct ColorsBuf
{
    uint v[1];
};

struct FrameData
{
    float4x4 view_proj;
    float4x4 view;
    float4x4 proj;
    float4x4 inv_proj;
    float4x4 light_view_proj;
    float4 camera_pos;
    float4 sun_dir;
    float4 sun_color;
    float4 sky;
    float4 ground;
    float4 fog;
    float4 shadow;
    float4 viewport;
    float4 env;
    float4 sh[9];
};

struct FrameBuf
{
    FrameData f;
};

struct mesh_vert_out
{
    float3 v_world [[user(locn0)]];
    float3 v_normal [[user(locn1)]];
    float2 v_uv [[user(locn2)]];
    float4 v_color [[user(locn3)]];
    uint v_id [[user(locn4)]];
    uint v_palette_row [[user(locn5)]];
    float3 v_shadow [[user(locn6)]];
    float v_view_depth [[user(locn7)]];
    float4 gl_Position [[position]];
};

static inline __attribute__((always_inline))
float3 read_vec3(thread const uint& base_index, thread const uint& which, const device PositionsBuf& b_positions, const device NormalsBuf& b_normals)
{
    if (which == 0u)
    {
        return float3(b_positions.v[base_index * 3u], b_positions.v[(base_index * 3u) + 1u], b_positions.v[(base_index * 3u) + 2u]);
    }
    return float3(b_normals.v[base_index * 3u], b_normals.v[(base_index * 3u) + 1u], b_normals.v[(base_index * 3u) + 2u]);
}

static inline __attribute__((always_inline))
float3x3 cofactor(thread const float3x3& m)
{
    return float3x3(float3(cross(m[1], m[2])), float3(cross(m[2], m[0])), float3(cross(m[0], m[1])));
}

static inline __attribute__((always_inline))
float3 srgb_to_linear(thread const float3& c)
{
    return mix(c / float3(12.9200000762939453125), pow((c + float3(0.054999999701976776123046875)) / float3(1.05499994754791259765625), float3(2.400000095367431640625)), step(float3(0.040449999272823333740234375), c));
}

static inline __attribute__((always_inline))
uint read_id(thread const uint& vi, thread const uint& fmt, const device IdsBuf& b_ids)
{
    if (fmt == 1u)
    {
        return (b_ids.v[vi >> 2u] >> ((vi & 3u) * 8u)) & 255u;
    }
    if (fmt == 2u)
    {
        return (b_ids.v[vi >> 1u] >> ((vi & 1u) * 16u)) & 65535u;
    }
    if (fmt == 3u)
    {
        return b_ids.v[vi];
    }
    return 0u;
}

vertex mesh_vert_out mesh_vert(const device PositionsBuf& b_positions [[buffer(0)]], const device NormalsBuf& b_normals [[buffer(1)]], const device UvsBuf& b_uvs [[buffer(2)]], const device ColorsBuf& b_colors [[buffer(3)]], const device IdsBuf& b_ids [[buffer(4)]], const device InstancesBuf& b_instances [[buffer(5)]], const device FrameBuf& b_frame [[buffer(6)]], const device DrawBuf& b_draw [[buffer(7)]], uint gl_VertexIndex [[vertex_id]], uint gl_InstanceIndex [[instance_id]])
{
    mesh_vert_out out = {};
    uint vi = uint(int(gl_VertexIndex));
    Instance _206;
    _206.model = b_instances.v[int(gl_InstanceIndex)].model;
    _206.tint = b_instances.v[int(gl_InstanceIndex)].tint;
    _206.pick_id = b_instances.v[int(gl_InstanceIndex)].pick_id;
    _206.palette_row = b_instances.v[int(gl_InstanceIndex)].palette_row;
    _206.user = b_instances.v[int(gl_InstanceIndex)].user;
    _206.pad = b_instances.v[int(gl_InstanceIndex)].pad;
    Instance inst = _206;
    uint flags = ((device uint*)&b_draw.d.flags)[0u];
    uint param = vi;
    uint param_1 = 0u;
    float4 world = inst.model * float4(read_vec3(param, param_1, b_positions, b_normals), 1.0);
    float3 n = float3(0.0, 1.0, 0.0);
    if ((flags & 1u) != 0u)
    {
        float3x3 param_2 = float3x3(inst.model[0].xyz, inst.model[1].xyz, inst.model[2].xyz);
        uint param_3 = vi;
        uint param_4 = 1u;
        n = fast::normalize(cofactor(param_2) * read_vec3(param_3, param_4, b_positions, b_normals));
    }
    out.v_world = world.xyz;
    out.v_normal = n;
    float2 _267;
    if ((flags & 2u) != 0u)
    {
        _267 = float2(b_uvs.v[vi * 2u], b_uvs.v[(vi * 2u) + 1u]);
    }
    else
    {
        _267 = float2(0.0);
    }
    out.v_uv = _267;
    float4 color = float4(1.0);
    if ((flags & 4u) != 0u)
    {
        float4 c = unpack_unorm4x8_to_float(b_colors.v[vi]);
        float3 param_5 = c.xyz;
        color = float4(srgb_to_linear(param_5), c.w);
    }
    out.v_color = color * inst.tint;
    uint param_6 = vi;
    uint param_7 = ((device uint*)&b_draw.d.flags)[3u];
    out.v_id = read_id(param_6, param_7, b_ids);
    out.v_palette_row = inst.palette_row;
    float4 ls = b_frame.f.light_view_proj * float4(world.xyz + (n * ((device float*)&b_frame.f.shadow)[1u]), 1.0);
    out.v_shadow = ls.xyz / float3(ls.w);
    float4 view = b_frame.f.view * world;
    out.v_view_depth = -view.z;
    out.gl_Position = b_frame.f.view_proj * world;
    out.gl_Position.y = -(out.gl_Position.y);    // Invert Y-axis for Metal
    return out;
}

