struct ParticleSortPrepareUniforms {
    world_transform: mat4x4<f32>,
    params: vec4<f32>,
    sort_params: vec4<f32>,
};

struct ParticleSimState {
    position_lifetime: vec4<f32>,
    velocity_age: vec4<f32>,
    size_rotation: vec4<f32>,
    color: vec4<f32>,
    params: vec4<u32>,
};

struct ParticleSortItem {
    key: f32,
    index: u32,
    padding0: u32,
    padding1: u32,
};

@group(0) @binding(0) var<uniform> uniforms: ParticleSortPrepareUniforms;
@group(0) @binding(1) var<storage, read> sim_particles: array<ParticleSimState>;
@group(0) @binding(2) var<storage, read_write> sort_items: array<ParticleSortItem>;

fn particle_sort_key(particle: ParticleSimState, sort_mode: u32) -> f32 {
    if (particle.position_lifetime.w <= 0.0
        || particle.velocity_age.w >= particle.position_lifetime.w) {
        return 3.402823e38;
    }

    if (sort_mode == 2u) {
        return -particle.velocity_age.w;
    }
    if (sort_mode == 3u) {
        return particle.velocity_age.w;
    }

    let world_position = uniforms.world_transform * vec4<f32>(particle.position_lifetime.xyz, 1.0);
    let inv_w = select(1.0, 1.0 / world_position.w, abs(world_position.w) > 0.0001);
    let world_xyz = world_position.xyz * inv_w;
    let to_camera = world_xyz - uniforms.sort_params.xyz;
    let distance_squared = dot(to_camera, to_camera);
    return select(-distance_squared, distance_squared, sort_mode == 1u);
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let local_index = gid.x;
    let render_count = u32(uniforms.params.x);
    let source_start_index = u32(uniforms.params.y);
    let sort_mode = u32(uniforms.params.z);
    let sort_capacity = u32(uniforms.params.w);
    if (local_index >= sort_capacity) {
        return;
    }

    if (local_index >= render_count) {
        sort_items[local_index] = ParticleSortItem(
            3.402823e38,
            0xffffffffu,
            0u,
            0u
        );
        return;
    }

    let particle = sim_particles[source_start_index + local_index];
    sort_items[local_index] = ParticleSortItem(
        particle_sort_key(particle, sort_mode),
        local_index,
        0u,
        0u
    );
}
