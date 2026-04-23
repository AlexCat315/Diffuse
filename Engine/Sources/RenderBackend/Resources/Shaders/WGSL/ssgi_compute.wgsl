// Source-level WGSL port. Runtime execution still needs storage-texture bindings in RHIWGPU.

fn cosine_weighted_direction(seed : vec2<f32>) -> vec3<f32> {
    let phi = seed.x * 6.28318530718;
    let r = sqrt(seed.y);
    return vec3<f32>(cos(phi) * r, sin(phi) * r, sqrt(max(0.0, 1.0 - seed.y)));
}

@compute
@workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
    let seed = vec2<f32>(gid.xy) / 128.0;
    let ray_dir = cosine_weighted_direction(seed);
    _ = ray_dir;
}