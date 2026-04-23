// Source-level WGSL port. Runtime execution still needs cubemap and storage bindings.

fn hemisphere_direction(sample_uv : vec2<f32>) -> vec3<f32> {
    let phi = sample_uv.x * 6.28318530718;
    let cos_theta = 1.0 - sample_uv.y;
    let sin_theta = sqrt(max(0.0, 1.0 - cos_theta * cos_theta));
    return vec3<f32>(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
}

@compute
@workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
    let sample_uv = vec2<f32>(gid.xy) / 64.0;
    let dir = hemisphere_direction(sample_uv);
    _ = dir;
}