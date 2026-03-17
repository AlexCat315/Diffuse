#version 450

layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 2) in vec3 v_world_normal;
layout(location = 3) in vec3 v_world_position;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_base_color;

layout(set = 3, binding = 0, std140) uniform MaterialUniforms {
    vec4 u_base_color_factor;
    vec4 u_camera_world_position;
    vec4 u_light_direction;
    vec4 u_light_color_intensity;
    vec4 u_point_light_position_radius;
    vec4 u_point_light_color_intensity;
    vec4 u_ambient_color;
} material_uniforms;

// ACES Filmic Tonemapping - maps HDR values to LDR smoothly
vec3 ACESFilm(vec3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

void main() {
    vec4 base = texture(u_base_color, v_uv);
    vec3 normal = normalize(v_world_normal);
    vec3 light_vector = normalize(-material_uniforms.u_light_direction.xyz);
    vec3 view_vector = normalize(material_uniforms.u_camera_world_position.xyz - v_world_position);
    vec3 half_vector = normalize(light_vector + view_vector);

    float diffuse_strength = max(dot(normal, light_vector), 0.0);
    float specular_strength = pow(max(dot(normal, half_vector), 0.0), 32.0) * 0.18;

    vec3 point_light_vector = material_uniforms.u_point_light_position_radius.xyz - v_world_position;
    float point_distance = length(point_light_vector);
    vec3 point_light_dir = point_distance > 0.0001 ? point_light_vector / point_distance : vec3(0.0, 1.0, 0.0);
    float point_attenuation = clamp(1.0 - point_distance / max(material_uniforms.u_point_light_position_radius.w, 0.001), 0.0, 1.0);
    point_attenuation *= point_attenuation;
    float point_diffuse = max(dot(normal, point_light_dir), 0.0) * point_attenuation;
    vec3 point_half_vector = normalize(point_light_dir + view_vector);
    float point_specular = pow(max(dot(normal, point_half_vector), 0.0), 24.0) * 0.12 * point_attenuation;

    vec3 albedo = base.rgb * v_color.rgb * material_uniforms.u_base_color_factor.rgb;
    vec3 lighting =
        material_uniforms.u_ambient_color.rgb +
        material_uniforms.u_light_color_intensity.rgb * (material_uniforms.u_light_color_intensity.w * diffuse_strength) +
        material_uniforms.u_light_color_intensity.rgb * specular_strength +
        material_uniforms.u_point_light_color_intensity.rgb * (material_uniforms.u_point_light_color_intensity.w * point_diffuse) +
        material_uniforms.u_point_light_color_intensity.rgb * point_specular;

    vec3 hdr_color = albedo * lighting;
    // Apply ACES tonemapping to prevent overexposure
    vec3 ldr_color = ACESFilm(hdr_color);
    
    out_color = vec4(ldr_color, base.a * v_color.a * material_uniforms.u_base_color_factor.a);
}
