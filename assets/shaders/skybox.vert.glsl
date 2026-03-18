#version 450

layout(location = 0) out vec3 v_world_dir;

layout(set = 0, binding = 0, std140) uniform VertexUniforms {
    mat4 projection;
    mat4 view;
    vec4 camera_position;
    mat4 inv_vp; // Precomputed inverse of (projection * view_rot_only)
} uniforms;

void main() {
    // Generate a fullscreen triangle
    // Vertex indices: 0, 1, 2
    // Map to positions: (-1,-1), (3,-1), (-1,3)
    // This creates a triangle that covers the entire screen
    vec2 vertex_positions[3] = vec2[](
        vec2(-1.0, -1.0),
        vec2( 3.0, -1.0),
        vec2(-1.0,  3.0)
    );
    
    vec2 pos = vertex_positions[gl_VertexIndex];
    vec4 clip_pos = vec4(pos, 1.0, 1.0);

    // Use precomputed inverse view-projection matrix
    vec4 world_pos = uniforms.inv_vp * clip_pos;
    v_world_dir = normalize(world_pos.xyz);

    // Output standard position
    gl_Position = clip_pos;
    // Flip Y for Vulkan/SDL_GPU typical clip space vs texture coordinates
    gl_Position.y = -gl_Position.y;
}
