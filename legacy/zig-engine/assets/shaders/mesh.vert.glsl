#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec4 in_color;
layout(location = 3) in vec2 in_uv;
layout(location = 4) in vec4 in_joints;
layout(location = 5) in vec4 in_weights;

layout(set = 1, binding = 0, std140) uniform VertexUniforms {
    mat4 u_view_projection;
    mat4 u_model;
    uvec4 u_skinning_meta;
    mat4 u_skin_matrices[64];
} vertex_uniforms;

layout(location = 0) out vec4 v_color;
layout(location = 1) out vec2 v_uv;
layout(location = 2) out vec3 v_world_normal;
layout(location = 3) out vec3 v_world_position;

mat4 resolve_skin_matrix() {
    if (vertex_uniforms.u_skinning_meta.x == 0u || vertex_uniforms.u_skinning_meta.y == 0u) {
        return mat4(1.0);
    }

    mat4 skin = mat4(0.0);
    float total_weight = 0.0;

    for (int influence = 0; influence < 4; influence++) {
        float weight = in_weights[influence];
        if (weight <= 0.0) {
            continue;
        }

        uint joint_index = uint(in_joints[influence]);
        if (joint_index >= vertex_uniforms.u_skinning_meta.y) {
            continue;
        }

        skin += vertex_uniforms.u_skin_matrices[joint_index] * weight;
        total_weight += weight;
    }

    if (total_weight <= 0.0001) {
        return mat4(1.0);
    }

    return skin;
}

void main() {
    v_color = in_color;
    v_uv = in_uv;

    mat4 skin_matrix = resolve_skin_matrix();
    vec4 local_position = skin_matrix * vec4(in_position, 1.0);
    vec3 local_normal = normalize((skin_matrix * vec4(in_normal, 0.0)).xyz);

    vec4 world_position = vertex_uniforms.u_model * local_position;
    v_world_position = world_position.xyz;
    v_world_normal = normalize((vertex_uniforms.u_model * vec4(local_normal, 0.0)).xyz);
    gl_Position = vertex_uniforms.u_view_projection * world_position;
}
