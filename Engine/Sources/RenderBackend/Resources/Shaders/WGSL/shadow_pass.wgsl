struct Uniforms {
    mvp : mat4x4<f32>,
    model : mat4x4<f32>,
    color_tint : vec4<f32>,
};

struct ShadowUniforms {
    light_view_projection : mat4x4<f32>,
    params : vec4<f32>,
};

@group(0) @binding(0) var<uniform> u : Uniforms;
@group(0) @binding(5) var<uniform> shadow : ShadowUniforms;

struct VsIn {
    @location(0) pos : vec3<f32>,
    @location(1) normal : vec3<f32>,
    @location(2) color : vec3<f32>,
};

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) depth : f32,
};

@vertex
fn vs_main(in : VsIn) -> VsOut {
    var out : VsOut;
    let world = u.model * vec4<f32>(in.pos, 1.0);
    out.position = shadow.light_view_projection * world;
    out.depth = clamp(out.position.z / max(out.position.w, 0.00001), 0.0, 1.0);
    return out;
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    return vec4<f32>(vec3<f32>(in.depth), 1.0);
}
