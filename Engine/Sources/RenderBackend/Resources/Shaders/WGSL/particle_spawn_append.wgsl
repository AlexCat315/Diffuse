struct ParticleSpawnUniforms {
    params: vec4<u32>,
};

struct ParticleSimState {
    position_lifetime: vec4<f32>,
    velocity_age: vec4<f32>,
    size_rotation: vec4<f32>,
    color: vec4<f32>,
    params: vec4<u32>,
};

struct ParticleSimMetadata {
    alive_count: atomic<u32>,
    expired_count: atomic<u32>,
    collision_count: atomic<u32>,
    spawned_count: atomic<u32>,
    dropped_spawn_count: atomic<u32>,
    append_cursor: atomic<u32>,
    compacted_count: atomic<u32>,
    event_count: atomic<u32>,
};

@group(0) @binding(0) var<uniform> uniforms: ParticleSpawnUniforms;
@group(0) @binding(1) var<storage, read> spawn_particles: array<ParticleSimState>;
@group(0) @binding(2) var<storage, read_write> particles: array<ParticleSimState>;
@group(0) @binding(3) var<storage, read_write> metadata: ParticleSimMetadata;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let index = gid.x;
    let requested_count = uniforms.params.x;
    let capacity = uniforms.params.y;
    if (index >= requested_count) {
        return;
    }

    let slot = atomicAdd(&metadata.append_cursor, 1u);
    if (slot >= capacity) {
        _ = atomicAdd(&metadata.dropped_spawn_count, 1u);
        return;
    }

    particles[slot] = spawn_particles[index];
    _ = atomicAdd(&metadata.spawned_count, 1u);
}
