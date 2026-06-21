struct ParticleSimToInstanceUniforms {
    world_transform: mat4x4<f32>,
    params: vec4<f32>,
    uv_rect: vec4<f32>,
};

struct ParticleSimState {
    position_lifetime: vec4<f32>,
    velocity_age: vec4<f32>,
    size_rotation: vec4<f32>,
    color: vec4<f32>,
};

struct ParticleInstance {
    position_size: vec4<f32>,
    rotation: vec4<f32>,
    color: vec4<f32>,
    uv_rect: vec4<f32>,
    axis_stretch: vec4<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: ParticleSimToInstanceUniforms;
@group(0) @binding(1) var<storage, read> sim_particles: array<ParticleSimState>;
@group(0) @binding(2) var<storage, read_write> render_particles: array<ParticleInstance>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let index = gid.x;
    let count = u32(uniforms.params.x);
    let base_instance = u32(uniforms.params.y);
    if (index >= count) {
        return;
    }

    let sim_particle = sim_particles[index];
    let world_position = uniforms.world_transform
        * vec4<f32>(sim_particle.position_lifetime.xyz, 1.0);

    let inv_w = select(1.0, 1.0 / world_position.w, abs(world_position.w) > 0.0001);

    var instance: ParticleInstance;
    instance.position_size = vec4<f32>(
        world_position.xyz * inv_w,
        max(sim_particle.size_rotation.x, 0.0)
    );
    instance.rotation = vec4<f32>(sim_particle.size_rotation.y, 0.0, 0.0, 0.0);
    instance.color = sim_particle.color;
    instance.uv_rect = uniforms.uv_rect;
    instance.axis_stretch = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    render_particles[base_instance + index] = instance;
}
