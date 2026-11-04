// W10 spike (docs/windows-osr-spike.md): an off-screen page's frame copied into the card's swap
// chain with the card's 6pt corners cut out, anti-aliased, as Core Animation's cornerRadius
// draws the Mac's card. DirectComposition's own rounded clip (IDCompositionRectangleClip) is
// aliased, even with DCOMPOSITION_BORDER_MODE_SOFT. Drawn with Theme.hlsl's FullscreenVertex.

Texture2D page : register(t0);

cbuffer Card : register(b0) {
    float2 size;    // the frame, px
    float radius;   // the corners, px
    float unused;
};

struct VertexOut {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

float4 RoundedPage(VertexOut i) : SV_Target {
    // Pixel centres, as the frame's own pixels: one texel per pixel, no filtering.
    float2 p = i.position.xy;
    float4 c = page.Load(int3(int2(p), 0));
    // Coverage of a rounded rectangle the frame's size (its signed distance, a pixel-wide ramp).
    float2 q = abs(p - size * 0.5) - (size * 0.5 - radius);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float coverage = saturate(0.5 - d);
    // The page is opaque; premultiplied out at the corners.
    return float4(c.rgb, 1.0) * coverage;
}
