struct Uniforms {
    mvp : mat4x4<f32>,
};

@group(0) @binding(0) var<uniform> u : Uniforms;
@group(0) @binding(2) var base_color_sampler : sampler;
@group(0) @binding(3) var base_color_texture : texture_2d<f32>;

struct VsIn {
    @location(0) pos            : vec3<f32>,
    @location(1) normal         : vec3<f32>,
    @location(2) color          : vec3<f32>,
    @location(3) uv             : vec2<f32>,
    @location(4) tangent        : vec4<f32>,
    @location(5) material_index : f32,
    @location(6) joints         : vec4<f32>,
    @location(7) weights        : vec4<f32>,
};

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) color : vec3<f32>,
    @location(1) normal : vec3<f32>,
    @location(2) uv : vec2<f32>,
    @location(3) material_index : f32,
};

@vertex
fn vs_main(in : VsIn) -> VsOut {
    var out : VsOut;
    out.position = u.mvp * vec4<f32>(in.pos, 1.0);
    out.color = in.color;
    out.normal = in.normal;
    out.uv = in.uv;
    out.material_index = in.material_index;
    return out;
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let light_dir = normalize(vec3<f32>(0.4, 0.8, 0.6));
    let normal = normalize(in.normal);
    let lambert = max(dot(normal, light_dir), 0.0);
    let rim = pow(1.0 - max(normal.z, 0.0), 2.0);
    let texel = textureSample(base_color_texture, base_color_sampler, in.uv);
    let base = in.color * texel.rgb;
    let hdr = base * (0.22 + lambert * 1.15 + rim * 0.18);
    return vec4<f32>(hdr, texel.a);
}
