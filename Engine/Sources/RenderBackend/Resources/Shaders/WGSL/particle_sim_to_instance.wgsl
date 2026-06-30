struct ParticleSimToInstanceUniforms {
    world_transform: mat4x4<f32>,
    params: vec4<f32>,
    uv_rect: vec4<f32>,
    texture_sheet: vec4<f32>,
    render_params: vec4<f32>,
    trail_params: vec4<f32>,
    texture_sheet_playback: vec4<f32>,
    appearance_size: vec4<f32>,
    appearance_start_color: vec4<f32>,
    appearance_end_color: vec4<f32>,
    appearance_color_curve: vec4<f32>,
};

struct ParticleSimState {
    position_lifetime: vec4<f32>,
    velocity_age: vec4<f32>,
    size_rotation: vec4<f32>,
    color: vec4<f32>,
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

struct ParticleSortItem {
    key: f32,
    index: u32,
    padding0: u32,
    padding1: u32,
};

@group(0) @binding(0) var<uniform> uniforms: ParticleSimToInstanceUniforms;
@group(0) @binding(1) var<storage, read> sim_particles: array<ParticleSimState>;
@group(0) @binding(2) var<storage, read_write> render_particles: array<ParticleInstance>;
@group(0) @binding(3) var<storage, read> sorted_particles: array<ParticleSortItem>;

fn texture_sheet_uv_rect(particle: ParticleSimState) -> vec4<f32> {
    let columns = max(u32(uniforms.texture_sheet.x), 1u);
    let rows = max(u32(uniforms.texture_sheet.y), 1u);
    let max_frames = max(columns * rows, 1u);
    let start_frame = min(u32(max(uniforms.texture_sheet_playback.y, 0.0)), max_frames - 1u);
    let frame_count = min(max(u32(uniforms.texture_sheet.z), 1u), max_frames - start_frame);
    let random_range = min(u32(max(uniforms.texture_sheet_playback.z, 0.0)), frame_count - 1u);
    let random_offset = select(0u, particle.params.z % (random_range + 1u), random_range > 0u);
    let first_frame = min(frame_count - 1u, random_offset);
    let mode = u32(max(uniforms.texture_sheet_playback.x, 0.0));
    let normalized_age = select(
        0.0,
        clamp(particle.velocity_age.w / particle.position_lifetime.w, 0.0, 1.0),
        particle.position_lifetime.w > 0.0001
    );
    let play_once_rate = select(f32(frame_count), uniforms.texture_sheet.w, uniforms.texture_sheet.w > 0.0);
    var advanced_frame: u32 = 0u;
    if (mode == 0u) {
        if (uniforms.texture_sheet.w > 0.0) {
            advanced_frame = u32(max(floor(max(particle.velocity_age.w, 0.0) * uniforms.texture_sheet.w), 0.0));
        } else {
            advanced_frame = u32(max(floor(normalized_age * f32(frame_count)), 0.0));
        }
    } else if (mode == 1u) {
        advanced_frame = u32(max(floor(normalized_age * f32(frame_count)), 0.0));
    } else if (mode == 2u || mode == 3u) {
        advanced_frame = u32(max(floor(max(particle.velocity_age.w, 0.0) * play_once_rate), 0.0));
    }

    var frame_index: u32;
    if (mode == 3u) {
        frame_index = start_frame + ((first_frame + advanced_frame) % frame_count);
    } else if (mode == 4u) {
        frame_index = start_frame + first_frame;
    } else {
        frame_index = start_frame + min(frame_count - 1u, first_frame + advanced_frame);
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

fn particle_normalized_age(particle: ParticleSimState) -> f32 {
    return select(
        0.0,
        clamp(particle.velocity_age.w / particle.position_lifetime.w, 0.0, 1.0),
        particle.position_lifetime.w > 0.0001
    );
}

fn particle_curve_value(mode: f32, constant_value: f32, t: f32) -> f32 {
    if (mode < 0.5) {
        return -1.0;
    }
    if (mode < 1.5) {
        return constant_value;
    }
    if (mode < 2.5) {
        return t;
    }
    if (mode < 3.5) {
        return t * t;
    }
    if (mode < 4.5) {
        return 1.0 - (1.0 - t) * (1.0 - t);
    }
    let inv = -2.0 * t + 2.0;
    return select(
        2.0 * t * t,
        1.0 - inv * inv * 0.5,
        t >= 0.5
    );
}

fn particle_appearance_size(particle: ParticleSimState, t: f32) -> f32 {
    if (uniforms.appearance_color_curve.z < 0.5 || particle.params.y != 0u) {
        return max(particle.size_rotation.x, 0.0);
    }
    let size_t = particle_curve_value(uniforms.appearance_size.z, uniforms.appearance_size.w, t);
    if (size_t < 0.0) {
        return max(particle.size_rotation.x, 0.0);
    }
    let authored_size = mix(
        max(uniforms.appearance_size.x, 0.0),
        max(uniforms.appearance_size.y, 0.0),
        size_t
    );
    return max(authored_size * max(particle.size_rotation.w, 0.0), 0.0);
}

fn particle_appearance_color(particle: ParticleSimState, t: f32) -> vec4<f32> {
    if (uniforms.appearance_color_curve.z < 0.5 || particle.params.y != 0u) {
        return particle.color;
    }
    let color_t = particle_curve_value(uniforms.appearance_color_curve.x, uniforms.appearance_color_curve.y, t);
    if (color_t < 0.0) {
        return particle.color;
    }
    return mix(uniforms.appearance_start_color, uniforms.appearance_end_color, color_t);
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

    let local_particle_index = output_index / instance_multiplier;
    let sorted_particle_index = sorted_particles[local_particle_index].index;
    let index = source_start_index + sorted_particle_index;
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
            vec4<f32>(0.0, 0.0, 0.0, 1.0),
            vec4<f32>(0.0),
            vec4<f32>(0.0)
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
    let normalized_age = particle_normalized_age(sim_particle);
    var color = particle_appearance_color(sim_particle, normalized_age);
    color.a = color.a * clamp(uniforms.render_params.w, 0.0, 1.0) * trail_alpha_scale;
    let size = max(particle_appearance_size(sim_particle, normalized_age) * trail_size_scale, 0.0);

    var instance: ParticleInstance;
    instance.position_size = vec4<f32>(
        world_position.xyz * inv_w - trail_offset,
        size
    );
    instance.rotation = vec4<f32>(sim_particle.size_rotation.y, 0.0, 0.0, 0.0);
    instance.color = color;
    instance.uv_rect = texture_sheet_uv_rect(sim_particle);
    instance.axis_stretch = axis_stretch;
    instance.ribbon_color = color;
    instance.ribbon_params = vec4<f32>(size, size, 0.0, 0.0);
    render_particles[output_instance] = instance;
}
