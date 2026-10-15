// Liquid-glass backdrop for floating UI panels.
//
// One program, four jobs, chosen by `params.blur.x`:
//   0 — downsample the frame region behind a panel into a quarter-size target
//   1 — separable gaussian, the direction coming from `params.blur.yz`
//   2 — composite: refracted edge over the blurred body, masked to the panel's
//       rect (`params.blur.yw` carry the lift, `params.glass` the lens, see
//       `composite`)
//   4 — straight copy of the capture into the full-resolution scratch, the
//       sharp source the edges refract
//
// The renderer ping-pongs two scratch textures for the blur and keeps a third
// at capture resolution for the edges, all sized to the panel, so a glass menu
// costs five small passes instead of a full-frame copy. Sampling and blending
// stay in the render target's own space: the scratch targets reuse the frame's
// format, so every sRGB encode and decode is the hardware's job.

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
    float4 shape;        // composite: xy = half size in px, z = corner radius
    // Composite only. The lens: `x` = how far inward the edge band reaches
    // (px from the panel's edge), `y` = how far the band samples outside
    // itself (px, already shrunk by the renderer to what the capture holds),
    // `z` = how much wider the red offset swings than the blue one, `w` spare.
    float4 glass;
};
[[vk::push_constant]] ConstantBuffer<BackdropParams> params : register(b0, space0);
[[vk::binding(1, 0)]] Texture2D<float4> source : register(t1, space0);
[[vk::binding(2, 0)]] SamplerState sourceSampler : register(s2, space0);
[[vk::binding(3, 0)]] Texture2D<float4> sharp : register(t3, space0);

static const int TapCount = 6;

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
// instead of filling the corners the fill leaves transparent. Inside the
// edge band the panel acts as a lens: the sharp capture is sampled from
// beyond the edge and pulled inward, so whatever sits behind the rim reads
// bent — the trait that separates glass from tinted paint. Red and blue
// swing by slightly different amounts, the faint dispersion a real pane has.
float4 composite(BackdropVertex input) {
    float2 halfSize = params.shape.xy;
    float2 local = (input.uv - 0.5) * 2 * halfSize;
    float edge = roundedRectDistance(local);
    float coverage = 1 - smoothstep(-0.5, 0.5, edge);
    // The margin captured around the panel keeps clamped edge pixels out of
    // the blur, so the composite can clamp without smearing them inward.
    float2 uv = clamp(sourceUV(input), float2(0, 0), float2(1, 1));
    // Outward normal, from two extra SDF evals a pixel apart — cheap, and it
    // stays correct around the corner arcs where an analytic gradient splits.
    float2 normal = float2(roundedRectDistance(local + float2(1, 0)) - edge,
                           roundedRectDistance(local + float2(0, 1)) - edge);
    normal = normalize(normal + 1e-6);
    // The band fades in from the edge inward, so the lens lives on the rim
    // and the frosted body is untouched.
    float band = 1 - smoothstep(0, params.glass.x, -edge);
    float2 pull = normal * (params.glass.y * band / (2 * halfSize));
    float3 lens;
    lens.r = sharp.SampleLevel(sourceSampler, clamp(uv + pull * (1 + params.glass.z), float2(0, 0), float2(1, 1)), 0).r;
    lens.g = sharp.SampleLevel(sourceSampler, clamp(uv + pull, float2(0, 0), float2(1, 1)), 0).g;
    lens.b = sharp.SampleLevel(sourceSampler, clamp(uv + pull * (1 - params.glass.z), float2(0, 0), float2(1, 1)), 0).b;
    float3 backdrop = lerp(source.SampleLevel(sourceSampler, uv, 0).rgb, lens, band);
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
    return float4(backdrop, coverage);
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
    // 4 — the same straight copy, kept sharp: the full-resolution capture the
    // edge band refracts. The blur chain's quarter-size targets would soften
    // the lens into invisibility.
    if (mode == 4) return source.SampleLevel(sourceSampler, sourceUV(input), 0);
    return composite(input);
}
#endif
