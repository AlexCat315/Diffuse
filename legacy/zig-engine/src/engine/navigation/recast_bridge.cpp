// Recast/Detour C++ bridge implementation for Guava Engine.
// Wraps Recast navmesh building, Detour pathfinding, and DetourCrowd
// behind the C API declared in recast_bridge.h.

#include "recast_bridge.h"

#include <Recast.h>
#include <DetourNavMesh.h>
#include <DetourNavMeshBuilder.h>
#include <DetourNavMeshQuery.h>
#include <DetourCommon.h>
#include <DetourCrowd.h>

#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <cmath>
#include <new>

// ---------------------------------------------------------------------------
// Internal structures
// ---------------------------------------------------------------------------

struct GuavaNavMesh {
    dtNavMesh*      nav_mesh  = nullptr;
    dtNavMeshQuery* nav_query = nullptr;

    ~GuavaNavMesh() {
        dtFreeNavMeshQuery(nav_query);
        dtFreeNavMesh(nav_mesh);
    }
};

struct GuavaCrowd {
    dtCrowd*           crowd    = nullptr;
    const GuavaNavMesh* nav_ref = nullptr;

    ~GuavaCrowd() {
        dtFreeCrowd(crowd);
    }
};

// ---------------------------------------------------------------------------
// NavMesh building
// ---------------------------------------------------------------------------

extern "C" GuavaNavMesh* guava_nav_build(
    const float* verts, int nverts,
    const int* tris, int ntris,
    const GuavaNavMeshParams* params)
{
    if (!verts || nverts <= 0 || !tris || ntris <= 0 || !params)
        return nullptr;

    // ── 1. Compute bounding box ──────────────────────────────────────────
    float bmin[3] = {  1e10f,  1e10f,  1e10f };
    float bmax[3] = { -1e10f, -1e10f, -1e10f };
    for (int i = 0; i < nverts; ++i) {
        const float* v = &verts[i * 3];
        for (int j = 0; j < 3; ++j) {
            if (v[j] < bmin[j]) bmin[j] = v[j];
            if (v[j] > bmax[j]) bmax[j] = v[j];
        }
    }

    // ── 2. Recast config ─────────────────────────────────────────────────
    rcConfig cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.cs  = params->cell_size;
    cfg.ch  = params->cell_height;
    cfg.walkableSlopeAngle   = params->agent_max_slope;
    cfg.walkableHeight       = (int)std::ceil(params->agent_height / cfg.ch);
    cfg.walkableClimb        = (int)std::floor(params->agent_max_climb / cfg.ch);
    cfg.walkableRadius       = (int)std::ceil(params->agent_radius / cfg.cs);
    cfg.maxEdgeLen           = (int)(params->edge_max_len / cfg.cs);
    cfg.maxSimplificationError = params->edge_max_error;
    cfg.minRegionArea        = (int)(params->region_min_size * params->region_min_size);
    cfg.mergeRegionArea      = (int)(params->region_merge_size * params->region_merge_size);
    cfg.maxVertsPerPoly      = params->verts_per_poly;
    cfg.detailSampleDist     = params->detail_sample_dist < 0.9f ? 0.0f : cfg.cs * params->detail_sample_dist;
    cfg.detailSampleMaxError = cfg.ch * params->detail_sample_max_error;
    rcVcopy(cfg.bmin, bmin);
    rcVcopy(cfg.bmax, bmax);
    rcCalcGridSize(cfg.bmin, cfg.bmax, cfg.cs, &cfg.width, &cfg.height);

    // ── 3. Rasterize ─────────────────────────────────────────────────────
    rcContext ctx;

    rcHeightfield* hf = rcAllocHeightfield();
    if (!hf || !rcCreateHeightfield(&ctx, *hf, cfg.width, cfg.height,
                                    cfg.bmin, cfg.bmax, cfg.cs, cfg.ch))
    {
        rcFreeHeightField(hf);
        return nullptr;
    }

    // Mark walkable triangles.
    auto* tri_areas = new (std::nothrow) unsigned char[ntris];
    if (!tri_areas) { rcFreeHeightField(hf); return nullptr; }
    std::memset(tri_areas, 0, ntris);
    rcMarkWalkableTriangles(&ctx, cfg.walkableSlopeAngle,
                            verts, nverts, tris, ntris, tri_areas);
    if (!rcRasterizeTriangles(&ctx, verts, nverts,
                              tris, tri_areas, ntris, *hf, cfg.walkableClimb))
    {
        delete[] tri_areas;
        rcFreeHeightField(hf);
        return nullptr;
    }
    delete[] tri_areas;

    // ── 4. Filter ────────────────────────────────────────────────────────
    rcFilterLowHangingWalkableObstacles(&ctx, cfg.walkableClimb, *hf);
    rcFilterLedgeSpans(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf);
    rcFilterWalkableLowHeightSpans(&ctx, cfg.walkableHeight, *hf);

    // ── 5. Compact heightfield ───────────────────────────────────────────
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    if (!chf || !rcBuildCompactHeightfield(&ctx, cfg.walkableHeight, cfg.walkableClimb, *hf, *chf)) {
        rcFreeCompactHeightfield(chf);
        rcFreeHeightField(hf);
        return nullptr;
    }
    rcFreeHeightField(hf);

    if (!rcErodeWalkableArea(&ctx, cfg.walkableRadius, *chf)) {
        rcFreeCompactHeightfield(chf);
        return nullptr;
    }

    // ── 6. Regions ───────────────────────────────────────────────────────
    if (!rcBuildDistanceField(&ctx, *chf) ||
        !rcBuildRegions(&ctx, *chf, 0, cfg.minRegionArea, cfg.mergeRegionArea))
    {
        rcFreeCompactHeightfield(chf);
        return nullptr;
    }

    // ── 7. Contours ──────────────────────────────────────────────────────
    rcContourSet* cset = rcAllocContourSet();
    if (!cset || !rcBuildContours(&ctx, *chf, cfg.maxSimplificationError, cfg.maxEdgeLen, *cset)) {
        rcFreeContourSet(cset);
        rcFreeCompactHeightfield(chf);
        return nullptr;
    }

    // ── 8. Poly mesh ─────────────────────────────────────────────────────
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    if (!pmesh || !rcBuildPolyMesh(&ctx, *cset, cfg.maxVertsPerPoly, *pmesh)) {
        rcFreePolyMesh(pmesh);
        rcFreeContourSet(cset);
        rcFreeCompactHeightfield(chf);
        return nullptr;
    }

    // ── 9. Detail mesh ───────────────────────────────────────────────────
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    if (!dmesh || !rcBuildPolyMeshDetail(&ctx, *pmesh, *chf,
                                         cfg.detailSampleDist,
                                         cfg.detailSampleMaxError, *dmesh))
    {
        rcFreePolyMeshDetail(dmesh);
        rcFreePolyMesh(pmesh);
        rcFreeContourSet(cset);
        rcFreeCompactHeightfield(chf);
        return nullptr;
    }
    rcFreeContourSet(cset);
    rcFreeCompactHeightfield(chf);

    // ── 10. Detour navmesh data ──────────────────────────────────────────
    // Set poly flags for Detour.
    for (int i = 0; i < pmesh->npolys; ++i) {
        pmesh->flags[i] = 1; // walkable
    }

    dtNavMeshCreateParams dtParams;
    std::memset(&dtParams, 0, sizeof(dtParams));
    dtParams.verts            = pmesh->verts;
    dtParams.vertCount        = pmesh->nverts;
    dtParams.polys            = pmesh->polys;
    dtParams.polyAreas        = pmesh->areas;
    dtParams.polyFlags        = pmesh->flags;
    dtParams.polyCount        = pmesh->npolys;
    dtParams.nvp              = pmesh->nvp;
    dtParams.detailMeshes     = dmesh->meshes;
    dtParams.detailVerts      = dmesh->verts;
    dtParams.detailVertsCount = dmesh->nverts;
    dtParams.detailTris       = dmesh->tris;
    dtParams.detailTriCount   = dmesh->ntris;
    dtParams.walkableHeight   = params->agent_height;
    dtParams.walkableRadius   = params->agent_radius;
    dtParams.walkableClimb    = params->agent_max_climb;
    rcVcopy(dtParams.bmin, pmesh->bmin);
    rcVcopy(dtParams.bmax, pmesh->bmax);
    dtParams.cs = cfg.cs;
    dtParams.ch = cfg.ch;
    dtParams.buildBvTree = true;

    unsigned char* navData = nullptr;
    int navDataSize = 0;
    if (!dtCreateNavMeshData(&dtParams, &navData, &navDataSize)) {
        rcFreePolyMeshDetail(dmesh);
        rcFreePolyMesh(pmesh);
        return nullptr;
    }
    rcFreePolyMeshDetail(dmesh);
    rcFreePolyMesh(pmesh);

    // ── 11. Create Detour navmesh + query ────────────────────────────────
    auto* result = new (std::nothrow) GuavaNavMesh();
    if (!result) {
        dtFree(navData);
        return nullptr;
    }

    result->nav_mesh = dtAllocNavMesh();
    if (!result->nav_mesh ||
        dtStatusFailed(result->nav_mesh->init(navData, navDataSize, DT_TILE_FREE_DATA)))
    {
        dtFree(navData);
        delete result;
        return nullptr;
    }

    result->nav_query = dtAllocNavMeshQuery();
    if (!result->nav_query ||
        dtStatusFailed(result->nav_query->init(result->nav_mesh, 2048)))
    {
        delete result;
        return nullptr;
    }

    return result;
}

extern "C" void guava_nav_destroy(GuavaNavMesh* nav) {
    delete nav;
}

// ---------------------------------------------------------------------------
// Pathfinding
// ---------------------------------------------------------------------------

extern "C" int guava_nav_find_path(
    const GuavaNavMesh* nav,
    const float start[3], const float end[3],
    const float half_ext[3],
    float* out_path, int max_path)
{
    if (!nav || !nav->nav_query || max_path <= 0) return 0;

    dtQueryFilter filter;
    filter.setIncludeFlags(0xffff);
    filter.setExcludeFlags(0);

    dtPolyRef startRef = 0, endRef = 0;
    float startNearest[3], endNearest[3];

    nav->nav_query->findNearestPoly(start, half_ext, &filter, &startRef, startNearest);
    nav->nav_query->findNearestPoly(end,   half_ext, &filter, &endRef,   endNearest);
    if (startRef == 0 || endRef == 0) return 0;

    dtPolyRef polyPath[256];
    int npolys = 0;
    nav->nav_query->findPath(startRef, endRef, startNearest, endNearest,
                             &filter, polyPath, &npolys, 256);
    if (npolys == 0) return 0;

    // Straighten the path.
    float straightPath[256 * 3];
    unsigned char straightPathFlags[256];
    dtPolyRef straightPathPolys[256];
    int nstraight = 0;
    nav->nav_query->findStraightPath(startNearest, endNearest,
                                     polyPath, npolys,
                                     straightPath, straightPathFlags,
                                     straightPathPolys, &nstraight, 256, 0);

    int count = nstraight < max_path ? nstraight : max_path;
    std::memcpy(out_path, straightPath, count * 3 * sizeof(float));
    return count;
}

extern "C" int guava_nav_nearest_point(
    const GuavaNavMesh* nav,
    const float pos[3], const float half_ext[3],
    float* out_pos)
{
    if (!nav || !nav->nav_query) return 0;
    dtQueryFilter filter;
    filter.setIncludeFlags(0xffff);
    filter.setExcludeFlags(0);
    dtPolyRef ref = 0;
    dtStatus status = nav->nav_query->findNearestPoly(pos, half_ext, &filter, &ref, out_pos);
    return (dtStatusSucceed(status) && ref != 0) ? 1 : 0;
}

extern "C" int guava_nav_raycast(
    const GuavaNavMesh* nav,
    const float start[3], const float end[3],
    const float half_ext[3],
    float* out_hit)
{
    if (!nav || !nav->nav_query) return 0;
    dtQueryFilter filter;
    filter.setIncludeFlags(0xffff);
    filter.setExcludeFlags(0);

    dtPolyRef startRef = 0;
    float nearest[3];
    nav->nav_query->findNearestPoly(start, half_ext, &filter, &startRef, nearest);
    if (startRef == 0) return 0;

    float t = 0.0f;
    float hitNormal[3] = {0};
    dtPolyRef pathPolys[256];
    int npolys = 0;
    nav->nav_query->raycast(startRef, nearest, end, &filter, &t, hitNormal, pathPolys, &npolys, 256);

    // t = 1.0 means we reached the end without hitting a boundary.
    if (t >= 1.0f) {
        dtVcopy(out_hit, end);
        return 0; // No hit
    }

    // Lerp to hit position.
    dtVlerp(out_hit, nearest, end, t);
    return 1; // Hit
}

// ---------------------------------------------------------------------------
// Debug mesh
// ---------------------------------------------------------------------------

extern "C" void guava_nav_get_debug_mesh(
    const GuavaNavMesh* nav,
    float** out_verts, int* out_nverts,
    int** out_tris, int* out_ntris)
{
    *out_verts = nullptr;
    *out_nverts = 0;
    *out_tris = nullptr;
    *out_ntris = 0;

    if (!nav || !nav->nav_mesh) return;

    const dtNavMesh* mesh = nav->nav_mesh;

    // Count totals across all tiles.
    int total_verts = 0;
    int total_tris = 0;
    for (int i = 0; i < mesh->getMaxTiles(); ++i) {
        const dtMeshTile* tile = mesh->getTile(i);
        if (!tile || !tile->header) continue;
        total_verts += tile->header->vertCount;
        // Count triangles from detail meshes.
        for (int j = 0; j < tile->header->detailMeshCount; ++j) {
            total_tris += tile->detailMeshes[j].triCount;
        }
    }
    if (total_verts == 0) return;

    auto* v_buf = static_cast<float*>(std::malloc(total_verts * 3 * sizeof(float)));
    auto* t_buf = static_cast<int*>(std::malloc(total_tris * 3 * sizeof(int)));
    if (!v_buf || !t_buf) {
        std::free(v_buf);
        std::free(t_buf);
        return;
    }

    int v_off = 0, t_off = 0;
    for (int i = 0; i < mesh->getMaxTiles(); ++i) {
        const dtMeshTile* tile = mesh->getTile(i);
        if (!tile || !tile->header) continue;

        int base_vert = v_off / 3;
        std::memcpy(&v_buf[v_off], tile->verts,
                     tile->header->vertCount * 3 * sizeof(float));
        v_off += tile->header->vertCount * 3;

        for (int j = 0; j < tile->header->detailMeshCount; ++j) {
            const dtPolyDetail& pd = tile->detailMeshes[j];
            for (int k = 0; k < pd.triCount; ++k) {
                const unsigned char* t = &tile->detailTris[(pd.triBase + k) * 4];
                for (int m = 0; m < 3; ++m) {
                    if (t[m] < tile->header->polyCount) {
                        // Use polygon vertex.
                        const dtPoly& poly = tile->polys[j];
                        t_buf[t_off++] = base_vert + poly.verts[t[m]];
                    } else {
                        // Detail vertex — map into our buffer.
                        t_buf[t_off++] = base_vert + pd.vertBase + t[m] - tile->header->polyCount;
                    }
                }
            }
        }
    }

    *out_verts  = v_buf;
    *out_nverts = total_verts;
    *out_tris   = t_buf;
    *out_ntris  = t_off / 3;
}

extern "C" void guava_nav_free_debug_mesh(float* verts, int* tris) {
    std::free(verts);
    std::free(tris);
}

// ---------------------------------------------------------------------------
// Crowd simulation
// ---------------------------------------------------------------------------

extern "C" GuavaCrowd* guava_crowd_create(
    const GuavaNavMesh* nav, int max_agents, float agent_radius)
{
    if (!nav || !nav->nav_mesh || max_agents <= 0) return nullptr;

    auto* crowd = new (std::nothrow) GuavaCrowd();
    if (!crowd) return nullptr;

    crowd->crowd = dtAllocCrowd();
    if (!crowd->crowd) { delete crowd; return nullptr; }

    if (!crowd->crowd->init(max_agents, agent_radius, const_cast<dtNavMesh*>(nav->nav_mesh))) {
        delete crowd;
        return nullptr;
    }
    crowd->nav_ref = nav;
    return crowd;
}

extern "C" void guava_crowd_destroy(GuavaCrowd* crowd) {
    delete crowd;
}

extern "C" int guava_crowd_add_agent(
    GuavaCrowd* crowd, const float pos[3],
    float radius, float height,
    float max_accel, float max_speed)
{
    if (!crowd || !crowd->crowd) return -1;

    dtCrowdAgentParams ap;
    std::memset(&ap, 0, sizeof(ap));
    ap.radius                = radius;
    ap.height                = height;
    ap.maxAcceleration       = max_accel;
    ap.maxSpeed              = max_speed;
    ap.collisionQueryRange   = radius * 12.0f;
    ap.pathOptimizationRange = radius * 30.0f;
    ap.updateFlags           = DT_CROWD_ANTICIPATE_TURNS |
                               DT_CROWD_OPTIMIZE_VIS |
                               DT_CROWD_OPTIMIZE_TOPO |
                               DT_CROWD_OBSTACLE_AVOIDANCE |
                               DT_CROWD_SEPARATION;
    ap.obstacleAvoidanceType = 3; // high quality
    ap.separationWeight      = 2.0f;

    return crowd->crowd->addAgent(pos, &ap);
}

extern "C" void guava_crowd_remove_agent(GuavaCrowd* crowd, int idx) {
    if (crowd && crowd->crowd) crowd->crowd->removeAgent(idx);
}

extern "C" void guava_crowd_set_target(GuavaCrowd* crowd, int idx, const float target[3]) {
    if (!crowd || !crowd->crowd || !crowd->nav_ref || !crowd->nav_ref->nav_query)
        return;

    dtQueryFilter filter;
    filter.setIncludeFlags(0xffff);
    filter.setExcludeFlags(0);

    dtPolyRef polyRef = 0;
    float nearest[3];
    float ext[3] = { 2.0f, 4.0f, 2.0f };
    crowd->nav_ref->nav_query->findNearestPoly(target, ext, &filter, &polyRef, nearest);
    if (polyRef != 0) {
        crowd->crowd->requestMoveTarget(idx, polyRef, nearest);
    }
}

extern "C" void guava_crowd_get_agent_pos(const GuavaCrowd* crowd, int idx, float* out_pos) {
    if (!crowd || !crowd->crowd) return;
    const dtCrowdAgent* ag = crowd->crowd->getAgent(idx);
    if (ag && ag->active) {
        dtVcopy(out_pos, ag->npos);
    }
}

extern "C" void guava_crowd_get_agent_vel(const GuavaCrowd* crowd, int idx, float* out_vel) {
    if (!crowd || !crowd->crowd) return;
    const dtCrowdAgent* ag = crowd->crowd->getAgent(idx);
    if (ag && ag->active) {
        dtVcopy(out_vel, ag->vel);
    }
}

extern "C" int guava_crowd_agent_active(const GuavaCrowd* crowd, int idx) {
    if (!crowd || !crowd->crowd) return 0;
    const dtCrowdAgent* ag = crowd->crowd->getAgent(idx);
    return (ag && ag->active) ? 1 : 0;
}

extern "C" void guava_crowd_update(GuavaCrowd* crowd, float dt) {
    if (crowd && crowd->crowd)
        crowd->crowd->update(dt, nullptr);
}
