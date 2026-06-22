struct ParticleStateMaintenanceUniforms {
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

@group(0) @binding(0) var<uniform> uniforms: ParticleStateMaintenanceUniforms;
@group(0) @binding(1) var<storage, read> source_particles: array<ParticleSimState>;
@group(0) @binding(2) var<storage, read_write> compact_particles: array<ParticleSimState>;
@group(0) @binding(3) var<storage, read_write> metadata: ParticleSimMetadata;

fn particle_alive(particle: ParticleSimState) -> bool {
    return particle.position_lifetime.w > 0.0
        && particle.velocity_age.w < particle.position_lifetime.w;
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let index = gid.x;
    let count = uniforms.params.x;
    let capacity = uniforms.params.y;
    if (index >= count) {
        return;
    }

    let particle = source_particles[index];
    if (!particle_alive(particle)) {
        return;
    }

    let slot = atomicAdd(&metadata.compacted_count, 1u);
    if (slot < capacity) {
        compact_particles[slot] = particle;
    }
}
