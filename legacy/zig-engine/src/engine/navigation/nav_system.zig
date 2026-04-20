//! Navigation system — manages NavMesh state and per-frame crowd updates.
//!
//! Integrates with the World ECS: entities with a `NavAgent` component are
//! automatically registered with the crowd simulation and their positions
//! are written back every tick.

const std = @import("std");
const nav_mod = @import("navigation.zig");
const components = @import("../scene/components.zig");
const world_mod = @import("../scene/world.zig");
const World = world_mod.World;
const EntityId = world_mod.EntityId;

pub const NavMesh = nav_mod.NavMesh;
pub const NavMeshParams = nav_mod.NavMeshParams;
pub const Crowd = nav_mod.Crowd;
pub const AgentParams = nav_mod.AgentParams;

/// Per-entity crowd agent mapping.
const AgentMapping = struct {
    entity_id: EntityId,
    crowd_idx: u32,
};

pub const NavSystem = struct {
    allocator: std.mem.Allocator,
    /// Currently baked navmesh (null if none).
    navmesh: ?NavMesh = null,
    /// Active crowd simulation (null if no navmesh).
    crowd: ?Crowd = null,
    /// Map of entity_id → crowd agent index.
    agent_map: std.ArrayListUnmanaged(AgentMapping) = .empty,
    /// Whether to draw the debug navmesh overlay.
    debug_draw_enabled: bool = false,
    /// Cached debug mesh for rendering.
    debug_mesh: ?NavMesh.DebugMesh = null,

    pub fn init(allocator: std.mem.Allocator) NavSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NavSystem) void {
        self.clearCrowd();
        if (self.debug_mesh) |*dm| dm.free();
        if (self.navmesh) |*nm| nm.deinit();
        self.agent_map.deinit(self.allocator);
    }

    // -- NavMesh management -------------------------------------------------

    /// Bake a navmesh from packed triangle-soup geometry.
    pub fn bake(self: *NavSystem, verts: []const f32, tris: []const i32, params: NavMeshParams) !void {
        // Tear down old state.
        self.clearCrowd();
        if (self.debug_mesh) |*dm| {
            dm.free();
            self.debug_mesh = null;
        }
        if (self.navmesh) |*old| old.deinit();

        self.navmesh = try NavMesh.build(verts, tris, params);

        // Pre-cache debug mesh.
        self.debug_mesh = self.navmesh.?.getDebugMesh();

        // Create crowd with sensible defaults.
        self.crowd = try self.navmesh.?.createCrowdExt(128, params.agent_radius);
    }

    /// Bake a navmesh from the current world's static mesh geometry.
    pub fn bakeFromWorld(self: *NavSystem, world: *World, params: NavMeshParams) !void {
        const geom = try collectSceneGeometry(self.allocator, world);
        defer self.allocator.free(geom.verts);
        defer self.allocator.free(geom.tris);
        if (geom.verts.len == 0 or geom.tris.len == 0) return error.NoBakeGeometry;
        try self.bake(geom.verts, geom.tris, params);
    }

    pub fn hasNavMesh(self: *const NavSystem) bool {
        return self.navmesh != null;
    }

    pub fn setDebugDrawEnabled(self: *NavSystem, enabled: bool) void {
        self.debug_draw_enabled = enabled;
    }

    pub fn debugDrawEnabled(self: *const NavSystem) bool {
        return self.debug_draw_enabled;
    }

    pub fn debugMesh(self: *const NavSystem) ?NavMesh.DebugMesh {
        return self.debug_mesh;
    }

    // -- Crowd / agent management ------------------------------------------

    fn clearCrowd(self: *NavSystem) void {
        if (self.crowd) |*cr| cr.deinit();
        self.crowd = null;
        self.agent_map.clearRetainingCapacity();
    }

    /// Register an entity's NavAgent with the crowd.
    pub fn registerAgent(self: *NavSystem, entity_id: EntityId, pos: [3]f32, params: AgentParams) !u32 {
        var crowd = self.crowd orelse return error.NoCrowd;
        const idx = try crowd.addAgent(pos, params);
        try self.agent_map.append(self.allocator, .{ .entity_id = entity_id, .crowd_idx = idx });
        return idx;
    }

    /// Unregister an entity's NavAgent from the crowd.
    pub fn unregisterAgent(self: *NavSystem, entity_id: EntityId) void {
        var crowd = self.crowd orelse return;
        if (self.findAgentMappingIndex(entity_id)) |i| {
            crowd.removeAgent(self.agent_map.items[i].crowd_idx);
            _ = self.agent_map.swapRemove(i);
            return;
        }
    }

    /// Set the move target for an entity's agent.
    pub fn setAgentTarget(self: *NavSystem, entity_id: EntityId, target: [3]f32) void {
        var crowd = self.crowd orelse return;
        if (self.findAgentMappingIndex(entity_id)) |i| {
            crowd.setTarget(self.agent_map.items[i].crowd_idx, target);
            return;
        }
    }

    fn findAgentMappingIndex(self: *const NavSystem, entity_id: EntityId) ?usize {
        for (self.agent_map.items, 0..) |mapping, i| {
            if (mapping.entity_id == entity_id) return i;
        }
        return null;
    }

    // -- Pathfinding queries (convenience) ---------------------------------

    pub fn findPath(self: *const NavSystem, start: [3]f32, end: [3]f32, out_path: [][3]f32) u32 {
        const nm = self.navmesh orelse return 0;
        return nm.findPath(start, end, out_path);
    }

    pub fn nearestPoint(self: *const NavSystem, pos: [3]f32) ?[3]f32 {
        const nm = self.navmesh orelse return null;
        return nm.nearestPoint(pos);
    }

    // -- Per-frame update ---------------------------------------------------

    /// Advance the crowd and write agent positions back to entities.
    pub fn update(self: *NavSystem, world: *World, dt: f32) void {
        var crowd = self.crowd orelse return;

        // 1) Auto-register/unregister entities with NavAgent components.
        for (world.entities.items) |*entity| {
            if (entity.nav_agent) |*agent| {
                if (!agent._registered) {
                    const params = AgentParams{
                        .radius = agent.radius,
                        .height = agent.height,
                        .max_accel = agent.max_acceleration,
                        .max_speed = agent.max_speed,
                    };
                    const idx = self.registerAgent(entity.id, entity.local_transform.translation, params) catch continue;
                    agent._crowd_idx = idx;
                    agent._registered = true;
                }

                if (agent.target) |target| {
                    self.setAgentTarget(entity.id, target);
                }
            } else if (self.findAgentMappingIndex(entity.id) != null) {
                // Component removed at runtime: remove from crowd.
                self.unregisterAgent(entity.id);
            }
        }

        // Remove stale mappings for deleted entities.
        var i: usize = 0;
        while (i < self.agent_map.items.len) {
            const mapping = self.agent_map.items[i];
            if (!world.hasEntity(mapping.entity_id)) {
                crowd.removeAgent(mapping.crowd_idx);
                _ = self.agent_map.swapRemove(i);
                continue;
            }
            i += 1;
        }

        // Step crowd simulation.
        crowd.update(dt);

        // Sync crowd agent positions → entity transforms.
        for (self.agent_map.items) |mapping| {
            const entity = world.getEntity(mapping.entity_id) orelse continue;
            const pos = crowd.getAgentPos(mapping.crowd_idx);
            entity.local_transform.translation = pos;
            entity.dirty = true;
        }
    }

    // -- Bake helpers -------------------------------------------------------

    /// Collect all static mesh geometry from the world into packed arrays
    /// suitable for navmesh building.  Returns owned slices that the caller
    /// must free.
    pub fn collectSceneGeometry(
        allocator: std.mem.Allocator,
        world: *const World,
    ) !struct { verts: []f32, tris: []i32 } {
        var verts: std.ArrayListUnmanaged(f32) = .empty;
        var tris: std.ArrayListUnmanaged(i32) = .empty;
        errdefer {
            verts.deinit(allocator);
            tris.deinit(allocator);
        }

        var base_idx: i32 = 0;
        for (world.entities.items) |*entity| {
            // Only include static entities (no rigidbody or kinematic/static ones).
            if (entity.rigidbody) |rb| {
                if (rb.motion_type == .dynamic) continue;
            }
            // Must have a mesh resource handle.
            const mesh_comp = entity.mesh orelse continue;
            const mesh_handle = mesh_comp.handle orelse continue;
            const mesh_res = world.resources.mesh(mesh_handle) orelse continue;

            // Transform vertices by the entity's world matrix.
            const mat = entity.world_matrix_cache;
            for (mesh_res.vertices) |v| {
                const x = v.position[0];
                const y = v.position[1];
                const z = v.position[2];
                // Column-major 4x4 matrix multiply (position only).
                const wx = mat[0] * x + mat[4] * y + mat[8] * z + mat[12];
                const wy = mat[1] * x + mat[5] * y + mat[9] * z + mat[13];
                const wz = mat[2] * x + mat[6] * y + mat[10] * z + mat[14];
                try verts.append(allocator, wx);
                try verts.append(allocator, wy);
                try verts.append(allocator, wz);
            }

            for (mesh_res.indices) |idx| {
                try tris.append(allocator, base_idx + @as(i32, @intCast(idx)));
            }
            base_idx += @as(i32, @intCast(mesh_res.vertices.len));
        }

        return .{
            .verts = try verts.toOwnedSlice(allocator),
            .tris = try tris.toOwnedSlice(allocator),
        };
    }
};
