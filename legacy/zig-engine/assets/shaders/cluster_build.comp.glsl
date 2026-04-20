#version 450
// ─── Clustered Forward+ — Phase 1: Build Cluster AABBs ───────────────────────
// Dispatched once per frame when projection changes.
// One thread per cluster: computes the view-space AABB for each frustum cluster.
//
// Grid: CLUSTER_X × CLUSTER_Y × CLUSTER_Z = 16 × 9 × 24 = 3456 clusters.
// Z slices use exponential (log) distribution: dense near camera, sparse far.
//
// Output: cluster_aabbs[cluster_id] = { vec4 min_pt, vec4 max_pt } (view space)

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

#define CLUSTER_X 16
#define CLUSTER_Y 9
#define CLUSTER_Z 24
#define TOTAL_CLUSTERS (CLUSTER_X * CLUSTER_Y * CLUSTER_Z)   // 3456

struct ClusterAABB {
    vec4 min_pt; // xyz = view-space min, w = padding
    vec4 max_pt; // xyz = view-space max, w = padding
};

layout(set = 0, binding = 0, std430) writeonly buffer ClusterAABBBuffer {
    ClusterAABB cluster_aabbs[];
};

layout(set = 1, binding = 0, std140) uniform BuildUniforms {
    mat4 u_inv_projection;
    float u_near;
    float u_far;
    float u_viewport_w;
    float u_viewport_h;
} u;

// Unproject a screen UV point [0,1]^2 at a given view-space depth (negative Z)
// to view-space coordinates.
vec3 screenToView(vec2 screen_uv, float view_z) {
    vec2 ndc = screen_uv * 2.0 - 1.0;
    vec4 clip = vec4(ndc, -1.0, 1.0);
    vec4 view = u.u_inv_projection * clip;
    view /= view.w;
    // Rescale from the reference plane to the target depth.
    view.xy *= (-view_z) / (-view.z);
    view.z = view_z;
    return view.xyz;
}

void main() {
    uint cluster_id = gl_GlobalInvocationID.x;
    if (cluster_id >= uint(TOTAL_CLUSTERS)) return;

    uint cx = cluster_id % uint(CLUSTER_X);
    uint cy = (cluster_id / uint(CLUSTER_X)) % uint(CLUSTER_Y);
    uint cz = cluster_id / uint(CLUSTER_X * CLUSTER_Y);

    // Exponential depth slicing: equal-area in log space.
    float ratio = u.u_far / u.u_near;
    float z_near_slice = -u.u_near * pow(ratio, float(cz)       / float(CLUSTER_Z));
    float z_far_slice  = -u.u_near * pow(ratio, float(cz + 1u)  / float(CLUSTER_Z));

    // Screen UV tile corners for this cluster's XY cell.
    vec2 uv_min = vec2(float(cx),      float(cy))      / vec2(float(CLUSTER_X), float(CLUSTER_Y));
    vec2 uv_max = vec2(float(cx + 1u), float(cy + 1u)) / vec2(float(CLUSTER_X), float(CLUSTER_Y));

    // Reconstruct 8 view-space corners.
    vec3 c[8];
    c[0] = screenToView(vec2(uv_min.x, uv_min.y), z_near_slice);
    c[1] = screenToView(vec2(uv_max.x, uv_min.y), z_near_slice);
    c[2] = screenToView(vec2(uv_min.x, uv_max.y), z_near_slice);
    c[3] = screenToView(vec2(uv_max.x, uv_max.y), z_near_slice);
    c[4] = screenToView(vec2(uv_min.x, uv_min.y), z_far_slice);
    c[5] = screenToView(vec2(uv_max.x, uv_min.y), z_far_slice);
    c[6] = screenToView(vec2(uv_min.x, uv_max.y), z_far_slice);
    c[7] = screenToView(vec2(uv_max.x, uv_max.y), z_far_slice);

    vec3 aabb_min = c[0];
    vec3 aabb_max = c[0];
    for (int i = 1; i < 8; ++i) {
        aabb_min = min(aabb_min, c[i]);
        aabb_max = max(aabb_max, c[i]);
    }

    cluster_aabbs[cluster_id].min_pt = vec4(aabb_min, 0.0);
    cluster_aabbs[cluster_id].max_pt = vec4(aabb_max, 0.0);
}
