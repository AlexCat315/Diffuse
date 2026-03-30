#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec4 in_color;
layout(location = 3) in vec2 in_uv;
layout(location = 4) in vec4 in_joints;
layout(location = 5) in vec4 in_weights;

layout(set = 1, binding = 0, std140) uniform VelocityVertexUniforms {
    mat4 u_current_view_projection;
    mat4 u_prev_view_projection;
    mat4 u_model;
    mat4 u_prev_model;
    uvec4 u_skinning_meta;
    mat4 u_skin_matrices[64];
} velocity_uniforms;

layout(location = 0) out vec4 v_current_clip;
layout(location = 1) out vec4 v_prev_clip;

mat4 resolve_skin_matrix() {
    if (velocity_uniforms.u_skinning_meta.x == 0u || velocity_uniforms.u_skinning_meta.y == 0u) {
        return mat4(1.0);
    }

    mat4 skin = mat4(0.0);
    float total_weight = 0.0;

    for (int influence = 0; influence < 4; ++influence) {
        float weight = in_weights[influence];
        if (weight <= 0.0) {
            continue;
        }

        uint joint_index = uint(in_joints[influence]);
        if (joint_index >= velocity_uniforms.u_skinning_meta.y) {
            continue;
        }

        skin += velocity_uniforms.u_skin_matrices[joint_index] * weight;
        total_weight += weight;
    }

    if (total_weight <= 0.0001) {
        return mat4(1.0);
    }

    return skin;
}

void main() {
    mat4 skin_matrix = resolve_skin_matrix();
    vec4 local_position = skin_matrix * vec4(in_position, 1.0);

    vec4 current_world_position = velocity_uniforms.u_model * local_position;
    vec4 prev_world_position = velocity_uniforms.u_prev_model * local_position;

    v_current_clip = velocity_uniforms.u_current_view_projection * current_world_position;
    v_prev_clip = velocity_uniforms.u_prev_view_projection * prev_world_position;
    gl_Position = v_current_clip;
}
