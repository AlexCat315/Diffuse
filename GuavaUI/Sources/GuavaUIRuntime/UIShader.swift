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

    @fragment
    fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
        // u < 0 → solid color path (no texture sample).
        if (in.uv.x < 0.0) {
            return in.color;
        }
        // u >= 20 → alpha-mask image. Use the source alpha as coverage and
        // theme/tint color as final RGB.
        if (in.uv.x >= 20.0) {
            let real_uv = vec2<f32>(in.uv.x - 20.0, in.uv.y);
            let s = textureSample(atlas_tex, atlas_sampler, real_uv);
            return vec4<f32>(in.color.rgb, in.color.a * s.a);
        }
        // u >= 10 → RGBA color image; subtract the 10-unit offset to recover
        // the real uv. Result is the texture sample tinted by `color`.
        if (in.uv.x >= 10.0) {
            let real_uv = vec2<f32>(in.uv.x - 10.0, in.uv.y);
            let s = textureSample(atlas_tex, atlas_sampler, real_uv);
            return in.color * s;
        }
        // Otherwise: alpha-only texture (font glyph). Sample .r as coverage.
        let a = textureSample(atlas_tex, atlas_sampler, in.uv).r;
        // FreeType produces linear coverage fractions, but display gamma (~2.2)
        // causes thin strokes to look lighter/thinner than intended. A mild
        // power curve boosts midtone coverage so 12-14 px labels look crisp
        // on a dark background without appearing artificially bold at larger sizes.
        let a_corrected = pow(a, 0.75);
        return vec4<f32>(in.color.rgb, in.color.a * a_corrected);
    }
    """
}
