#version 450
// ─── Clustered Forward+ — Light Culling Compute Shader ───────────────────────
// One thread per cluster (3456 total = 16×9×24).
// Computes each cluster's view-space AABB on the fly (no pre-built AABB buffer),
// then sphere-tests every active point light against it.
// Writes per-cluster light counts + indices to R32UI storage images.
//
// Output (read by mesh.frag.glsl as usampler2D):
//   u_cluster_counts       — R32UI, width=3456, height=1
//   u_cluster_light_indices — R32UI, width=64, height=3456

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

#define CLUSTER_X  16
#define CLUSTER_Y   9
#define CLUSTER_Z  24
#define TOTAL_CLUSTERS      3456   // 16 × 9 × 24
#define MAX_POINT_LIGHTS    256
#define MAX_LIGHTS_PER_CLUSTER 64

// ── Output images (set=0) ────────────────────────────────────────────────────
// Binding 0: per-cluster light count (one uint per cluster)
layout(set = 0, binding = 0, r32ui) uniform writeonly uimage2D u_cluster_counts;

// Binding 1: per-cluster light indices (up to MAX_LIGHTS_PER_CLUSTER per cluster)
//   texel (x=slot, y=cluster_id) → light index
layout(set = 0, binding = 1, r32ui) uniform writeonly uimage2D u_cluster_light_indices;

// ── Per-frame UBO (set=1) ────────────────────────────────────────────────────
// All data the shader needs: matrices, camera params, and all active point lights.
// Placed in set=1 so no buffer-slot collision with the set=0 storage images.
struct GpuPointLight {
    vec4 position_range;   // xyz = world position, w = range
    vec4 color_intensity;  // rgb = color, w = intensity
};

layout(set = 1, binding = 0, std140) uniform ClusterCullUniforms {
    mat4  u_inv_projection; // clip → view transform (for AABB corners)
    mat4  u_view;           // world → view transform (for light positions)
    float u_near;           // camera near plane distance (positive)
    float u_far;            // camera far plane distance (positive)
    float u_viewport_w;     // viewport width  in pixels
    float u_viewport_h;     // viewport height in pixels
    uint  u_point_count;    // number of active point lights this frame
    uint  _pad0;
    uint  _pad1;
    uint  _pad2;
    GpuPointLight u_lights[MAX_POINT_LIGHTS];
} u;

// ── Helpers ──────────────────────────────────────────────────────────────────

// Unproject a screen-space UV point (in [0,1]²) at a given view-space depth
// (negative Z convention) to view-space coordinates.
vec3 screenToView(vec2 screen_uv, float view_z) {
    vec2 ndc   = screen_uv * 2.0 - 1.0;
    vec4 clip  = vec4(ndc, -1.0, 1.0);
    vec4 view  = u.u_inv_projection * clip;
    view /= view.w;
    // Rescale XY from the canonical near plane to the target depth.
    view.xy *= (-view_z) / (-view.z);
    view.z   = view_z;
    return view.xyz;
}

// Sphere vs. AABB overlap (all in view space).
bool sphereIntersectsAABB(vec3 center, float radius, vec3 aabb_min, vec3 aabb_max) {
    vec3 closest = clamp(center, aabb_min, aabb_max);
    vec3 delta   = center - closest;
    return dot(delta, delta) <= (radius * radius);
}

void main() {
    uint cluster_id = gl_GlobalInvocationID.x;
    if (cluster_id >= uint(TOTAL_CLUSTERS)) return;

    // Decompose cluster_id → (cx, cy, cz) tile indices.
    uint cx = cluster_id % uint(CLUSTER_X);
    uint cy = (cluster_id / uint(CLUSTER_X)) % uint(CLUSTER_Y);
    uint cz = cluster_id / uint(CLUSTER_X * CLUSTER_Y);

    // Exponential Z slicing: equal-area bands in log space.
    float ratio       = u.u_far / u.u_near;
    float z_near_sl   = -u.u_near * pow(ratio, float(cz)      / float(CLUSTER_Z));
    float z_far_sl    = -u.u_near * pow(ratio, float(cz + 1u) / float(CLUSTER_Z));

    // Screen UV tile corners for this XY cell.
    vec2 uv_min = vec2(float(cx),      float(cy))      / vec2(float(CLUSTER_X), float(CLUSTER_Y));
    vec2 uv_max = vec2(float(cx + 1u), float(cy + 1u)) / vec2(float(CLUSTER_X), float(CLUSTER_Y));

    // 8 view-space AABB corners.
    vec3 c[8];
    c[0] = screenToView(vec2(uv_min.x, uv_min.y), z_near_sl);
    c[1] = screenToView(vec2(uv_max.x, uv_min.y), z_near_sl);
    c[2] = screenToView(vec2(uv_min.x, uv_max.y), z_near_sl);
    c[3] = screenToView(vec2(uv_max.x, uv_max.y), z_near_sl);
    c[4] = screenToView(vec2(uv_min.x, uv_min.y), z_far_sl);
    c[5] = screenToView(vec2(uv_max.x, uv_min.y), z_far_sl);
    c[6] = screenToView(vec2(uv_min.x, uv_max.y), z_far_sl);
    c[7] = screenToView(vec2(uv_max.x, uv_max.y), z_far_sl);

    vec3 aabb_min = c[0];
    vec3 aabb_max = c[0];
    for (int k = 1; k < 8; ++k) {
        aabb_min = min(aabb_min, c[k]);
        aabb_max = max(aabb_max, c[k]);
    }

    // Cull point lights against this cluster's AABB.
    uint count = 0u;
    for (uint i = 0u; i < u.u_point_count && count < uint(MAX_LIGHTS_PER_CLUSTER); ++i) {
        vec3  world_pos = u.u_lights[i].position_range.xyz;
        float range     = u.u_lights[i].position_range.w;
        // Transform light position to view space.
        vec3 view_pos = (u.u_view * vec4(world_pos, 1.0)).xyz;

        if (sphereIntersectsAABB(view_pos, range, aabb_min, aabb_max)) {
            imageStore(u_cluster_light_indices,
                       ivec2(int(count), int(cluster_id)),
                       uvec4(i, 0u, 0u, 0u));
            count++;
        }
    }

    // Write the final count for this cluster.
    imageStore(u_cluster_counts, ivec2(int(cluster_id), 0), uvec4(count, 0u, 0u, 0u));
}
