struct ParticleSimUniforms {
    time: vec4<f32>,
    gravity: vec4<f32>,
    noise: vec4<f32>,
    vector_field_direction_strength: vec4<f32>,
    vector_field_params: vec4<f32>,
    force_center_radius: vec4<f32>,
    force_axis_mode: vec4<f32>,
    force_params: vec4<f32>,
    collision_params: vec4<f32>,
    collision_to_world: mat4x4<f32>,
    collision_to_local: mat4x4<f32>,
};

struct ParticleSimState {
    position_lifetime: vec4<f32>,
    velocity_age: vec4<f32>,
    size_rotation: vec4<f32>,
    color: vec4<f32>,
};

struct ParticleSimMetadata {
    alive_count: atomic<u32>,
    expired_count: atomic<u32>,
    collision_count: atomic<u32>,
    spawned_count: atomic<u32>,
    dropped_spawn_count: atomic<u32>,
    append_cursor: atomic<u32>,
    compacted_count: atomic<u32>,
};

struct CollisionResult {
    position: vec3<f32>,
    velocity: vec3<f32>,
    collided: bool,
};

@group(0) @binding(0) var<uniform> uniforms: ParticleSimUniforms;
@group(0) @binding(1) var<storage, read_write> particles: array<ParticleSimState>;
@group(0) @binding(2) var<storage, read_write> metadata: ParticleSimMetadata;

fn safe_normalize(v: vec3<f32>, fallback: vec3<f32>) -> vec3<f32> {
    let len2 = dot(v, v);
    if (len2 <= 0.000001) {
        return fallback;
    }
    return v * inverseSqrt(len2);
}

fn sine_wave(x: f32) -> f32 {
    return sin(x);
}

fn noise_acceleration(position: vec3<f32>, age: f32) -> vec3<f32> {
    let strength = uniforms.noise.x;
    if (strength <= 0.0) {
        return vec3<f32>(0.0);
    }

    let p = position * max(uniforms.noise.y, 0.0001);
    let phase = age * max(uniforms.noise.z, 0.0) + uniforms.noise.w;
    return vec3<f32>(
        sine_wave(p.x * 12.9898 + p.y * 78.233 + p.z * 37.719 + phase),
        sine_wave(p.y * 26.651 + p.z * 91.191 + p.x * 13.153 + phase + 2.17),
        sine_wave(p.z * 54.123 + p.x * 44.531 + p.y * 9.151 + phase + 4.31)
    ) * strength;
}

fn curl_field(position: vec3<f32>, age: f32) -> vec3<f32> {
    let p = position * max(uniforms.vector_field_params.x, 0.0001);
    let phase = age * uniforms.vector_field_params.y + uniforms.time.z;
    let bias = safe_normalize(
        uniforms.vector_field_direction_strength.xyz,
        vec3<f32>(0.0, 1.0, 0.0)
    );
    let field = vec3<f32>(
        sine_wave(p.y * 8.173 + p.z * 3.117 + phase)
            - sine_wave(p.z * 5.731 + p.x * 7.191 - phase),
        sine_wave(p.z * 6.313 + p.x * 4.997 + phase + 1.37)
            - sine_wave(p.x * 9.239 + p.y * 2.173 - phase),
        sine_wave(p.x * 4.113 + p.y * 7.911 + phase + 2.71)
            - sine_wave(p.y * 5.337 + p.z * 6.771 - phase)
    );
    return safe_normalize(field + bias * 0.25, bias);
}

fn vector_field_acceleration(position: vec3<f32>, age: f32) -> vec3<f32> {
    let strength = uniforms.vector_field_direction_strength.w;
    if (strength == 0.0) {
        return vec3<f32>(0.0);
    }

    let mode = uniforms.vector_field_params.z;
    let direction = safe_normalize(
        uniforms.vector_field_direction_strength.xyz,
        vec3<f32>(0.0, 1.0, 0.0)
    );
    if (mode < 0.5) {
        return vec3<f32>(0.0);
    }
    if (mode < 1.5) {
        return direction * strength;
    }
    return curl_field(position, age) * strength;
}

fn force_acceleration(position: vec3<f32>) -> vec3<f32> {
    let mode = uniforms.force_axis_mode.w;
    let strength = uniforms.force_params.x;
    if (mode < 0.5 || strength == 0.0) {
        return vec3<f32>(0.0);
    }

    let center = uniforms.force_center_radius.xyz;
    let radius = max(uniforms.force_center_radius.w, 0.0);
    let offset = position - center;
    let distance = length(offset);
    if (radius > 0.0 && distance >= radius) {
        return vec3<f32>(0.0);
    }

    var attenuation = 1.0;
    if (radius > 0.0) {
        attenuation = pow(max(0.0, 1.0 - distance / radius), max(uniforms.force_params.y, 0.0));
    }
    if (attenuation <= 0.0) {
        return vec3<f32>(0.0);
    }

    if (mode < 1.5) {
        if (distance <= 0.0001) {
            return vec3<f32>(0.0);
        }
        return (offset / distance) * strength * attenuation;
    }

    let axis = safe_normalize(uniforms.force_axis_mode.xyz, vec3<f32>(0.0, 1.0, 0.0));
    let planar = offset - axis * dot(offset, axis);
    let planar_distance = length(planar);
    if (planar_distance <= 0.0001) {
        return vec3<f32>(0.0);
    }
    let radial = planar / planar_distance;
    let tangent = safe_normalize(cross(axis, radial), vec3<f32>(0.0, 0.0, 1.0));
    return tangent * strength * attenuation;
}

fn particle_collision(position: vec3<f32>, velocity: vec3<f32>) -> CollisionResult {
    let mode = uniforms.collision_params.x;
    if (mode < 0.5) {
        return CollisionResult(position, velocity, false);
    }

    let plane_y = uniforms.collision_params.y;
    let restitution = clamp(uniforms.collision_params.z, 0.0, 1.0);
    let tangent_scale = 1.0 - clamp(uniforms.collision_params.w, 0.0, 1.0);
    var resolved_position = position;
    var resolved_velocity = velocity;

    if (mode < 1.5) {
        if (resolved_position.y < plane_y) {
            resolved_position.y = plane_y;
            if (resolved_velocity.y < 0.0) {
                resolved_velocity = vec3<f32>(
                    resolved_velocity.x * tangent_scale,
                    -resolved_velocity.y * restitution,
                    resolved_velocity.z * tangent_scale
                );
            }
            return CollisionResult(resolved_position, resolved_velocity, true);
        }
        return CollisionResult(resolved_position, resolved_velocity, false);
    }

    var world_position = uniforms.collision_to_world * vec4<f32>(resolved_position, 1.0);
    var collided = false;
    if (world_position.y < plane_y) {
        collided = true;
        world_position.y = plane_y;
        let local_position = uniforms.collision_to_local * world_position;
        if (abs(local_position.w) > 0.0001) {
            resolved_position = local_position.xyz / local_position.w;
        } else {
            resolved_position = local_position.xyz;
        }

        let world_velocity = uniforms.collision_to_world * vec4<f32>(resolved_velocity, 0.0);
        if (world_velocity.y < 0.0) {
            let bounced_world_velocity = vec4<f32>(
                world_velocity.x * tangent_scale,
                -world_velocity.y * restitution,
                world_velocity.z * tangent_scale,
                0.0
            );
            resolved_velocity = (uniforms.collision_to_local * bounced_world_velocity).xyz;
        }
    }

    return CollisionResult(resolved_position, resolved_velocity, collided);
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let index = gid.x;
    if (index >= u32(uniforms.time.y)) {
        return;
    }

    var particle = particles[index];
    var position = particle.position_lifetime.xyz;
    let lifetime = particle.position_lifetime.w;
    var velocity = particle.velocity_age.xyz;
    var age = particle.velocity_age.w;

    if (lifetime <= 0.0) {
        return;
    }

    if (age >= lifetime) {
        _ = atomicAdd(&metadata.expired_count, 1u);
        return;
    }

    let dt = max(uniforms.time.x, 0.0);
    let noise = noise_acceleration(position, age);
    let field = vector_field_acceleration(position, age);
    let force = force_acceleration(position);
    velocity = velocity + (uniforms.gravity.xyz + noise + force + field) * dt;
    position = position + velocity * dt;
    let collision = particle_collision(position, velocity);
    position = collision.position;
    velocity = collision.velocity;
    if (collision.collided) {
        _ = atomicAdd(&metadata.collision_count, 1u);
    }
    age = min(age + dt, lifetime);

    particle.position_lifetime = vec4<f32>(position, lifetime);
    particle.velocity_age = vec4<f32>(velocity, age);
    particle.size_rotation.y = particle.size_rotation.y + particle.size_rotation.z * dt;
    particles[index] = particle;
    if (age < lifetime) {
        _ = atomicAdd(&metadata.alive_count, 1u);
    } else {
        _ = atomicAdd(&metadata.expired_count, 1u);
    }
}
