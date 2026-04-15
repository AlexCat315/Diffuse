//! Navigation system — Zig wrapper around the Recast/Detour C bridge.
//!
//! Provides NavMesh building from triangle soup, pathfinding queries,
//! crowd simulation for agent avoidance, and debug mesh extraction for
//! visualisation.
//!
//! ## Usage
//! ```zig
//! // Build navmesh from scene geometry:
//! var nav = try Navigation.build(verts, tris, .{});
//! defer nav.deinit();
//!
//! // Query a path:
//! var path_buf: [64][3]f32 = undefined;
//! const n = nav.findPath(start, end, &path_buf);
//!
//! // Crowd:
//! var crowd = try nav.createCrowd(32);
//! defer crowd.deinit();
//! const agent = try crowd.addAgent(pos, .{});
//! crowd.setTarget(agent, target_pos);
//! crowd.update(delta_seconds);
//! const p = crowd.getAgentPos(agent);
//! ```

const std = @import("std");
const c = @import("c_recast");

// ---------------------------------------------------------------------------
// NavMesh build parameters
// ---------------------------------------------------------------------------

pub const NavMeshParams = struct {
    cell_size: f32 = 0.3,
    cell_height: f32 = 0.2,
    agent_height: f32 = 2.0,
    agent_radius: f32 = 0.6,
    agent_max_climb: f32 = 0.9,
    agent_max_slope: f32 = 45.0,
    region_min_size: f32 = 8.0,
    region_merge_size: f32 = 20.0,
    edge_max_len: f32 = 12.0,
    edge_max_error: f32 = 1.3,
    verts_per_poly: i32 = 6,
    detail_sample_dist: f32 = 6.0,
    detail_sample_max_error: f32 = 1.0,

    fn toC(self: NavMeshParams) c.GuavaNavMeshParams {
        return .{
            .cell_size = self.cell_size,
            .cell_height = self.cell_height,
            .agent_height = self.agent_height,
            .agent_radius = self.agent_radius,
            .agent_max_climb = self.agent_max_climb,
            .agent_max_slope = self.agent_max_slope,
            .region_min_size = self.region_min_size,
            .region_merge_size = self.region_merge_size,
            .edge_max_len = self.edge_max_len,
            .edge_max_error = self.edge_max_error,
            .verts_per_poly = self.verts_per_poly,
            .detail_sample_dist = self.detail_sample_dist,
            .detail_sample_max_error = self.detail_sample_max_error,
        };
    }
};

// ---------------------------------------------------------------------------
// NavMesh
// ---------------------------------------------------------------------------

pub const NavMesh = struct {
    handle: *c.GuavaNavMesh,

    /// Build a navmesh from packed triangle-soup geometry.
    ///
    /// - `verts`: packed xyz float array, length = num_verts * 3
    /// - `tris`: triangle index array, length = num_tris * 3
    pub fn build(
        verts: []const f32,
        tris: []const i32,
        params: NavMeshParams,
    ) !NavMesh {
        const nverts: c_int = @intCast(@divExact(verts.len, 3));
        const ntris: c_int = @intCast(@divExact(tris.len, 3));
        var cp = params.toC();
        const handle = c.guava_nav_build(
            verts.ptr,
            nverts,
            tris.ptr,
            ntris,
            &cp,
        );
        if (handle == null) return error.NavMeshBuildFailed;
        return .{ .handle = handle.? };
    }

    pub fn deinit(self: *NavMesh) void {
        c.guava_nav_destroy(self.handle);
        self.* = undefined;
    }

    // -- Pathfinding -------------------------------------------------------

    /// Find a straight-line path.  Returns number of waypoints written.
    pub fn findPath(
        self: *const NavMesh,
        start: [3]f32,
        end: [3]f32,
        out_path: [][3]f32,
    ) u32 {
        const half_ext = [3]f32{ 2.0, 4.0, 2.0 };
        return self.findPathExt(start, end, half_ext, out_path);
    }

    pub fn findPathExt(
        self: *const NavMesh,
        start: [3]f32,
        end: [3]f32,
        half_ext: [3]f32,
        out_path: [][3]f32,
    ) u32 {
        var s = start;
        var e = end;
        var he = half_ext;
        const n = c.guava_nav_find_path(
            self.handle,
            &s,
            &e,
            &he,
            @ptrCast(out_path.ptr),
            @intCast(out_path.len),
        );
        return if (n > 0) @intCast(n) else 0;
    }

    /// Find the nearest point on the navmesh surface.
    pub fn nearestPoint(self: *const NavMesh, pos: [3]f32) ?[3]f32 {
        const half_ext = [3]f32{ 2.0, 4.0, 2.0 };
        var p = pos;
        var he = half_ext;
        var out: [3]f32 = undefined;
        if (c.guava_nav_nearest_point(self.handle, &p, &he, &out) != 0) {
            return out;
        }
        return null;
    }

    /// Raycast along the navmesh surface.  Returns the hit point if the
    /// ray hit a navmesh boundary before reaching `end`, or null if it
    /// reached `end` unobstructed.
    pub fn raycast(self: *const NavMesh, start: [3]f32, end: [3]f32) ?[3]f32 {
        const half_ext = [3]f32{ 2.0, 4.0, 2.0 };
        var s = start;
        var e = end;
        var he = half_ext;
        var hit: [3]f32 = undefined;
        if (c.guava_nav_raycast(self.handle, &s, &e, &he, &hit) != 0) {
            return hit;
        }
        return null;
    }

    // -- Debug mesh --------------------------------------------------------

    pub const DebugMesh = struct {
        verts: []const f32, // packed xyz
        tris: []const i32,

        pub fn vertCount(self: DebugMesh) usize {
            return self.verts.len / 3;
        }
        pub fn triCount(self: DebugMesh) usize {
            return self.tris.len / 3;
        }
        pub fn free(self: *DebugMesh) void {
            if (self.verts.len > 0) {
                c.guava_nav_free_debug_mesh(
                    @ptrCast(@constCast(self.verts.ptr)),
                    @ptrCast(@constCast(self.tris.ptr)),
                );
            }
            self.* = undefined;
        }
    };

    /// Extract navmesh triangles for debug overlay rendering.
    pub fn getDebugMesh(self: *const NavMesh) ?DebugMesh {
        var v_ptr: [*c]f32 = null;
        var t_ptr: [*c]c_int = null;
        var nv: c_int = 0;
        var nt: c_int = 0;
        c.guava_nav_get_debug_mesh(self.handle, &v_ptr, &nv, &t_ptr, &nt);
        if (nv == 0 or v_ptr == null) return null;
        const nv_u: usize = @intCast(nv);
        const nt_u: usize = @intCast(nt);
        return .{
            .verts = @as([*]const f32, @ptrCast(v_ptr))[0 .. nv_u * 3],
            .tris = @as([*]const i32, @ptrCast(t_ptr))[0 .. nt_u * 3],
        };
    }

    // -- Crowd factory -----------------------------------------------------

    pub fn createCrowd(self: *const NavMesh, max_agents: u32) !Crowd {
        return Crowd.init(self, max_agents, 0.6);
    }

    pub fn createCrowdExt(self: *const NavMesh, max_agents: u32, agent_radius: f32) !Crowd {
        return Crowd.init(self, max_agents, agent_radius);
    }
};

// ---------------------------------------------------------------------------
// Crowd (agent avoidance)
// ---------------------------------------------------------------------------

pub const AgentParams = struct {
    radius: f32 = 0.6,
    height: f32 = 2.0,
    max_accel: f32 = 8.0,
    max_speed: f32 = 3.5,
};

pub const Crowd = struct {
    handle: *c.GuavaCrowd,

    fn init(nav: *const NavMesh, max_agents: u32, agent_radius: f32) !Crowd {
        const h = c.guava_crowd_create(nav.handle, @intCast(max_agents), agent_radius);
        if (h == null) return error.CrowdCreateFailed;
        return .{ .handle = h.? };
    }

    pub fn deinit(self: *Crowd) void {
        c.guava_crowd_destroy(self.handle);
        self.* = undefined;
    }

    pub fn addAgent(self: *Crowd, pos: [3]f32, params: AgentParams) !u32 {
        var p = pos;
        const idx = c.guava_crowd_add_agent(
            self.handle,
            &p,
            params.radius,
            params.height,
            params.max_accel,
            params.max_speed,
        );
        if (idx < 0) return error.AgentAddFailed;
        return @intCast(idx);
    }

    pub fn removeAgent(self: *Crowd, idx: u32) void {
        c.guava_crowd_remove_agent(self.handle, @intCast(idx));
    }

    pub fn setTarget(self: *Crowd, idx: u32, target: [3]f32) void {
        var t = target;
        c.guava_crowd_set_target(self.handle, @intCast(idx), &t);
    }

    pub fn getAgentPos(self: *const Crowd, idx: u32) [3]f32 {
        var pos: [3]f32 = .{ 0, 0, 0 };
        c.guava_crowd_get_agent_pos(self.handle, @intCast(idx), &pos);
        return pos;
    }

    pub fn getAgentVel(self: *const Crowd, idx: u32) [3]f32 {
        var vel: [3]f32 = .{ 0, 0, 0 };
        c.guava_crowd_get_agent_vel(self.handle, @intCast(idx), &vel);
        return vel;
    }

    pub fn isAgentActive(self: *const Crowd, idx: u32) bool {
        return c.guava_crowd_agent_active(self.handle, @intCast(idx)) != 0;
    }

    pub fn update(self: *Crowd, dt: f32) void {
        c.guava_crowd_update(self.handle, dt);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "NavMeshParams defaults" {
    const p = NavMeshParams{};
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), p.cell_size, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), p.agent_height, 0.001);
    try std.testing.expectEqual(@as(i32, 6), p.verts_per_poly);
}

test "NavMeshParams toC round-trip" {
    const p = NavMeshParams{ .cell_size = 0.5, .agent_height = 1.8 };
    const cp = p.toC();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cp.cell_size, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.8), cp.agent_height, 0.001);
}
