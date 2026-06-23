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
    ribbon_color: vec4<f32>,
    ribbon_params: vec4<f32>,
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

const PARTICLE_CULL_WORKGROUP_SIZE: u32 = 64u;

@group(0) @binding(0) var<uniform> uniforms: ParticleCullUniforms;
@group(0) @binding(1) var<storage, read> source_particles: array<ParticleInstance>;
@group(0) @binding(2) var<storage, read> batches: array<ParticleCullBatch>;
@group(0) @binding(3) var<storage, read_write> visible_particles: array<ParticleInstance>;
@group(0) @binding(4) var<storage, read_write> draw_args: array<ParticleIndirectDrawArgs>;

var<workgroup> visible_flags: array<u32, 64>;
var<workgroup> visible_base: u32;

fn particle_visible(particle: ParticleInstance) -> bool {
    if (particle.position_size.w <= 0.0 || particle.color.w <= 0.0) {
        return false;
    }

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

fn visible_prefix(local_index: u32) -> u32 {
    var count = 0u;
    for (var i = 0u; i < local_index; i = i + 1u) {
        count = count + visible_flags[i];
    }
    return count;
}

fn tile_visible_count() -> u32 {
    var count = 0u;
    for (var i = 0u; i < PARTICLE_CULL_WORKGROUP_SIZE; i = i + 1u) {
        count = count + visible_flags[i];
    }
    return count;
}

@compute @workgroup_size(64)
fn main(
    @builtin(workgroup_id) workgroup_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>
) {
    let batch_index = workgroup_id.x;
    if (batch_index >= uniforms.params.x) {
        return;
    }
    let local_index = local_id.x;

    let batch = batches[batch_index];
    if (local_index == 0u) {
        visible_base = 0u;
    }
    workgroupBarrier();

    for (var tile_start = 0u;
         tile_start < batch.source_count;
         tile_start = tile_start + PARTICLE_CULL_WORKGROUP_SIZE) {
        let source_offset = tile_start + local_index;
        var visible = 0u;
        if (source_offset < batch.source_count) {
            let particle = source_particles[batch.source_start + source_offset];
            visible = select(0u, 1u, particle_visible(particle));
        }
        visible_flags[local_index] = visible;
        workgroupBarrier();

        if (visible == 1u) {
            let particle = source_particles[batch.source_start + source_offset];
            let output_offset = visible_base + visible_prefix(local_index);
            visible_particles[batch.output_start + output_offset] = particle;
        }
        workgroupBarrier();

        if (local_index == 0u) {
            visible_base = visible_base + tile_visible_count();
        }
        workgroupBarrier();
    }

    if (local_index == 0u) {
        draw_args[batch_index] = ParticleIndirectDrawArgs(
            6u,
            visible_base,
            0u,
            batch.output_start
        );
    }
}
