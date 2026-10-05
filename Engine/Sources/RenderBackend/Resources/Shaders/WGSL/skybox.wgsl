struct SkyboxUniforms {
    inv_view_proj : mat4x4<f32>,
    sky_tint : vec4<f32>,
    horizon_tint : vec4<f32>,
    ground_tint : vec4<f32>,
};

@group(0) @binding(0) var<uniform> u : SkyboxUniforms;

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) world_dir : vec3<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vertex_index : u32) -> VsOut {
    var positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>( 3.0, -1.0),
        vec2<f32>(-1.0,  3.0)
    );

    let pos = positions[vertex_index];
    let clip = vec4<f32>(pos, 1.0, 1.0);
    let world = u.inv_view_proj * clip;
    let near_world = u.inv_view_proj * vec4<f32>(pos, 0.0, 1.0);

    var out : VsOut;
    out.position = vec4<f32>(pos, 1.0, 1.0);
    out.world_dir = normalize(world.xyz / world.w - near_world.xyz / near_world.w);
    return out;
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    // A neutral backdrop keeps the orthographic construction grid readable.
    if u.sky_tint.w > 0.5 {
        return vec4<f32>(u.ground_tint.rgb, 1.0);
    }
    let dir = normalize(in.world_dir);
    let horizon_mix = smoothstep(-0.15, 0.45, dir.y);
    let upper = mix(u.horizon_tint.rgb, u.sky_tint.rgb, smoothstep(0.15, 0.95, dir.y));
    let lower = mix(u.ground_tint.rgb, u.horizon_tint.rgb, smoothstep(-0.95, 0.15, dir.y));
    let sky = mix(lower, upper, horizon_mix);

    let sun_dir = normalize(vec3<f32>(0.35, 0.75, 0.25));
    let sun_amount = pow(max(dot(dir, sun_dir), 0.0), 96.0);
    let sun_glow = pow(max(dot(dir, sun_dir), 0.0), 8.0) * 0.18;

    let color = sky + vec3<f32>(1.8, 1.5, 1.1) * sun_amount + vec3<f32>(0.7, 0.5, 0.28) * sun_glow;
    return vec4<f32>(color, 1.0);
}
