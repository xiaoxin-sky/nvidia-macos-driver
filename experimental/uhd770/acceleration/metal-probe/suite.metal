// Offscreen render suite for uhd770-metal-probe --mode suite; built on CI only.
// Every case uses one oversized triangle per draw (no pixel centre on an edge)
// and writes values that are exact in RGBA8Unorm, so readback needs no tolerance.
#include <metal_stdlib>
using namespace metal;

struct SuiteVertex {
    float4 position [[position]];
    float4 color;
};

static float4 cover(uint vid, float z)
{
    return float4(vid % 3 == 1 ? 3.0f : -1.0f, vid % 3 == 2 ? 3.0f : -1.0f, z, 1.0f);
}

// texture: sample the uploaded source with a nearest sampler at texel centres.
vertex SuiteVertex suite_cover_vertex(uint vid [[vertex_id]])
{
    SuiteVertex out;
    out.position = cover(vid, 0.0f);
    out.color = float4(0.0f);
    return out;
}

fragment float4 suite_texture_fragment(SuiteVertex in [[stage_in]], texture2d<float> source [[texture(0)]])
{
    constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
    const float2 size = float2(source.get_width(), source.get_height());
    return source.sample(nearest, (floor(in.position.xy) + 0.5f) / size);
}

// blend: two overlapping additive draws of (64, 32, 0, 0)/255.
fragment float4 suite_blend_fragment(SuiteVertex in [[stage_in]])
{
    return float4(64.0f / 255.0f, 32.0f / 255.0f, 0.0f, 0.0f);
}

// depth: the near (blue) draw runs first; the far (green) draw must be rejected.
vertex SuiteVertex suite_depth_near_vertex(uint vid [[vertex_id]])
{
    SuiteVertex out;
    out.position = cover(vid, 0.25f);
    out.color = float4(0.0f, 0.0f, 1.0f, 1.0f);
    return out;
}

vertex SuiteVertex suite_depth_far_vertex(uint vid [[vertex_id]])
{
    SuiteVertex out;
    out.position = cover(vid, 0.75f);
    out.color = float4(0.0f, 1.0f, 0.0f, 1.0f);
    return out;
}

fragment float4 suite_color_fragment(SuiteVertex in [[stage_in]])
{
    return in.color;
}

// large and iosurface: integer pixel coordinates folded into exact bytes.
fragment float4 suite_coordinate_fragment(SuiteVertex in [[stage_in]])
{
    const uint2 p = uint2(in.position.xy);
    return float4(float(p.x & 255u) / 255.0f, float(p.y & 255u) / 255.0f,
                  float((p.x >> 8) * 16u + (p.y >> 8)) / 255.0f, 1.0f);
}
