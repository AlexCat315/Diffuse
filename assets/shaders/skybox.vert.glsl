#version 450

layout(location = 0) out vec3 v_world_dir;

layout(set = 0, binding = 0, std140) uniform VertexUniforms {
    mat4 projection;
    mat4 view;
    vec4 camera_position;
    mat4 inv_vp;
} uniforms;

void main() {
    vec2 positions[3] = vec2[](
        vec2(-1.0, -1.0),
        vec2( 3.0, -1.0),
        vec2(-1.0,  3.0)
    );
    
    vec2 pos = positions[gl_VertexIndex];
    vec4 clip_pos = vec4(pos, 1.0, 1.0);

    vec4 world_pos = uniforms.inv_vp * clip_pos;
    v_world_dir = normalize(world_pos.xyz);

    gl_Position = vec4(pos.x, pos.y, 1.0, 1.0);
}



