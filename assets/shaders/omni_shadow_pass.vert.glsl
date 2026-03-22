#version 450

layout(location = 0) in vec3 in_position;
layout(location = 4) in vec4 in_joints;
layout(location = 5) in vec4 in_weights;

layout(set = 0, binding = 0, std140) uniform VertexUniforms {
    mat4 u_view_projection;
    mat4 u_model;
    uvec4 u_skinning_meta;
    mat4 u_skin_matrices[64];
} vertex_uniforms;

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
    vec4 world_position = vertex_uniforms.u_model * (resolve_skin_matrix() * vec4(in_position, 1.0));
    gl_Position = vertex_uniforms.u_view_projection * world_position;
}
