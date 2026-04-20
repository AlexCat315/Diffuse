#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

// 可见性纹理 (R8: 0=未探索, 0.5=已探索, 1.0=可见)
layout(set = 2, binding = 0) uniform sampler2D u_fog_map;

// Uniforms (std140)
layout(set = 3, binding = 0, std140) uniform FogParams {
    vec4  u_unexplored_color;  // 未探索颜色+alpha
    vec4  u_explored_color;    // 已探索颜色+alpha
    vec4  u_grid_world_params; // (origin_x, origin_z, 1/total_w, 1/total_h)
    mat4  u_inv_view_projection;
};

void main() {
    // 将屏幕 UV 转换为 NDC 空间 clip 坐标
    vec2 ndc = v_uv * 2.0 - 1.0;
    // 重建世界空间位置（假设地面 Y=0 平面）
    // 取 near plane 和 far plane 两点
    vec4 world_near = u_inv_view_projection * vec4(ndc.x, -ndc.y, 0.0, 1.0);
    vec4 world_far  = u_inv_view_projection * vec4(ndc.x, -ndc.y, 1.0, 1.0);
    world_near /= world_near.w;
    world_far  /= world_far.w;

    // 射线与 Y=0 平面求交
    vec3 ray_origin = world_near.xyz;
    vec3 ray_dir = world_far.xyz - world_near.xyz;

    float t = -ray_origin.y / ray_dir.y;

    // 如果射线不与地面相交（向上看），保持全透明
    if (t < 0.0 || ray_dir.y == 0.0) {
        out_color = vec4(0.0);
        return;
    }

    vec3 world_pos = ray_origin + ray_dir * t;

    // 世界坐标 → 迷雾网格 UV
    float fog_u = (world_pos.x - u_grid_world_params.x) * u_grid_world_params.z;
    float fog_v = (world_pos.z - u_grid_world_params.y) * u_grid_world_params.w;

    // 超出网格范围的部分视为未探索
    if (fog_u < 0.0 || fog_u > 1.0 || fog_v < 0.0 || fog_v > 1.0) {
        out_color = u_unexplored_color;
        return;
    }

    float visibility = texture(u_fog_map, vec2(fog_u, fog_v)).r;

    // visibility: 0.0=未探索, ~0.5=已探索, 1.0=可见
    if (visibility > 0.9) {
        // 当前可见 → 完全透明
        out_color = vec4(0.0);
    } else if (visibility > 0.3) {
        // 已探索但不可见 → 半透明迷雾
        out_color = u_explored_color;
    } else {
        // 从未探索 → 黑雾
        out_color = u_unexplored_color;
    }
}
