// Offscreen capture and frame compositing for the UI pass.
//
// One program, five jobs, chosen by `params.blur.x`:
//   0 — downsample the frame region behind a panel into a quarter-size target
//   1 — separable gaussian, the direction coming from `params.blur.yz`
//   2 — composite: the blurred body, masked to the panel's rounded rect
//       (`params.blur.yw` carry the saturation and the lift, see `composite`)
//   3 — straight copy of the frame into the swapchain, which is only ever a
//       render target and must never be sampled itself
//   4 — reveal: put the retained frame back over the current one, masked to a
//       disc, so the new frame shows through a circle growing from a point
//
// The renderer ping-pongs two scratch textures for the blur, both sized to the
// panel, so a frosted menu costs four small passes instead of a full-frame
// copy. Sampling and blending stay in the render target's own space: the
// scratch targets reuse the frame's format, so every sRGB encode and decode is
// the hardware's job.

struct BackdropVertex {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

// Compile stages separately so offline reflection exposes only each stage's ABI.
#if BACKDROP_VERTEX_SHADER
struct Input { float2 position : TEXCOORD0; float2 uv : TEXCOORD1; };
[shader("vertex")]
BackdropVertex backdropVertex(Input input) {
    BackdropVertex output;
    output.position = float4(input.position, 0, 1);
    output.uv = input.uv;
    return output;
}
#else
struct BackdropParams {
    // Destination uv -> source uv. One pass' worth of crop and scale; the
    // renderer bakes the panel's rect, its blur margin and the ping-pong
    // sizes into this so no branch has to know which pass it is.
    float4 uvTransform;  // xy = scale, zw = offset
    float4 blur;         // x = mode, yz = uv step per tap, w = sigma in texels
    float4 shape;        // composite: xy = half size in px, z = radius, w = opacity
                         // reveal:   xy = half frame size in px
    float4 reveal;       // reveal:   xy = centre in px, z = radius, w = feather
};
[[vk::push_constant]] ConstantBuffer<BackdropParams> params : register(b0, space0);
[[vk::binding(1, 0)]] Texture2D<float4> source : register(t1, space0);
[[vk::binding(2, 0)]] SamplerState sourceSampler : register(s2, space0);

// 25 taps reach two sigma with at most one and a half texels between them,
// so bilinear filtering covers the gap; sparser taps alias detail behind the
// panel into a visible dot grid.
static const int TapCount = 12;

float2 sourceUV(BackdropVertex input) {
    return input.uv * params.uvTransform.xy + params.uvTransform.zw;
}

// Four bilinear taps over a 4x4 block: enough for a source that is about to be
// blurred, and cheap enough to run per panel.
float4 downsample(BackdropVertex input) {
    float2 uv = sourceUV(input);
    float2 texel = params.blur.yz;
    float3 sum = source.SampleLevel(sourceSampler, uv + texel * float2(-1, -1), 0).rgb;
    sum += source.SampleLevel(sourceSampler, uv + texel * float2( 1, -1), 0).rgb;
    sum += source.SampleLevel(sourceSampler, uv + texel * float2(-1,  1), 0).rgb;
    sum += source.SampleLevel(sourceSampler, uv + texel * float2( 1,  1), 0).rgb;
    return float4(sum * 0.25, 1);
}

float4 blur(BackdropVertex input) {
    float2 uv = sourceUV(input);
    float2 step = params.blur.yz;
    // Sigma arrives in tap units, so the weights follow real distance.
    float sigma = max(params.blur.w, 0.0001);
    float3 sum = float3(0, 0, 0);
    float total = 0;
    for (int i = -TapCount; i <= TapCount; i++) {
        float offset = float(i);
        float weight = exp(-0.5 * offset * offset / (sigma * sigma));
        sum += source.SampleLevel(sourceSampler, uv + step * offset, 0).rgb * weight;
        total += weight;
    }
    return float4(sum / total, 1);
}

// Signed distance to the panel's rounded rect, in physical pixels, negative
// inside. `local` is the panel-space position the composite's uv maps to.
float roundedRectDistance(float2 local) {
    float2 halfSize = params.shape.xy;
    float radius = min(params.shape.z, min(halfSize.x, halfSize.y));
    float2 offset = abs(local) - (halfSize - radius);
    return length(max(offset, float2(0, 0))) + min(max(offset.x, offset.y), 0) - radius;
}

// Rounded-rect coverage, so the frost stops where the panel's fill stops
// instead of filling the corners the fill leaves transparent.
float4 composite(BackdropVertex input) {
    float2 halfSize = params.shape.xy;
    float2 local = (input.uv - 0.5) * 2 * halfSize;
    float edge = roundedRectDistance(local);
    float coverage = 1 - smoothstep(-0.5, 0.5, edge);
    // The margin captured around the panel keeps clamped edge pixels out of
    // the blur, so the composite can clamp without smearing them inward.
    float2 uv = clamp(sourceUV(input), float2(0, 0), float2(1, 1));
    float3 backdrop = source.SampleLevel(sourceSampler, uv, 0).rgb;
    // Blur alone is not a material. Over a plain window the blurred frame is
    // the same colour as the fill, so the panel is indistinguishable from
    // paint; the frost is only ever visible where the backdrop happened to
    // have structure. Real glass also lifts what it passes: colour is pushed
    // away from its own luma and the whole result comes up a little, so the
    // material reads as glass over any backdrop, plain or busy. `blur.yw`
    // carries the two strengths here (they are unused by this mode).
    float luma = dot(backdrop, float3(0.2126, 0.7152, 0.0722));
    // The lift is mirrored around mid-luma. Over a dark backdrop glass reads as
    // lit, so pushing up is right; over a light one the same push runs into
    // white and does nothing at all — which is why the frost showed on the dark
    // theme and went missing on the light one. Mid-grey is where any
    // directional push is weakest, so it keeps a floor rather than collapsing
    // to nothing and taking the frost with it.
    float direction = 1 - 2 * luma;
    direction = sign(direction) * max(abs(direction), 0.4);
    backdrop = saturate(luma + (backdrop - luma) * params.blur.y
                        + params.blur.w * direction);
    return float4(backdrop, coverage * params.shape.w);
}

// Reveal the current frame through the retained one inside a growing disc.
// Alpha is the coverage, because the pipeline is alpha blended and the current
// frame is already in the target: outside coverage keeps the retained frame,
// while zero coverage inside the disc leaves the new frame alone.
float4 revealComposite(BackdropVertex input) {
    // uv 0..1 covers the whole frame, and y runs downwards in screen space.
    float2 pixel = input.uv * 2 * params.shape.xy;
    float distance = length(pixel - params.reveal.xy);
    float feather = max(params.reveal.w, 0.0001);
    // A hard edge crawls as the radius grows; the band keeps the boundary a
    // clean anti-aliased boundary instead of a staircase of pixels.
    float coverage = params.reveal.z <= 0 ? 1
        : smoothstep(params.reveal.z - feather, params.reveal.z + feather, distance);
    float3 retained = source.SampleLevel(sourceSampler, sourceUV(input), 0).rgb;
    return float4(retained, coverage);
}

[shader("fragment")]
float4 backdropFragment(BackdropVertex input) : SV_Target {
    int mode = int(params.blur.x + 0.5);
    if (mode == 0) return downsample(input);
    if (mode == 1) return blur(input);
    // 3 — straight copy. The window keeps its frame in an owned texture so a
    // panel can sample it; this hands that frame to the swapchain, which is
    // only ever a render target and must never be sampled itself.
    if (mode == 3) return source.SampleLevel(sourceSampler, sourceUV(input), 0);

    if (mode == 4) return revealComposite(input);
    return composite(input);
}
#endif
