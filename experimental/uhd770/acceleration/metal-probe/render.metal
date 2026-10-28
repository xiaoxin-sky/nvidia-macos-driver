// Offscreen render input for uhd770-metal-probe --mode render; built on CI only.
// One oversized triangle covers the whole 64x64 target, so no pixel centre lies
// on an edge. Each fragment writes its own integer pixel coordinate, which makes
// every expected RGBA value exact: (4x, 4y, 128, 255).
#include <metal_stdlib>
using namespace metal;

struct RenderVertex {
    float4 position [[position]];
};

vertex RenderVertex render_vertex(uint vid [[vertex_id]])
{
    RenderVertex out;
    out.position = float4(vid == 1 ? 3.0f : -1.0f, vid == 2 ? 3.0f : -1.0f, 0.0f, 1.0f);
    return out;
}

fragment float4 render_fragment(RenderVertex in [[stage_in]])
{
    const float2 pixel = floor(in.position.xy);
    return float4(pixel.x * 4.0f / 255.0f, pixel.y * 4.0f / 255.0f, 128.0f / 255.0f, 1.0f);
}
