struct ParticleSimMetadata {
    alive_count: atomic<u32>,
    expired_count: atomic<u32>,
    collision_count: atomic<u32>,
    spawned_count: atomic<u32>,
    dropped_spawn_count: atomic<u32>,
    append_cursor: atomic<u32>,
    compacted_count: atomic<u32>,
};

@group(0) @binding(0) var<storage, read_write> metadata: ParticleSimMetadata;

@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x > 0u) {
        return;
    }

    atomicStore(&metadata.alive_count, 0u);
    atomicStore(&metadata.expired_count, 0u);
    atomicStore(&metadata.collision_count, 0u);
    atomicStore(&metadata.spawned_count, 0u);
    atomicStore(&metadata.dropped_spawn_count, 0u);
    atomicStore(&metadata.compacted_count, 0u);
}
