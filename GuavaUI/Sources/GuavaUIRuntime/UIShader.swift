/// WGSL source for the UI renderer.
///
/// Vertex layout (matches `UIVertex`, 20 bytes):
///   loc 0: float32x2  pos      (screen pixels)
///   loc 1: float32x2  uv       — sentinel-encoded:
///                                * `u < 0`         → solid color (no sample)
///                                * `0 ≤ u ≤ 1`    → alpha texture (font atlas)
///                                * `u ≥ 10`        → RGBA texture (Image),
///                                                    actual u = u - 10
///                                * `u ≥ 20`        → image alpha mask,
///                                                    actual u = u - 20
///   loc 2: unorm8x4   color    (linear RGBA, used as tint)
///
/// Bindings:
///   group 0, binding 0: uniform { viewport: vec2<f32> } — screen size in pixels
///   group 0, binding 1: 2D texture (alpha font atlas, or RGBA color image)
///   group 0, binding 2: sampler chosen per texture kind
enum UIShader {
    static let wgsl: String = """
    struct Uniforms {
        viewport: vec2<f32>,
        // 1.0 when the render target is sRGB (gamma-correct path); 0.0 for
        // legacy non-sRGB targets (e.g. in-game UI matching the game surface).
        srgb: f32,
        _pad: f32,
    };

    @group(0) @binding(0) var<uniform> u: Uniforms;
    @group(0) @binding(1) var atlas_tex: texture_2d<f32>;
    @group(0) @binding(2) var atlas_sampler: sampler;

    struct VsIn {
        @location(0) pos: vec2<f32>,
        @location(1) uv: vec2<f32>,
        @location(2) color: vec4<f32>,
    };

    struct VsOut {
        @builtin(position) clip: vec4<f32>,
        @location(0) uv: vec2<f32>,
        @location(1) color: vec4<f32>,
    };

    @vertex
    fn vs_main(in: VsIn) -> VsOut {
        var out: VsOut;
        // Map pixel coords to clip space: x in [-1,1], y flipped.
        let ndc_x = (in.pos.x / u.viewport.x) * 2.0 - 1.0;
        let ndc_y = 1.0 - (in.pos.y / u.viewport.y) * 2.0;
        out.clip = vec4<f32>(ndc_x, ndc_y, 0.0, 1.0);
        out.uv = in.uv;
        out.color = in.color;
        return out;
    }

    // sRGB → linear. Vertex/tint colors and sampled image texels are sRGB-
    // encoded; the render target is sRGB, so the shader must output LINEAR and
    // the hardware re-encodes on write. Crucially this also means alpha blending
    // (incl. glyph antialiasing) happens in linear light — gamma-correct, the
    // way DirectWrite/Chromium render text — instead of smearing on gamma-
    // encoded values.
    fn srgb_to_linear(c: vec3<f32>) -> vec3<f32> {
        let lower = c / 12.92;
        let higher = pow((c + vec3<f32>(0.055)) / 1.055, vec3<f32>(2.4));
        return select(higher, lower, c <= vec3<f32>(0.04045));
    }

    @fragment
    fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        let is_srgb = u.srgb > 0.5;
        // sRGB target: output linear so the hardware re-encodes and, crucially,
        // blends in linear light. Non-sRGB target: keep the original behaviour.
        let rgb = select(in.color.rgb, srgb_to_linear(in.color.rgb), is_srgb);
        // u < 0 → solid color path (no texture sample).
        if (in.uv.x < 0.0) {
            return vec4<f32>(rgb, in.color.a);
        }
        // u >= 20 → alpha-mask image. Source alpha is coverage; tint is RGB.
        if (in.uv.x >= 20.0) {
            let real_uv = vec2<f32>(in.uv.x - 20.0, in.uv.y);
            let s = textureSample(atlas_tex, atlas_sampler, real_uv);
            return vec4<f32>(rgb, in.color.a * s.a);
        }
        // u >= 10 → RGBA color image tinted by `color` (icons, the 3D viewport).
        if (in.uv.x >= 10.0) {
            let real_uv = vec2<f32>(in.uv.x - 10.0, in.uv.y);
            let s = textureSample(atlas_tex, atlas_sampler, real_uv);
            let stex = select(s.rgb, srgb_to_linear(s.rgb), is_srgb);
            return vec4<f32>(rgb * stex, in.color.a * s.a);
        }
        // Otherwise: alpha-only font glyph. On sRGB targets the coverage blends
        // gamma-correctly in linear light (the DirectWrite/Chromium way); on
        // legacy targets keep the ad-hoc midtone boost so they don't regress.
        let a = textureSample(atlas_tex, atlas_sampler, in.uv).r;
        let cov = select(pow(a, 0.75), a, is_srgb);
        return vec4<f32>(rgb, in.color.a * cov);
    }
    """
}
