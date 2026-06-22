struct ParticleStateMaintenanceUniforms {
    params: vec4<u32>,
};

struct ParticleSimState {
    position_lifetime: vec4<f32>,
    velocity_age: vec4<f32>,
    size_rotation: vec4<f32>,
    color: vec4<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: ParticleStateMaintenanceUniforms;
@group(0) @binding(1) var<storage, read_write> particles: array<ParticleSimState>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let index = gid.x;
    let capacity = uniforms.params.y;
    if (index >= capacity) {
        return;
    }

    particles[index] = ParticleSimState(
        vec4<f32>(0.0),
        vec4<f32>(0.0),
        vec4<f32>(0.0),
        vec4<f32>(0.0)
    );
}
