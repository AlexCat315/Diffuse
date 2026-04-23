struct Uniforms {
    mvp : mat4x4<f32>,
};

@group(0) @binding(0) var<uniform> u : Uniforms;

struct VsIn {
    @location(0) pos : vec3<f32>,
    @location(1) normal : vec3<f32>,
    @location(2) color : vec3<f32>,
};

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) id_color : vec3<f32>,
};

@vertex
fn vs_main(in : VsIn) -> VsOut {
    var out : VsOut;
    out.position = u.mvp * vec4<f32>(in.pos, 1.0);
    out.id_color = fract(in.color * vec3<f32>(1.0, 0.73, 0.41) + vec3<f32>(0.11, 0.27, 0.53));
    return out;
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    return vec4<f32>(in.id_color, 1.0);
}