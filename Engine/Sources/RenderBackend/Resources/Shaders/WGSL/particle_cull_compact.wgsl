struct ParticleCullUniforms {
    view_proj: mat4x4<f32>,
    params: vec4<u32>,
};

struct ParticleInstance {
    position_size: vec4<f32>,
    rotation: vec4<f32>,
    color: vec4<f32>,
    uv_rect: vec4<f32>,
    axis_stretch: vec4<f32>,
};

struct ParticleCullBatch {
    source_start: u32,
    source_count: u32,
    output_start: u32,
    padding: u32,
};

struct ParticleIndirectDrawArgs {
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
};

@group(0) @binding(0) var<uniform> uniforms: ParticleCullUniforms;
@group(0) @binding(1) var<storage, read> source_particles: array<ParticleInstance>;
@group(0) @binding(2) var<storage, read> batches: array<ParticleCullBatch>;
@group(0) @binding(3) var<storage, read_write> visible_particles: array<ParticleInstance>;
@group(0) @binding(4) var<storage, read_write> draw_args: array<ParticleIndirectDrawArgs>;

fn particle_visible(particle: ParticleInstance) -> bool {
    let clip = uniforms.view_proj * vec4<f32>(particle.position_size.xyz, 1.0);
    if (abs(clip.w) <= 0.0001) {
        return false;
    }

    let ndc = clip.xyz / clip.w;
    let radius = max(particle.position_size.w * max(particle.axis_stretch.w, 1.0), 0.0);
    let padding = clamp(radius * 0.25, 0.0, 0.25);
    return ndc.x >= -1.0 - padding
        && ndc.x <= 1.0 + padding
        && ndc.y >= -1.0 - padding
        && ndc.y <= 1.0 + padding;
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let batch_index = gid.x;
    if (batch_index >= uniforms.params.x) {
        return;
    }

    let batch = batches[batch_index];
    var visible_count = 0u;
    for (var i = 0u; i < batch.source_count; i = i + 1u) {
        let particle = source_particles[batch.source_start + i];
        if (particle_visible(particle)) {
            visible_particles[batch.output_start + visible_count] = particle;
            visible_count = visible_count + 1u;
        }
    }

    draw_args[batch_index] = ParticleIndirectDrawArgs(
        6u,
        visible_count,
        0u,
        batch.output_start
    );
}
