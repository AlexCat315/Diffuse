struct ParticleSimUniforms {
    time: vec4<f32>,
    gravity: vec4<f32>,
    vector_field_direction_strength: vec4<f32>,
    vector_field_params: vec4<f32>,
    force_center_radius: vec4<f32>,
    force_axis_mode: vec4<f32>,
    force_params: vec4<f32>,
};

struct ParticleSimState {
    position_lifetime: vec4<f32>,
    velocity_age: vec4<f32>,
    size_rotation: vec4<f32>,
    color: vec4<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: ParticleSimUniforms;
@group(0) @binding(1) var<storage, read_write> particles: array<ParticleSimState>;

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

    if (age >= lifetime) {
        return;
    }

    let dt = max(uniforms.time.x, 0.0);
    let field = vector_field_acceleration(position, age);
    let force = force_acceleration(position);
    velocity = velocity + (uniforms.gravity.xyz + field + force) * dt;
    position = position + velocity * dt;
    age = min(age + dt, lifetime);

    particle.position_lifetime = vec4<f32>(position, lifetime);
    particle.velocity_age = vec4<f32>(velocity, age);
    particle.size_rotation.y = particle.size_rotation.y + particle.size_rotation.z * dt;
    particles[index] = particle;
}
