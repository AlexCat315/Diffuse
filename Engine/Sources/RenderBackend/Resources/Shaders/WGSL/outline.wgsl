struct Uniforms {
    mvp : mat4x4<f32>,
};

struct StylizedStyle {
    toon_thresholds : vec4<f32>,
    toon_levels : vec4<f32>,
    ink_wash_color : vec4<f32>,
    params : vec4<f32>,
};

@group(0) @binding(0) var<uniform> u : Uniforms;
@group(0) @binding(1) var<uniform> style : StylizedStyle;

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
};

@vertex
fn vs_main(in : VsIn) -> VsOut {
    var out : VsOut;
    let expanded = in.pos + normalize(in.normal) * style.params.w;
    out.position = u.mvp * vec4<f32>(expanded, 1.0);
    return out;
}

@fragment
fn fs_main() -> @location(0) vec4<f32> {
    return vec4<f32>(0.03, 0.03, 0.04, 1.0);
}
