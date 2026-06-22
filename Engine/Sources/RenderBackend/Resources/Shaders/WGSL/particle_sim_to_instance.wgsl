struct ParticleSimToInstanceUniforms {
    world_transform: mat4x4<f32>,
    params: vec4<f32>,
    uv_rect: vec4<f32>,
    texture_sheet: vec4<f32>,
    render_params: vec4<f32>,
    trail_params: vec4<f32>,
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

fn texture_sheet_uv_rect(particle: ParticleSimState) -> vec4<f32> {
    let columns = max(u32(uniforms.texture_sheet.x), 1u);
    let rows = max(u32(uniforms.texture_sheet.y), 1u);
    let max_frames = max(columns * rows, 1u);
    let frame_count = min(max(u32(uniforms.texture_sheet.z), 1u), max_frames);
    var frame_index: u32;
    if (uniforms.texture_sheet.w > 0.0) {
        frame_index = min(
            u32(max(floor(particle.velocity_age.w * uniforms.texture_sheet.w), 0.0)),
            frame_count - 1u
        );
    } else {
        let normalized_age = select(
            0.0,
            clamp(particle.velocity_age.w / particle.position_lifetime.w, 0.0, 1.0),
            particle.position_lifetime.w > 0.0001
        );
        frame_index = min(
            u32(max(floor(normalized_age * f32(frame_count)), 0.0)),
            frame_count - 1u
        );
    }

    let column = frame_index % columns;
    let row = frame_index / columns;
    let sheet_rect = vec4<f32>(
        f32(column) / f32(columns),
        f32(row) / f32(rows),
        1.0 / f32(columns),
        1.0 / f32(rows)
    );
    return vec4<f32>(
        uniforms.uv_rect.xy + sheet_rect.xy * uniforms.uv_rect.zw,
        sheet_rect.zw * uniforms.uv_rect.zw
    );
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let output_index = gid.x;
    let count = u32(uniforms.params.x);
    let base_instance = u32(uniforms.params.y);
    let source_start_index = u32(uniforms.params.z);
    let trail_segments = select(0u, u32(uniforms.trail_params.x), uniforms.trail_params.y > 0.0);
    let instance_multiplier = 1u + trail_segments;
    let total_instance_count = count * instance_multiplier;
    if (output_index >= total_instance_count) {
        return;
    }

    let index = source_start_index + output_index / instance_multiplier;
    let segment = output_index % instance_multiplier;
    let sim_particle = sim_particles[index];
    let output_instance = base_instance + output_index;
    if (sim_particle.position_lifetime.w <= 0.0
        || sim_particle.velocity_age.w >= sim_particle.position_lifetime.w) {
        render_particles[output_instance] = ParticleInstance(
            vec4<f32>(0.0),
            vec4<f32>(0.0),
            vec4<f32>(0.0),
            uniforms.uv_rect,
            vec4<f32>(0.0, 0.0, 0.0, 1.0)
        );
        return;
    }

    let world_position = uniforms.world_transform
        * vec4<f32>(sim_particle.position_lifetime.xyz, 1.0);
    let world_velocity = (uniforms.world_transform
        * vec4<f32>(sim_particle.velocity_age.xyz, 0.0)).xyz;

    let inv_w = select(1.0, 1.0 / world_position.w, abs(world_position.w) > 0.0001);
    var axis_stretch = vec4<f32>(0.0, 0.0, 0.0, 1.0);
    if (uniforms.render_params.x > 0.5) {
        let speed = length(world_velocity);
        if (speed > 0.0001) {
            axis_stretch = vec4<f32>(
                world_velocity / speed,
                min(max(uniforms.render_params.z, 1.0),
                    max(1.0, 1.0 + speed * max(uniforms.render_params.y, 0.0)))
            );
        }
    }

    let trail_t = select(0.0, f32(segment) / max(f32(trail_segments), 1.0), segment > 0u);
    let trail_offset = world_velocity * uniforms.trail_params.y * trail_t;
    let trail_size_scale = mix(1.0, max(uniforms.trail_params.z, 0.0), trail_t);
    let trail_alpha_scale = mix(1.0, clamp(uniforms.trail_params.w, 0.0, 1.0), trail_t);
    var color = sim_particle.color;
    color.a = color.a * clamp(uniforms.render_params.w, 0.0, 1.0) * trail_alpha_scale;

    var instance: ParticleInstance;
    instance.position_size = vec4<f32>(
        world_position.xyz * inv_w - trail_offset,
        max(sim_particle.size_rotation.x * trail_size_scale, 0.0)
    );
    instance.rotation = vec4<f32>(sim_particle.size_rotation.y, 0.0, 0.0, 0.0);
    instance.color = color;
    instance.uv_rect = texture_sheet_uv_rect(sim_particle);
    instance.axis_stretch = axis_stretch;
    render_particles[output_instance] = instance;
}
