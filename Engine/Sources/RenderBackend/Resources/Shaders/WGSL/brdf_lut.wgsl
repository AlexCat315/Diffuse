// Source-level WGSL port. Runtime execution still needs compute dispatch wiring.

fn fresnel_schlick_roughness(cos_theta : f32, f0 : vec3<f32>, roughness : f32) -> vec3<f32> {
    let one_minus = pow(1.0 - cos_theta, 5.0);
    return f0 + (max(vec3<f32>(1.0 - roughness), f0) - f0) * one_minus;
}

@compute
@workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
    let uv = vec2<f32>(gid.xy) / 256.0;
    let brdf = fresnel_schlick_roughness(clamp(uv.x, 0.0, 1.0), vec3<f32>(0.04), clamp(uv.y, 0.0, 1.0));
    _ = brdf;
}