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

const PARTICLE_WORKGROUP_SIZE: u32 = 64u;
var<workgroup> prefix: array<u32, 256>;
var<workgroup> output_base: u32;

@compute @workgroup_size(64)
fn main(@builtin(local_invocation_id) lane: vec3<u32>) {
    let tid = lane.x;
    if (tid == 0u) { output_base = 0u; }
    workgroupBarrier();
    for (var base = 0u; base < uniforms.params.x; base += PARTICLE_WORKGROUP_SIZE) {
        let index = base + tid;
        var particle: ParticleSimState;
        if (index < uniforms.params.x) { particle = source_particles[index]; }
        let alive = index < uniforms.params.x && particle_alive(particle);
        prefix[tid] = select(0u, 1u, alive);
        workgroupBarrier();
        for (var offset = 1u; offset < PARTICLE_WORKGROUP_SIZE; offset *= 2u) {
            var sum = prefix[tid];
            if (tid >= offset) { sum += prefix[tid - offset]; }
            workgroupBarrier();
            prefix[tid] = sum;
            workgroupBarrier();
        }
        if (alive) {
            let slot = output_base + prefix[tid] - 1u;
            if (slot < uniforms.params.y) { compact_particles[slot] = particle; }
        }
        workgroupBarrier();
        if (tid == 0u) { output_base += prefix[PARTICLE_WORKGROUP_SIZE - 1u]; }
        workgroupBarrier();
    }
    if (tid == 0u) { atomicStore(&metadata.compacted_count, output_base); }
}
