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
    @location(0) world_y : f32,
    @location(1) normal : vec3<f32>,
    @location(2) color : vec3<f32>,
};

@vertex
fn vs_main(in : VsIn) -> VsOut {
    var out : VsOut;
    out.position = u.mvp * vec4<f32>(in.pos, 1.0);
    out.world_y = in.pos.y;
    out.normal = in.normal;
    out.color = in.color;
    return out;
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let slope = 1.0 - abs(normalize(in.normal).y);
    let grass = vec3<f32>(0.14, 0.42, 0.12);
    let rock = vec3<f32>(0.45, 0.37, 0.30);
    let snow = vec3<f32>(0.88, 0.90, 0.92);
    let height_mix = smoothstep(0.25, 0.95, in.world_y * 0.5 + 0.5);
    let terrain = mix(mix(grass, rock, slope), snow, height_mix * 0.65);
    return vec4<f32>(terrain * (0.55 + in.color * 0.45), 1.0);
}