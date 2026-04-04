/// Recast/Detour C bridge for Guava Engine.
/// Wraps the Recast navmesh building and Detour pathfinding/crowd APIs
/// behind a plain-C interface that Zig can call directly.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Opaque handles
// ---------------------------------------------------------------------------

typedef struct GuavaNavMesh GuavaNavMesh;
typedef struct GuavaCrowd GuavaCrowd;

// ---------------------------------------------------------------------------
// Build parameters
// ---------------------------------------------------------------------------

typedef struct GuavaNavMeshParams {
    float cell_size;        // Rasterization cell size (XZ)     [0.3]
    float cell_height;      // Rasterization cell height (Y)    [0.2]
    float agent_height;     // Agent height                     [2.0]
    float agent_radius;     // Agent radius                     [0.6]
    float agent_max_climb;  // Max step height                  [0.9]
    float agent_max_slope;  // Max walkable slope (degrees)     [45]
    float region_min_size;  // Min region area (cells²)         [8]
    float region_merge_size;// Region merge threshold (cells²)  [20]
    float edge_max_len;     // Max edge length                  [12]
    float edge_max_error;   // Max edge simplification error    [1.3]
    int   verts_per_poly;   // Max verts per polygon (≤6)       [6]
    float detail_sample_dist;   // Detail mesh sample distance  [6]
    float detail_sample_max_error; // Detail mesh max error     [1]
} GuavaNavMeshParams;

// ---------------------------------------------------------------------------
// NavMesh building
// ---------------------------------------------------------------------------

/// Build a navmesh from triangle soup.
/// @param verts  Packed xyz float array [nverts * 3].
/// @param nverts Number of vertices.
/// @param tris   Triangle indices [ntris * 3].
/// @param ntris  Number of triangles.
/// @param params Build parameters.
/// @return Opaque navmesh handle, or NULL on failure.
GuavaNavMesh* guava_nav_build(
    const float* verts, int nverts,
    const int* tris, int ntris,
    const GuavaNavMeshParams* params);

/// Destroy a navmesh.
void guava_nav_destroy(GuavaNavMesh* nav);

// ---------------------------------------------------------------------------
// Pathfinding queries
// ---------------------------------------------------------------------------

/// Find a path from start to end.
/// @param nav      Navmesh handle.
/// @param start    Start position [3].
/// @param end      End position [3].
/// @param half_ext Search half-extents for nearest poly lookup [3].
/// @param out_path Output buffer for path waypoints [max_path * 3].
/// @param max_path Maximum number of waypoints.
/// @return Number of waypoints written, or 0 on failure.
int guava_nav_find_path(
    const GuavaNavMesh* nav,
    const float start[3], const float end[3],
    const float half_ext[3],
    float* out_path, int max_path);

/// Find the nearest point on the navmesh.
/// @param nav      Navmesh handle.
/// @param pos      Query position [3].
/// @param half_ext Search half-extents [3].
/// @param out_pos  Nearest position [3].
/// @return 1 on success, 0 on failure.
int guava_nav_nearest_point(
    const GuavaNavMesh* nav,
    const float pos[3], const float half_ext[3],
    float* out_pos);

/// Raycast on the navmesh (movement along surface).
/// @param nav      Navmesh handle.
/// @param start    Start position [3].
/// @param end      End position [3].
/// @param half_ext Search half-extents [3].
/// @param out_hit  Hit position [3].
/// @return 1 if the ray hit a boundary before reaching end, 0 if reached end.
int guava_nav_raycast(
    const GuavaNavMesh* nav,
    const float start[3], const float end[3],
    const float half_ext[3],
    float* out_hit);

// ---------------------------------------------------------------------------
// Debug / visualisation
// ---------------------------------------------------------------------------

/// Get navmesh triangles for debug rendering.
/// @param nav           Navmesh handle.
/// @param out_verts     Output vertex buffer (xyz float array).
/// @param out_nverts    Output vertex count.
/// @param out_tris      Output index buffer.
/// @param out_ntris     Output triangle count.
/// Caller must free buffers with guava_nav_free_debug_mesh().
void guava_nav_get_debug_mesh(
    const GuavaNavMesh* nav,
    float** out_verts, int* out_nverts,
    int** out_tris, int* out_ntris);

/// Free debug mesh buffers.
void guava_nav_free_debug_mesh(float* verts, int* tris);

// ---------------------------------------------------------------------------
// Crowd simulation (agent avoidance)
// ---------------------------------------------------------------------------

/// Create a crowd simulation attached to the given navmesh.
/// @param nav        Navmesh handle.
/// @param max_agents Maximum number of agents.
/// @param agent_radius Default agent radius.
/// @return Opaque crowd handle.
GuavaCrowd* guava_crowd_create(const GuavaNavMesh* nav, int max_agents, float agent_radius);

/// Destroy a crowd.
void guava_crowd_destroy(GuavaCrowd* crowd);

/// Add an agent to the crowd at the given position.
/// @return Agent index (≥0) or -1 on failure.
int guava_crowd_add_agent(GuavaCrowd* crowd, const float pos[3],
                          float radius, float height,
                          float max_accel, float max_speed);

/// Remove an agent.
void guava_crowd_remove_agent(GuavaCrowd* crowd, int idx);

/// Set agent move target.
void guava_crowd_set_target(GuavaCrowd* crowd, int idx, const float target[3]);

/// Get agent position.  Writes to out_pos[3].
void guava_crowd_get_agent_pos(const GuavaCrowd* crowd, int idx, float* out_pos);

/// Get agent velocity.  Writes to out_vel[3].
void guava_crowd_get_agent_vel(const GuavaCrowd* crowd, int idx, float* out_vel);

/// Is the agent active?
int guava_crowd_agent_active(const GuavaCrowd* crowd, int idx);

/// Step the crowd simulation.
void guava_crowd_update(GuavaCrowd* crowd, float dt);

#ifdef __cplusplus
}
#endif
