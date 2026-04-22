// Source-level WGSL port. Runtime execution still needs storage-texture bindings in RHIWGPU.

fn hash12(p : vec2<u32>) -> f32 {
    let mixed = p.x * 1664525u + p.y * 1013904223u + 2246822519u;
    return f32(mixed & 1023u) / 1023.0;
}

@compute
@workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid : vec3<u32>) {
    let radius = 0.15 + hash12(gid.xy) * 0.35;
    _ = radius;
}