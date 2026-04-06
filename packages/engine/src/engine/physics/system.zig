const std = @import("std");
const AABB = @import("../math/aabb.zig").AABB;
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");
const vec3 = @import("../math/vec3.zig");

// 从 scene 模块导入 EntityId
const EntityId = scene_mod.EntityId;

const physics_log = std.log.scoped(.physics);
const epsilon: f32 = 0.0001;

pub const TriggerEvent = struct {
    entity_a: EntityId,
    entity_b: EntityId,
    kind: TriggerEventKind,
};

pub const TriggerEventKind = enum(u8) {
    enter,
    stay,
    exit,
};

pub const CollisionEvent = struct {
    entity_a: EntityId,
    entity_b: EntityId,
    kind: CollisionEventKind,
};

pub const CollisionEventKind = enum(u8) {
    enter,
    exit,
};

pub const DebugShape = union(enum) {
    box: DebugBox,
    sphere: DebugSphere,
};

pub const DebugBox = struct {
    center: components.Vec3,
    half_extents: components.Vec3,
};

pub const DebugSphere = struct {
    center: components.Vec3,
    radius: f32,
};

pub const PhysicsDebugInfo = struct {
    entity_id: EntityId,
    shape: DebugShape,
    is_trigger: bool,
};

const PhysicsEvent = union(enum) {
    entity_created: EntityId,
    entity_destroyed: EntityId,
    rigidbody_added: EntityId,
    rigidbody_removed: EntityId,
    collider_added: EntityId,
    collider_removed: EntityId,
    constraint_added: EntityId,
    constraint_removed: EntityId,
    transform_changed: EntityId,
};

// ─────────────────────────────────────────────────────────────────────────────
// PhysicsState: encapsulates all mutable physics state (no more global vars)
// ─────────────────────────────────────────────────────────────────────────────

pub const PhysicsState = struct {
    allocator: std.mem.Allocator,

    /// Debug visualization scratch buffer (reused across frames)
    debug_info: std.ArrayListUnmanaged(PhysicsDebugInfo) = .empty,

    /// Event queue: World mutations → Jolt sync
    event_queue: std.ArrayListUnmanaged(PhysicsEvent) = .empty,
    event_mutex: std.Thread.Mutex = .{},

    /// Trigger events from Jolt callback
    trigger_queue: std.ArrayListUnmanaged(TriggerEvent) = .empty,
    trigger_mutex: std.Thread.Mutex = .{},
    trigger_callback: ?*const fn (TriggerEvent) void = null,

    /// Collision events from Jolt callback (non-sensor rigid body contacts)
    collision_queue: std.ArrayListUnmanaged(CollisionEvent) = .empty,
    collision_mutex: std.Thread.Mutex = .{},

    /// Log deduplication flags
    logged_config: bool = false,
    logged_jolt_backend: bool = false,
    logged_jolt_fallback: bool = false,
    last_snapshot: ?StepSnapshot = null,

    /// Jolt world state cache (keyed by @intFromPtr(world))
    jolt_world_states: std.AutoHashMapUnmanaged(usize, JoltWorldState) = .empty,
    jolt_world_states_mutex: std.Thread.Mutex = .{},

    /// Tracks which worlds have been initialized for Jolt
    jolt_initialized_for_world: std.AutoHashMapUnmanaged(usize, bool) = .empty,
    jolt_initialized_mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) PhysicsState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PhysicsState) void {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        self.event_queue.deinit(self.allocator);

        self.trigger_mutex.lock();
        defer self.trigger_mutex.unlock();
        self.trigger_queue.deinit(self.allocator);

        self.collision_mutex.lock();
        defer self.collision_mutex.unlock();
        self.collision_queue.deinit(self.allocator);

        self.jolt_world_states_mutex.lock();
        defer self.jolt_world_states_mutex.unlock();
        // Destroy all remaining Jolt contexts
        var it = self.jolt_world_states.valueIterator();
        while (it.next()) |state| {
            guava_jolt_context_destroy(state.context);
        }
        self.jolt_world_states.deinit(self.allocator);

        self.jolt_initialized_mutex.lock();
        defer self.jolt_initialized_mutex.unlock();
        self.jolt_initialized_for_world.deinit(self.allocator);

        self.debug_info.deinit(self.allocator);
    }

    pub fn setTriggerCallback(self: *PhysicsState, callback: ?*const fn (TriggerEvent) void) void {
        self.trigger_callback = callback;
    }

    pub fn pollTriggerEvents(self: *PhysicsState) []const TriggerEvent {
        self.trigger_mutex.lock();
        defer self.trigger_mutex.unlock();
        return self.trigger_queue.items;
    }

    pub fn clearTriggerEvents(self: *PhysicsState) void {
        self.trigger_mutex.lock();
        defer self.trigger_mutex.unlock();
        self.trigger_queue.clearRetainingCapacity();
    }

    pub fn pollCollisionEvents(self: *PhysicsState) []const CollisionEvent {
        self.collision_mutex.lock();
        defer self.collision_mutex.unlock();
        return self.collision_queue.items;
    }

    pub fn clearCollisionEvents(self: *PhysicsState) void {
        self.collision_mutex.lock();
        defer self.collision_mutex.unlock();
        self.collision_queue.clearRetainingCapacity();
    }

    pub fn collectDebugShapes(self: *PhysicsState, world: *scene_mod.World, allocator: std.mem.Allocator) ![]PhysicsDebugInfo {
        self.debug_info.clearRetainingCapacity();

        for (world.entities.items) |entity| {
            if (!hasAnyCollider(&entity)) continue;

            const world_transform = entity.world_transform_cache;
            const is_trigger = isTriggerOnly(&entity);

            if (entity.box_collider) |collider| {
                const center = vec3.add(
                    world_transform.translation,
                    vec3.mul(world_transform.scale, collider.center),
                );
                const half_extents = vec3.mul(world_transform.scale, collider.half_extents);

                try self.debug_info.append(allocator, .{
                    .entity_id = entity.id,
                    .shape = .{ .box = .{
                        .center = center,
                        .half_extents = half_extents,
                    } },
                    .is_trigger = is_trigger,
                });
            }

            if (entity.sphere_collider) |collider| {
                const center = vec3.add(
                    world_transform.translation,
                    vec3.mul(world_transform.scale, collider.center),
                );
                const radius = maxComponent(world_transform.scale) * collider.radius;

                try self.debug_info.append(allocator, .{
                    .entity_id = entity.id,
                    .shape = .{ .sphere = .{
                        .center = center,
                        .radius = radius,
                    } },
                    .is_trigger = is_trigger,
                });
            }
        }

        return self.debug_info.items;
    }

    pub fn enqueuePhysicsEvent(self: *PhysicsState, event: PhysicsEvent) void {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        self.event_queue.append(self.allocator, event) catch return;
    }

    pub fn deinitWorld(self: *PhysicsState, world: *scene_mod.World) void {
        self.event_mutex.lock();
        self.event_queue.clearRetainingCapacity();
        self.event_mutex.unlock();

        self.releaseJoltWorldState(@intFromPtr(world));
    }

    pub fn step(self: *PhysicsState, world: *scene_mod.World, delta_seconds: f32, config: Config) StepStats {
        if (!config.enabled or delta_seconds <= epsilon) {
            self.releaseJoltWorldState(@intFromPtr(world));
            return .{};
        }

        self.logConfigOnce(config);
        return switch (config.backend) {
            .builtin => blk: {
                self.releaseJoltWorldState(@intFromPtr(world));
                break :blk stepBuiltin(world, delta_seconds, config);
            },
            .jolt => self.stepJolt(world, delta_seconds, config),
        };
    }

    pub fn raycast(self: *PhysicsState, world: *scene_mod.World, query: RayQuery, filter: QueryFilter) ?RaycastHit {
        if (query.max_distance < 0.0) {
            return null;
        }

        const direction_length = vec3.length(query.direction);
        if (direction_length <= epsilon) {
            return null;
        }

        world.updateHierarchy();
        const normalized_direction = vec3.scale(query.direction, 1.0 / direction_length);

        if (self.joltRaycast(world, query.origin, normalized_direction, query.max_distance, filter)) |maybe_hit| {
            return maybe_hit;
        }

        return raycastBuiltin(world, query.origin, normalized_direction, query.max_distance, filter);
    }

    pub fn overlapAabb(
        self: *PhysicsState,
        world: *scene_mod.World,
        allocator: std.mem.Allocator,
        query_bounds: AABB,
        filter: QueryFilter,
    ) ![]OverlapHit {
        if (!query_bounds.isValid()) {
            return allocator.alloc(OverlapHit, 0);
        }

        world.updateHierarchy();

        if (try self.joltOverlapAabb(world, allocator, query_bounds, filter)) |hits| {
            return hits;
        }

        return overlapAabbBuiltin(world, allocator, query_bounds, filter);
    }

    pub fn sweepAabb(
        self: *PhysicsState,
        world: *scene_mod.World,
        query_bounds: AABB,
        translation: components.Vec3,
        filter: QueryFilter,
    ) ?SweepHit {
        if (!query_bounds.isValid()) {
            return null;
        }

        const travel_distance = vec3.length(translation);
        if (travel_distance <= epsilon) {
            return null;
        }

        world.updateHierarchy();

        if (self.joltSweepAabb(world, query_bounds, translation, filter)) |maybe_hit| {
            return maybe_hit;
        }

        return sweepAabbBuiltin(world, query_bounds, translation, travel_distance, filter);
    }

    // ── Body manipulation API (used by script runtime) ──

    pub fn setBodyLinearVelocity(self: *PhysicsState, world: *scene_mod.World, entity_id: u64, velocity: components.Vec3) void {
        _ = self;
        if (world.id_to_index.get(entity_id)) |idx| {
            var entity = &world.entities.items[idx];
            if (entity.rigidbody) |*rb| {
                rb.linear_velocity = velocity;
            }
        }
    }

    pub fn getBodyLinearVelocity(self: *PhysicsState, world: *scene_mod.World, entity_id: u64) ?components.Vec3 {
        _ = self;
        if (world.id_to_index.get(entity_id)) |idx| {
            const entity = &world.entities.items[idx];
            if (entity.rigidbody) |rb| {
                return rb.linear_velocity;
            }
        }
        return null;
    }

    pub fn addBodyImpulse(self: *PhysicsState, world: *scene_mod.World, entity_id: u64, impulse: components.Vec3) void {
        _ = self;
        if (world.id_to_index.get(entity_id)) |idx| {
            var entity = &world.entities.items[idx];
            if (entity.rigidbody) |*rb| {
                if (rb.mass > 0.0) {
                    const inv_mass = 1.0 / rb.mass;
                    rb.linear_velocity = vec3.add(rb.linear_velocity, vec3.scale(impulse, inv_mass));
                }
            }
        }
    }

    // ── Internal methods (prefixed with ps- to distinguish from free helpers) ──

    fn stepJolt(self: *PhysicsState, world: *scene_mod.World, delta_seconds: f32, config: Config) StepStats {
        if (!self.logged_jolt_backend) {
            physics_log.info("physics backend jolt active (persistent body cache)", .{});
            self.logged_jolt_backend = true;
        }

        world.updateHierarchy();

        var stats = StepStats{};
        countBodies(world, &stats);

        const limits = effectiveJoltBackendLimits(config, stats.dynamic_bodies + stats.static_bodies);
        const jolt_config = buildJoltStepConfig(config, delta_seconds, limits);
        const context = self.ensureJoltWorldContext(world, &jolt_config, limits) orelse
            return self.stepJoltFallback(world, delta_seconds, config, stats);

        self.processPhysicsEvents(world, context, config);
        self.ensureJoltInitializedForWorld(world, context, config);

        var body_states = std.ArrayList(JoltBodyState).empty;
        defer body_states.deinit(world.allocator);
        body_states.resize(world.allocator, stats.dynamic_bodies + stats.static_bodies) catch return self.stepJoltFallback(world, delta_seconds, config, stats);

        var jolt_stats = JoltStepStats{
            .dynamic_bodies = 0,
            .static_bodies = 0,
            .contacts_resolved = 0,
            .state_count = 0,
            .success = 0,
            .reserved0 = 0,
            .reserved1 = 0,
        };

        // Set threadlocal so C export callback can reach us
        g_active_state = self;
        const success = guava_jolt_context_step_incremental(
            context,
            delta_seconds,
            config.jolt_collision_steps,
            body_states.items.ptr,
            body_states.items.len,
            &jolt_stats,
        );
        g_active_state = null;

        if (!success or jolt_stats.success == 0) {
            self.releaseJoltWorldState(@intFromPtr(world));
            return self.stepJoltFallback(world, delta_seconds, config, stats);
        }

        applyJoltBodyStates(world, body_states.items[0..@min(body_states.items.len, @as(usize, @intCast(jolt_stats.state_count)))]);
        world.updateHierarchy();

        // Step and apply character controllers
        syncAndStepCharacters(world, context, delta_seconds, config);

        stats.dynamic_bodies = jolt_stats.dynamic_bodies;
        stats.static_bodies = jolt_stats.static_bodies;
        stats.contacts_resolved = jolt_stats.contacts_resolved;
        self.maybeLogStepSnapshot(stats);
        return stats;
    }

    fn stepJoltFallback(self: *PhysicsState, world: *scene_mod.World, delta_seconds: f32, config: Config, fallback_counts: StepStats) StepStats {
        if (!config.allow_builtin_fallback) {
            std.debug.print("JOLT FALLBACK: success=0\n", .{});
            self.maybeLogStepSnapshot(fallback_counts);
            return fallback_counts;
        }

        if (!self.logged_jolt_fallback) {
            physics_log.warn("jolt backend failed; falling back to builtin solver", .{});
            self.logged_jolt_fallback = true;
        }
        return stepBuiltin(world, delta_seconds, config);
    }

    fn processPhysicsEvents(self: *PhysicsState, world: *scene_mod.World, context: *JoltContext, config: Config) void {
        self.event_mutex.lock();
        defer self.event_mutex.unlock();

        for (self.event_queue.items) |event| {
            switch (event) {
                .entity_created => |entity_id| {
                    if (world.getEntityConst(entity_id)) |entity| {
                        if (buildJoltBodyDesc(world, entity, config)) |desc| {
                            _ = guava_jolt_context_add_or_update_body(context, &desc, 0.0);
                        }
                    }
                },
                .entity_destroyed => |entity_id| {
                    _ = guava_jolt_context_remove_body(context, entity_id);
                    _ = guava_jolt_context_remove_constraint(context, entity_id);
                },
                .rigidbody_added, .collider_added => |entity_id| {
                    if (world.getEntityConst(entity_id)) |entity| {
                        if (buildJoltBodyDesc(world, entity, config)) |desc| {
                            _ = guava_jolt_context_add_or_update_body(context, &desc, 0.0);
                        }
                    }
                },
                .rigidbody_removed, .collider_removed => |entity_id| {
                    _ = guava_jolt_context_remove_body(context, entity_id);
                },
                .constraint_added => |entity_id| {
                    if (world.getEntityConst(entity_id)) |entity| {
                        if (entity.constraint) |constraint| {
                            if (buildJoltConstraintDesc(world, entity, constraint)) |desc| {
                                _ = guava_jolt_context_add_or_update_constraint(context, &desc);
                            }
                        }
                    }
                },
                .constraint_removed => |entity_id| {
                    _ = guava_jolt_context_remove_constraint(context, entity_id);
                },
                .transform_changed => |entity_id| {
                    if (world.getEntityConst(entity_id)) |entity| {
                        if (entity.rigidbody != null or hasAnyCollider(entity)) {
                            if (buildJoltBodyDesc(world, entity, config)) |desc| {
                                _ = guava_jolt_context_add_or_update_body(context, &desc, 0.0);
                            }
                        }
                    }
                },
            }
        }

        self.event_queue.clearRetainingCapacity();
    }

    fn ensureJoltInitializedForWorld(self: *PhysicsState, world: *scene_mod.World, context: *JoltContext, config: Config) void {
        self.jolt_initialized_mutex.lock();
        defer self.jolt_initialized_mutex.unlock();

        const key = @intFromPtr(world);
        if (self.jolt_initialized_for_world.contains(key)) {
            return;
        }

        for (world.entities.items) |*entity| {
            if (entity.rigidbody == null and !hasAnyCollider(entity)) {
                continue;
            }
            if (buildJoltBodyDesc(world, entity, config)) |desc| {
                _ = guava_jolt_context_add_or_update_body(context, &desc, 0.0);
            }
        }

        self.jolt_initialized_for_world.put(self.allocator, key, true) catch {};
    }

    fn ensureJoltWorldContext(
        self: *PhysicsState,
        world: *scene_mod.World,
        create_config: *const JoltStepConfig,
        limits: JoltBackendLimits,
    ) ?*JoltContext {
        const key = @intFromPtr(world);
        self.jolt_world_states_mutex.lock();
        defer self.jolt_world_states_mutex.unlock();

        if (self.jolt_world_states.getPtr(key)) |state| {
            if (state.limits.eql(limits)) {
                return state.context;
            }

            guava_jolt_context_destroy(state.context);
            const replacement = guava_jolt_context_create(create_config) orelse {
                _ = self.jolt_world_states.remove(key);
                return null;
            };
            state.* = .{
                .context = replacement,
                .limits = limits,
            };
            return replacement;
        }

        const context = guava_jolt_context_create(create_config) orelse return null;
        self.jolt_world_states.put(self.allocator, key, .{
            .context = context,
            .limits = limits,
        }) catch {
            guava_jolt_context_destroy(context);
            return null;
        };
        return context;
    }

    fn ensureJoltQueryContext(
        self: *PhysicsState,
        world: *scene_mod.World,
        body_count: usize,
    ) ?*JoltContext {
        const query_config = Config{};
        const limits = effectiveJoltBackendLimits(query_config, body_count);
        const create_config = buildJoltStepConfig(query_config, 0.0, limits);

        const key = @intFromPtr(world);
        self.jolt_world_states_mutex.lock();
        defer self.jolt_world_states_mutex.unlock();

        if (self.jolt_world_states.getPtr(key)) |state| {
            if (joltBackendLimitsCover(state.limits, limits)) {
                return state.context;
            }

            guava_jolt_context_destroy(state.context);
            const replacement = guava_jolt_context_create(&create_config) orelse {
                _ = self.jolt_world_states.remove(key);
                return null;
            };
            state.* = .{
                .context = replacement,
                .limits = limits,
            };
            return replacement;
        }

        const context = guava_jolt_context_create(&create_config) orelse return null;
        self.jolt_world_states.put(self.allocator, key, .{
            .context = context,
            .limits = limits,
        }) catch {
            guava_jolt_context_destroy(context);
            return null;
        };
        return context;
    }

    fn releaseJoltWorldState(self: *PhysicsState, key: usize) void {
        self.jolt_world_states_mutex.lock();
        defer self.jolt_world_states_mutex.unlock();

        if (self.jolt_world_states.fetchRemove(key)) |removed| {
            guava_jolt_context_destroy(removed.value.context);
        }

        self.jolt_initialized_mutex.lock();
        defer self.jolt_initialized_mutex.unlock();
        _ = self.jolt_initialized_for_world.fetchRemove(key);
    }

    fn joltRaycast(
        self: *PhysicsState,
        world: *scene_mod.World,
        origin: components.Vec3,
        normalized_direction: components.Vec3,
        max_distance: f32,
        filter: QueryFilter,
    ) ??RaycastHit {
        const body_count = countQueryableBodies(world);
        const context = self.ensureJoltQueryContext(world, body_count) orelse return null;
        if (!syncJoltQuerySnapshot(world, context, body_count)) {
            return null;
        }

        var raw_hit: JoltRaycastHit = std.mem.zeroes(JoltRaycastHit);
        const query = JoltRayQuery{
            .origin = origin,
            .direction = normalized_direction,
            .max_distance = max_distance,
        };
        const query_filter = joltQueryFilter(filter);
        if (!guava_jolt_context_raycast(context, &query, &query_filter, &raw_hit)) {
            return null;
        }

        if (raw_hit.entity_id == 0) {
            return @as(?RaycastHit, null);
        }

        return makeRaycastHit(world, raw_hit);
    }

    fn joltOverlapAabb(
        self: *PhysicsState,
        world: *scene_mod.World,
        allocator: std.mem.Allocator,
        query_bounds: AABB,
        filter: QueryFilter,
    ) !?[]OverlapHit {
        const body_count = countQueryableBodies(world);
        const context = self.ensureJoltQueryContext(world, body_count) orelse return null;
        if (!syncJoltQuerySnapshot(world, context, body_count)) {
            return null;
        }

        if (body_count == 0) {
            return try allocator.alloc(OverlapHit, 0);
        }

        const center = query_bounds.centroid();
        const half_extents = queryHalfExtents(query_bounds);
        const query_filter = joltQueryFilter(filter);

        var raw_hits = try allocator.alloc(JoltOverlapHit, body_count);
        defer allocator.free(raw_hits);

        var raw_hit_count: usize = 0;
        if (!guava_jolt_context_overlap_aabb(
            context,
            &center,
            &half_extents,
            &query_filter,
            raw_hits.ptr,
            raw_hits.len,
            &raw_hit_count,
        )) {
            return null;
        }

        var hits = std.ArrayList(OverlapHit).empty;
        errdefer hits.deinit(allocator);

        for (raw_hits[0..@min(raw_hit_count, raw_hits.len)]) |raw_hit| {
            const hit = makeOverlapHit(world, raw_hit) orelse continue;
            try hits.append(allocator, hit);
        }

        return try hits.toOwnedSlice(allocator);
    }

    fn joltSweepAabb(
        self: *PhysicsState,
        world: *scene_mod.World,
        query_bounds: AABB,
        translation: components.Vec3,
        filter: QueryFilter,
    ) ??SweepHit {
        const body_count = countQueryableBodies(world);
        const context = self.ensureJoltQueryContext(world, body_count) orelse return null;
        if (!syncJoltQuerySnapshot(world, context, body_count)) {
            return null;
        }

        var raw_hit: JoltSweepHit = std.mem.zeroes(JoltSweepHit);
        const center = query_bounds.centroid();
        const half_extents = queryHalfExtents(query_bounds);
        const query_filter = joltQueryFilter(filter);

        if (!guava_jolt_context_sweep_aabb(
            context,
            &center,
            &half_extents,
            &translation,
            &query_filter,
            &raw_hit,
        )) {
            return null;
        }

        if (raw_hit.entity_id == 0) {
            return @as(?SweepHit, null);
        }

        return makeSweepHit(world, raw_hit);
    }

    fn logConfigOnce(self: *PhysicsState, config: Config) void {
        if (self.logged_config) {
            return;
        }

        physics_log.info(
            "physics config enabled backend={s} fixed_dt={d:.5} gravity=({d:.2},{d:.2},{d:.2}) max_substeps={d}",
            .{
                @tagName(config.backend),
                config.fixed_timestep_seconds,
                config.gravity[0],
                config.gravity[1],
                config.gravity[2],
                config.max_substeps_per_frame,
            },
        );
        self.logged_config = true;
    }

    fn maybeLogStepSnapshot(self: *PhysicsState, stats: StepStats) void {
        const snapshot = StepSnapshot{
            .dynamic_bodies = stats.dynamic_bodies,
            .static_bodies = stats.static_bodies,
            .contacts_resolved = stats.contacts_resolved,
        };

        if (self.last_snapshot) |previous| {
            if (previous.dynamic_bodies == snapshot.dynamic_bodies and
                previous.static_bodies == snapshot.static_bodies and
                previous.contacts_resolved == snapshot.contacts_resolved)
            {
                return;
            }
        }

        physics_log.info(
            "physics step active dynamic={d} static={d} contacts={d}",
            .{ snapshot.dynamic_bodies, snapshot.static_bodies, snapshot.contacts_resolved },
        );
        self.last_snapshot = snapshot;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper functions (no global state dependency)
// ─────────────────────────────────────────────────────────────────────────────

fn buildJoltStepConfig(config: Config, delta_seconds: f32, limits: JoltBackendLimits) JoltStepConfig {
    return .{
        .delta_seconds = delta_seconds,
        .gravity = config.gravity,
        .collision_steps = @max(config.jolt_collision_steps, 1),
        .temp_allocator_size_bytes = limits.temp_allocator_size_bytes,
        .max_bodies = limits.max_bodies,
        .num_body_mutexes = limits.num_body_mutexes,
        .max_body_pairs = limits.max_body_pairs,
        .max_contact_constraints = limits.max_contact_constraints,
    };
}

fn effectiveJoltBackendLimits(config: Config, body_count: usize) JoltBackendLimits {
    const max_u32 = std.math.maxInt(u32);
    const body_count_u32 = @as(u32, @intCast(@min(body_count, max_u32)));
    const body_count_plus_padding = saturatingAddU32(body_count_u32, 16);
    const estimated_pairs = saturatingAddU32(saturatingMulU32(body_count_u32, 4), 16);
    const estimated_contacts = saturatingAddU32(saturatingMulU32(body_count_u32, 8), 16);
    return .{
        .temp_allocator_size_bytes = @max(config.jolt_temp_allocator_size_bytes, 1024 * 1024),
        .max_bodies = @max(config.jolt_max_bodies, body_count_plus_padding),
        .num_body_mutexes = config.jolt_num_body_mutexes,
        .max_body_pairs = @max(config.jolt_max_body_pairs, estimated_pairs),
        .max_contact_constraints = @max(config.jolt_max_contact_constraints, estimated_contacts),
    };
}

fn joltBackendLimitsCover(existing: JoltBackendLimits, required: JoltBackendLimits) bool {
    return existing.temp_allocator_size_bytes >= required.temp_allocator_size_bytes and
        existing.max_bodies >= required.max_bodies and
        existing.num_body_mutexes >= required.num_body_mutexes and
        existing.max_body_pairs >= required.max_body_pairs and
        existing.max_contact_constraints >= required.max_contact_constraints;
}

/// Thread-local pointer used by the C export `GuavaJoltEnqueueTriggerEvent`.
/// Set during `stepJolt` and cleared immediately after.
threadlocal var g_active_state: ?*PhysicsState = null;
const jolt_flag_has_box: u32 = 1 << 0;
const jolt_flag_has_sphere: u32 = 1 << 1;
const jolt_flag_has_mesh_proxy: u32 = 1 << 2;
const jolt_flag_body_is_sensor: u32 = 1 << 3;
const jolt_flag_allow_sleep: u32 = 1 << 4;
const jolt_flag_has_capsule: u32 = 1 << 5;

const StepSnapshot = struct {
    dynamic_bodies: usize,
    static_bodies: usize,
    contacts_resolved: usize,
};

const ContactResolution = struct {
    translation: components.Vec3,
};

const JoltBodyDesc = extern struct {
    entity_id: u64,
    motion_type: u32,
    flags: u32,
    mass: f32,
    gravity_scale: f32,
    linear_damping: f32,
    angular_damping: f32,
    max_linear_speed: f32,
    max_angular_speed: f32,
    position: [3]f32,
    rotation: [4]f32,
    linear_velocity: [3]f32,
    angular_velocity: [3]f32,
    box_half_extents: [3]f32,
    box_center: [3]f32,
    sphere_radius: f32,
    sphere_center: [3]f32,
    mesh_half_extents: [3]f32,
    mesh_center: [3]f32,
    capsule_radius: f32,
    capsule_half_height: f32,
    capsule_center: [3]f32,
    layer_id: u16,
    layer_group: u16,
};

const JoltConstraintDesc = extern struct {
    entity_id: u64,
    constraint_type: u8,
    entity_a: u64,
    entity_b: u64,
    pivot_a: [3]f32,
    pivot_b: [3]f32,
    axis_a: [3]f32,
    axis_b: [3]f32,
    min_limit: f32,
    max_limit: f32,
    is_enabled: u8,
};

const JoltStepConfig = extern struct {
    delta_seconds: f32,
    gravity: [3]f32,
    collision_steps: u32,
    temp_allocator_size_bytes: u32,
    max_bodies: u32,
    num_body_mutexes: u32,
    max_body_pairs: u32,
    max_contact_constraints: u32,
};

const JoltBodyState = extern struct {
    entity_id: u64,
    position: [3]f32,
    rotation: [4]f32,
    linear_velocity: [3]f32,
    angular_velocity: [3]f32,
};

const JoltStepStats = extern struct {
    dynamic_bodies: u32,
    static_bodies: u32,
    contacts_resolved: u32,
    state_count: u32,
    success: u8,
    reserved0: u8,
    reserved1: u16,
};

const JoltQueryFilter = extern struct {
    exclude_entity: u64,
    layer_id: u16,
    layer_group_mask: u16,
    has_exclude_entity: u8,
    include_triggers: u8,
    has_layer_id: u8,
    reserved0: u8,
};

const JoltRayQuery = extern struct {
    origin: [3]f32,
    direction: [3]f32,
    max_distance: f32,
};

const JoltRaycastHit = extern struct {
    entity_id: u64,
    distance: f32,
    position: [3]f32,
    normal: [3]f32,
    is_trigger: u8,
    reserved0: u8,
    reserved1: u16,
};

const JoltOverlapHit = extern struct {
    entity_id: u64,
    is_trigger: u8,
    reserved0: u8,
    reserved1: u16,
};

const JoltSweepHit = extern struct {
    entity_id: u64,
    fraction: f32,
    distance: f32,
    position: [3]f32,
    normal: [3]f32,
    is_trigger: u8,
    reserved0: u8,
    reserved1: u16,
};

const JoltContext = opaque {};

const JoltBackendLimits = struct {
    temp_allocator_size_bytes: u32,
    max_bodies: u32,
    num_body_mutexes: u32,
    max_body_pairs: u32,
    max_contact_constraints: u32,

    fn eql(self: JoltBackendLimits, other: JoltBackendLimits) bool {
        return self.temp_allocator_size_bytes == other.temp_allocator_size_bytes and
            self.max_bodies == other.max_bodies and
            self.num_body_mutexes == other.num_body_mutexes and
            self.max_body_pairs == other.max_body_pairs and
            self.max_contact_constraints == other.max_contact_constraints;
    }
};

const JoltWorldState = struct {
    context: *JoltContext,
    limits: JoltBackendLimits,
};

extern fn guava_jolt_context_create(config: *const JoltStepConfig) callconv(.c) ?*JoltContext;
extern fn guava_jolt_context_destroy(context: *JoltContext) callconv(.c) void;
extern fn guava_jolt_context_step(
    context: *JoltContext,
    bodies: [*]const JoltBodyDesc,
    body_count: usize,
    config: *const JoltStepConfig,
    out_states: [*]JoltBodyState,
    state_capacity: usize,
    out_stats: *JoltStepStats,
) callconv(.c) bool;
extern fn guava_jolt_context_add_or_update_body(
    context: *JoltContext,
    desc: *const JoltBodyDesc,
    delta_seconds: f32,
) callconv(.c) bool;
extern fn guava_jolt_context_remove_body(
    context: *JoltContext,
    entity_id: u64,
) callconv(.c) bool;
extern fn guava_jolt_context_step_incremental(
    context: *JoltContext,
    delta_seconds: f32,
    collision_steps: u32,
    out_states: [*]JoltBodyState,
    state_capacity: usize,
    out_stats: *JoltStepStats,
) callconv(.c) bool;
extern fn guava_jolt_context_add_or_update_constraint(
    context: *JoltContext,
    desc: *const JoltConstraintDesc,
) callconv(.c) bool;
extern fn guava_jolt_context_remove_constraint(
    context: *JoltContext,
    entity_id: u64,
) callconv(.c) bool;
extern fn guava_jolt_context_sync_snapshot(
    context: *JoltContext,
    bodies: [*]const JoltBodyDesc,
    body_count: usize,
    delta_seconds: f32,
) callconv(.c) bool;
extern fn guava_jolt_context_raycast(
    context: *JoltContext,
    query: *const JoltRayQuery,
    filter: *const JoltQueryFilter,
    out_hit: *JoltRaycastHit,
) callconv(.c) bool;
extern fn guava_jolt_context_overlap_aabb(
    context: *JoltContext,
    center: *const [3]f32,
    half_extents: *const [3]f32,
    filter: *const JoltQueryFilter,
    out_hits: [*]JoltOverlapHit,
    out_capacity: usize,
    out_count: *usize,
) callconv(.c) bool;
extern fn guava_jolt_context_sweep_aabb(
    context: *JoltContext,
    center: *const [3]f32,
    half_extents: *const [3]f32,
    translation: *const [3]f32,
    filter: *const JoltQueryFilter,
    out_hit: *JoltSweepHit,
) callconv(.c) bool;

const JoltCharacterDesc = extern struct {
    entity_id: u64,
    max_slope_angle: f32,
    max_strength: f32,
    padding: f32,
    mass: f32,
    capsule_radius: f32,
    capsule_half_height: f32,
    up_direction: [3]f32,
    position: [3]f32,
    rotation: [4]f32,
    move_velocity: [3]f32,
};

const JoltCharacterState = extern struct {
    entity_id: u64,
    position: [3]f32,
    rotation: [4]f32,
    is_grounded: u8,
    reserved0: u8,
    reserved1: u16,
};

extern fn guava_jolt_context_add_or_update_character(
    context: *JoltContext,
    desc: *const JoltCharacterDesc,
    delta_seconds: f32,
) callconv(.c) bool;
extern fn guava_jolt_context_remove_character(
    context: *JoltContext,
    entity_id: u64,
) callconv(.c) bool;
extern fn guava_jolt_context_step_characters(
    context: *JoltContext,
    delta_seconds: f32,
    gravity: *const [3]f32,
    out_states: [*]JoltCharacterState,
    max_states: usize,
) callconv(.c) u32;

export fn GuavaJoltEnqueueTriggerEvent(event: *const extern struct {
    entity_a: u64,
    entity_b: u64,
    kind: u8,
}) void {
    const state = g_active_state orelse return;
    state.trigger_mutex.lock();
    defer state.trigger_mutex.unlock();

    const trigger_event = TriggerEvent{
        .entity_a = event.entity_a,
        .entity_b = event.entity_b,
        .kind = @enumFromInt(event.kind),
    };

    state.trigger_queue.append(state.allocator, trigger_event) catch return;

    if (state.trigger_callback) |callback| {
        callback(trigger_event);
    }
}

export fn GuavaJoltEnqueueCollisionEvent(event: *const extern struct {
    entity_a: u64,
    entity_b: u64,
    kind: u8,
}) void {
    const state = g_active_state orelse return;
    state.collision_mutex.lock();
    defer state.collision_mutex.unlock();

    const collision_event = CollisionEvent{
        .entity_a = event.entity_a,
        .entity_b = event.entity_b,
        .kind = @enumFromInt(event.kind),
    };

    state.collision_queue.append(state.allocator, collision_event) catch return;
}

pub const Backend = enum {
    jolt,
    builtin,
};

pub const Config = struct {
    enabled: bool = true,
    backend: Backend = .jolt,
    allow_builtin_fallback: bool = true,
    fixed_timestep_seconds: f32 = 1.0 / 60.0,
    max_substeps_per_frame: u8 = 4,
    gravity: components.Vec3 = .{ 0.0, -9.81, 0.0 },
    contact_offset: f32 = 0.005,
    max_linear_speed: f32 = 100.0,
    jolt_collision_steps: u32 = 1,
    jolt_temp_allocator_size_bytes: u32 = 10 * 1024 * 1024,
    jolt_max_bodies: u32 = 65_536,
    jolt_num_body_mutexes: u32 = 0,
    jolt_max_body_pairs: u32 = 65_536,
    jolt_max_contact_constraints: u32 = 10_240,
};

pub const StepStats = struct {
    dynamic_bodies: usize = 0,
    static_bodies: usize = 0,
    contacts_resolved: usize = 0,
};

pub const RayQuery = struct {
    origin: components.Vec3,
    direction: components.Vec3,
    max_distance: f32 = std.math.inf(f32),
};

pub const QueryFilter = struct {
    exclude_entity: ?EntityId = null,
    include_triggers: bool = false,
    layer_id: ?u16 = null,
    layer_group_mask: u16 = 0xFFFF,
};

pub const RaycastHit = struct {
    entity_id: EntityId,
    distance: f32,
    position: components.Vec3,
    normal: components.Vec3,
    bounds: AABB,
    is_trigger: bool,
};

pub const OverlapHit = struct {
    entity_id: EntityId,
    bounds: AABB,
    is_trigger: bool,
};

pub const SweepHit = struct {
    entity_id: EntityId,
    fraction: f32,
    distance: f32,
    position: components.Vec3,
    normal: components.Vec3,
    bounds: AABB,
    is_trigger: bool,
};

pub fn aabbFromCenterHalfExtents(center: components.Vec3, half_extents: components.Vec3) AABB {
    return .{
        .min = vec3.sub(center, half_extents),
        .max = vec3.add(center, half_extents),
    };
}

fn raycastBuiltin(
    world: *scene_mod.World,
    origin: components.Vec3,
    normalized_direction: components.Vec3,
    max_distance: f32,
    filter: QueryFilter,
) ?RaycastHit {
    var best_hit: ?RaycastHit = null;
    for (world.entities.items) |*entity| {
        if (!queryFilterMatches(entity, filter)) {
            continue;
        }

        const bounds = colliderBoundsForEntityTransform(world, entity.id, entity.world_transform_cache) orelse continue;
        const hit = raycastAabb(bounds, origin, normalized_direction, max_distance) orelse continue;
        if (best_hit == null or hit.distance < best_hit.?.distance) {
            best_hit = .{
                .entity_id = entity.id,
                .distance = hit.distance,
                .position = hit.position,
                .normal = hit.normal,
                .bounds = bounds,
                .is_trigger = isTriggerOnly(entity),
            };
        }
    }

    return best_hit;
}

fn overlapAabbBuiltin(
    world: *scene_mod.World,
    allocator: std.mem.Allocator,
    query_bounds: AABB,
    filter: QueryFilter,
) ![]OverlapHit {
    var hits = std.ArrayList(OverlapHit).empty;
    errdefer hits.deinit(allocator);

    for (world.entities.items) |*entity| {
        if (!queryFilterMatches(entity, filter)) {
            continue;
        }

        const bounds = colliderBoundsForEntityTransform(world, entity.id, entity.world_transform_cache) orelse continue;
        if (!aabbIntersects(query_bounds, bounds)) {
            continue;
        }

        try hits.append(allocator, .{
            .entity_id = entity.id,
            .bounds = bounds,
            .is_trigger = isTriggerOnly(entity),
        });
    }

    return try hits.toOwnedSlice(allocator);
}

fn sweepAabbBuiltin(
    world: *scene_mod.World,
    query_bounds: AABB,
    translation: components.Vec3,
    travel_distance: f32,
    filter: QueryFilter,
) ?SweepHit {
    const direction = vec3.scale(translation, 1.0 / travel_distance);
    const query_half_extents = vec3.scale(query_bounds.extent(), 0.5);
    const query_center = query_bounds.centroid();

    var best_hit: ?SweepHit = null;
    for (world.entities.items) |*entity| {
        if (!queryFilterMatches(entity, filter)) {
            continue;
        }

        const bounds = colliderBoundsForEntityTransform(world, entity.id, entity.world_transform_cache) orelse continue;
        const expanded_bounds = expandAabb(bounds, query_half_extents);
        const hit = raycastAabb(expanded_bounds, query_center, direction, travel_distance) orelse continue;
        if (best_hit == null or hit.distance < best_hit.?.distance) {
            best_hit = .{
                .entity_id = entity.id,
                .fraction = hit.distance / travel_distance,
                .distance = hit.distance,
                .position = hit.position,
                .normal = hit.normal,
                .bounds = bounds,
                .is_trigger = isTriggerOnly(entity),
            };
        }
    }

    return best_hit;
}

fn stepBuiltin(world: *scene_mod.World, delta_seconds: f32, config: Config) StepStats {
    var stats = StepStats{};
    world.updateHierarchy();
    countBodies(world, &stats);

    integrateDynamicBodies(world, delta_seconds, config);
    world.updateHierarchy();

    stats.contacts_resolved = resolveStaticContacts(world, config);
    world.updateHierarchy();

    return stats;
}

fn countQueryableBodies(world: *const scene_mod.World) usize {
    var count: usize = 0;
    for (world.entities.items) |*entity| {
        if (hasAnyCollider(entity)) {
            count += 1;
        }
    }
    return count;
}

fn syncJoltQuerySnapshot(
    world: *scene_mod.World,
    context: *JoltContext,
    body_count: usize,
) bool {
    var body_descs = std.ArrayList(JoltBodyDesc).empty;
    defer body_descs.deinit(world.allocator);
    body_descs.ensureTotalCapacity(world.allocator, body_count) catch return false;

    const query_config = Config{};
    for (world.entities.items) |*entity| {
        if (buildJoltBodyDesc(world, entity, query_config)) |desc| {
            body_descs.appendAssumeCapacity(desc);
        }
    }

    var empty_desc = std.mem.zeroes(JoltBodyDesc);
    const desc_ptr = if (body_descs.items.len > 0)
        body_descs.items.ptr
    else
        @as([*]const JoltBodyDesc, @ptrCast(&empty_desc));

    return guava_jolt_context_sync_snapshot(context, desc_ptr, body_descs.items.len, 0.0);
}

fn joltQueryFilter(filter: QueryFilter) JoltQueryFilter {
    return .{
        .exclude_entity = filter.exclude_entity orelse 0,
        .layer_id = filter.layer_id orelse 0,
        .layer_group_mask = filter.layer_group_mask,
        .has_exclude_entity = if (filter.exclude_entity != null) 1 else 0,
        .include_triggers = if (filter.include_triggers) 1 else 0,
        .has_layer_id = if (filter.layer_id != null) 1 else 0,
        .reserved0 = 0,
    };
}

fn queryHalfExtents(bounds: AABB) components.Vec3 {
    return maxVec3(vec3.scale(bounds.extent(), 0.5), .{ epsilon, epsilon, epsilon });
}

fn entityQueryBounds(world: *scene_mod.World, entity_id: EntityId) ?AABB {
    const entity = world.getEntityConst(entity_id) orelse return null;
    return colliderBoundsForEntityTransform(world, entity_id, entity.world_transform_cache);
}

fn makeRaycastHit(world: *scene_mod.World, raw_hit: JoltRaycastHit) ?RaycastHit {
    _ = world.getEntityConst(raw_hit.entity_id) orelse return null;
    return .{
        .entity_id = raw_hit.entity_id,
        .distance = raw_hit.distance,
        .position = raw_hit.position,
        .normal = vec3.normalize(raw_hit.normal),
        .bounds = entityQueryBounds(world, raw_hit.entity_id) orelse AABB.empty(),
        .is_trigger = raw_hit.is_trigger != 0,
    };
}

fn makeOverlapHit(world: *scene_mod.World, raw_hit: JoltOverlapHit) ?OverlapHit {
    _ = world.getEntityConst(raw_hit.entity_id) orelse return null;
    return .{
        .entity_id = raw_hit.entity_id,
        .bounds = entityQueryBounds(world, raw_hit.entity_id) orelse AABB.empty(),
        .is_trigger = raw_hit.is_trigger != 0,
    };
}

fn makeSweepHit(world: *scene_mod.World, raw_hit: JoltSweepHit) ?SweepHit {
    _ = world.getEntityConst(raw_hit.entity_id) orelse return null;
    return .{
        .entity_id = raw_hit.entity_id,
        .fraction = raw_hit.fraction,
        .distance = raw_hit.distance,
        .position = raw_hit.position,
        .normal = vec3.normalize(raw_hit.normal),
        .bounds = entityQueryBounds(world, raw_hit.entity_id) orelse AABB.empty(),
        .is_trigger = raw_hit.is_trigger != 0,
    };
}

fn applyJoltBodyStates(world: *scene_mod.World, body_states: []const JoltBodyState) void {
    for (body_states) |state| {
        const entity = world.getEntityConst(state.entity_id) orelse continue;
        const body = entity.rigidbody orelse continue;
        if (body.motion_type == .static) {
            continue;
        }

        var world_transform = entity.world_transform_cache;
        world_transform.translation = state.position;
        world_transform.rotation = state.rotation;
        _ = world.setEntityWorldTransform(state.entity_id, world_transform);

        if (world.getEntity(state.entity_id)) |entity_mut| {
            if (entity_mut.rigidbody) |body_val| {
                var new_body = body_val;
                new_body.linear_velocity = state.linear_velocity;
                new_body.angular_velocity = state.angular_velocity;
                entity_mut.rigidbody = new_body;
            }
        }
    }
}

fn buildJoltConstraintDesc(world: *const scene_mod.World, entity: *const scene_mod.Entity, constraint: components.Constraint) ?JoltConstraintDesc {
    const body_a = world.getEntityConst(constraint.entity_a) orelse return null;
    const body_b = world.getEntityConst(constraint.entity_b) orelse return null;

    _ = body_a;
    _ = body_b;

    return JoltConstraintDesc{
        .entity_id = entity.id,
        .constraint_type = @intFromEnum(constraint.constraint_type),
        .entity_a = constraint.entity_a,
        .entity_b = constraint.entity_b,
        .pivot_a = constraint.pivot_a,
        .pivot_b = constraint.pivot_b,
        .axis_a = constraint.axis_a,
        .axis_b = constraint.axis_b,
        .min_limit = constraint.min_limit,
        .max_limit = constraint.max_limit,
        .is_enabled = if (constraint.is_enabled) 1 else 0,
    };
}

fn syncAndStepCharacters(world: *scene_mod.World, context: *JoltContext, delta_seconds: f32, config: Config) void {
    // Count character controllers to size output buffer
    var char_count: usize = 0;
    for (world.entities.items) |*entity| {
        if (entity.character_controller != null) char_count += 1;
    }
    if (char_count == 0) return;

    const gravity = config.gravity;

    // Sync character descs to Jolt
    for (world.entities.items) |*entity| {
        const ctrl = entity.character_controller orelse continue;
        const capsule = entity.capsule_collider orelse components.CapsuleCollider{};
        const wt = entity.world_transform_cache;
        const scale_max = maxComponent(absVec3(wt.scale));
        const char_desc = JoltCharacterDesc{
            .entity_id = entity.id,
            .max_slope_angle = ctrl.max_slope_angle,
            .max_strength = ctrl.max_strength,
            .padding = ctrl.padding,
            .mass = ctrl.mass,
            .capsule_radius = @max(scale_max * capsule.radius, epsilon),
            .capsule_half_height = @max(scale_max * capsule.half_height, 0.0),
            .up_direction = ctrl.up_direction,
            .position = wt.translation,
            .rotation = wt.rotation,
            .move_velocity = ctrl.move_velocity,
        };
        _ = guava_jolt_context_add_or_update_character(context, &char_desc, delta_seconds);
    }

    // Step all characters and collect new state
    var char_states_buf: [1024]JoltCharacterState = undefined;
    const written = guava_jolt_context_step_characters(
        context,
        delta_seconds,
        &gravity,
        &char_states_buf,
        @min(char_count, char_states_buf.len),
    );

    // Apply state back to entities
    for (char_states_buf[0..written]) |state| {
        if (world.getEntity(state.entity_id)) |entity| {
            entity.local_transform.translation = state.position;
            entity.local_transform.rotation = state.rotation;
            entity.dirty = true;
            if (entity.character_controller) |*ctrl| {
                ctrl.is_grounded = state.is_grounded != 0;
            }
        }
    }
    world.updateHierarchy();
}

fn buildJoltBodyDesc(world: *const scene_mod.World, entity: *const scene_mod.Entity, config: Config) ?JoltBodyDesc {
    if (!hasAnyCollider(entity)) {
        return null;
    }

    const body = entity.rigidbody orelse components.Rigidbody{ .motion_type = .static };
    const world_transform = entity.world_transform_cache;
    const scale_abs = absVec3(world_transform.scale);

    const layer_info = extractLayerInfo(entity);

    var desc = JoltBodyDesc{
        .entity_id = entity.id,
        .motion_type = motionTypeToJolt(body.motion_type),
        .flags = if (isTriggerOnly(entity)) jolt_flag_body_is_sensor else 0,
        .mass = body.mass,
        .gravity_scale = body.gravity_scale,
        .linear_damping = body.linear_damping,
        .angular_damping = body.angular_damping,
        .max_linear_speed = config.max_linear_speed,
        .max_angular_speed = 100.0,
        .position = world_transform.translation,
        .rotation = world_transform.rotation,
        .linear_velocity = body.linear_velocity,
        .angular_velocity = body.angular_velocity,
        .box_half_extents = .{ 0.0, 0.0, 0.0 },
        .box_center = .{ 0.0, 0.0, 0.0 },
        .sphere_radius = 0.0,
        .sphere_center = .{ 0.0, 0.0, 0.0 },
        .mesh_half_extents = .{ 0.0, 0.0, 0.0 },
        .mesh_center = .{ 0.0, 0.0, 0.0 },
        .capsule_radius = 0.0,
        .capsule_half_height = 0.0,
        .capsule_center = .{ 0.0, 0.0, 0.0 },
        .layer_id = layer_info.id,
        .layer_group = layer_info.group,
    };
    if (body.allow_sleep) {
        desc.flags |= jolt_flag_allow_sleep;
    }

    if (entity.box_collider) |collider| {
        desc.flags |= jolt_flag_has_box;
        desc.box_half_extents = maxVec3(vec3.mul(scale_abs, collider.half_extents), .{ epsilon, epsilon, epsilon });
        desc.box_center = vec3.mul(world_transform.scale, collider.center);
    }

    if (entity.sphere_collider) |collider| {
        desc.flags |= jolt_flag_has_sphere;
        desc.sphere_radius = @max(maxComponent(scale_abs) * collider.radius, epsilon);
        desc.sphere_center = vec3.mul(world_transform.scale, collider.center);
    }

    if (entity.mesh_collider) |collider| {
        if (resolveAttachedMeshBounds(world, entity, collider)) |mesh_bounds| {
            const scaled_bounds = mesh_bounds.transformed(.{
                .scale = world_transform.scale,
            });
            if (scaled_bounds.isValid()) {
                desc.flags |= jolt_flag_has_mesh_proxy;
                desc.mesh_center = scaled_bounds.centroid();
                desc.mesh_half_extents = maxVec3(
                    vec3.scale(scaled_bounds.extent(), 0.5),
                    .{ epsilon, epsilon, epsilon },
                );
            }
        }
    }

    if (entity.capsule_collider) |collider| {
        const scale_max = maxComponent(scale_abs);
        desc.flags |= jolt_flag_has_capsule;
        desc.capsule_radius = @max(scale_max * collider.radius, epsilon);
        desc.capsule_half_height = @max(scale_max * collider.half_height, 0.0);
        desc.capsule_center = vec3.mul(world_transform.scale, collider.center);
    }

    return if ((desc.flags & (jolt_flag_has_box | jolt_flag_has_sphere | jolt_flag_has_mesh_proxy | jolt_flag_has_capsule)) != 0) desc else null;
}

fn extractLayerInfo(entity: *const scene_mod.Entity) struct { id: u16, group: u16 } {
    if (entity.box_collider) |collider| {
        return .{ .id = collider.layer_id, .group = collider.layer_group };
    }
    if (entity.sphere_collider) |collider| {
        return .{ .id = collider.layer_id, .group = collider.layer_group };
    }
    if (entity.capsule_collider) |collider| {
        return .{ .id = collider.layer_id, .group = collider.layer_group };
    }
    if (entity.mesh_collider) |collider| {
        return .{ .id = collider.layer_id, .group = collider.layer_group };
    }
    return .{ .id = 0, .group = 0xFFFF };
}

fn motionTypeToJolt(motion_type: components.RigidbodyMotionType) u32 {
    return switch (motion_type) {
        .static => 0,
        .dynamic => 1,
        .kinematic => 2,
    };
}

fn countBodies(world: *const scene_mod.World, stats: *StepStats) void {
    for (world.entities.items) |entity| {
        if (entity.rigidbody) |body| {
            switch (body.motion_type) {
                .dynamic => stats.dynamic_bodies += 1,
                .static, .kinematic => stats.static_bodies += 1,
            }
        } else if (hasAnyCollider(&entity)) {
            stats.static_bodies += 1;
        }
    }
}

fn integrateDynamicBodies(world: *scene_mod.World, delta_seconds: f32, config: Config) void {
    var index: usize = 0;
    while (index < world.entities.items.len) : (index += 1) {
        const entity_id = world.entities.items[index].id;
        var apply_transform = false;
        var next_world_transform: components.Transform = undefined;

        {
            const entity = &world.entities.items[index];
            const body = entity.rigidbody orelse continue;
            if (body.motion_type != .dynamic) {
                continue;
            }

            var updated_body = body;
            updated_body.linear_velocity = vec3.add(
                updated_body.linear_velocity,
                vec3.scale(config.gravity, updated_body.gravity_scale * delta_seconds),
            );

            const damping = std.math.clamp(1.0 - updated_body.linear_damping * delta_seconds, 0.0, 1.0);
            updated_body.linear_velocity = vec3.scale(updated_body.linear_velocity, damping);

            const speed = vec3.length(updated_body.linear_velocity);
            if (speed > config.max_linear_speed and speed > epsilon) {
                updated_body.linear_velocity = vec3.scale(updated_body.linear_velocity, config.max_linear_speed / speed);
            }

            next_world_transform = entity.world_transform_cache;
            next_world_transform.translation = vec3.add(
                next_world_transform.translation,
                vec3.scale(updated_body.linear_velocity, delta_seconds),
            );

            entity.rigidbody = updated_body;
            apply_transform = true;
        }

        if (apply_transform) {
            _ = world.setEntityWorldTransform(entity_id, next_world_transform);
        }
    }
}

fn resolveStaticContacts(world: *scene_mod.World, config: Config) usize {
    var contact_count: usize = 0;
    var index: usize = 0;
    while (index < world.entities.items.len) : (index += 1) {
        const entity_id = world.entities.items[index].id;

        var current_transform: components.Transform = undefined;
        var current_velocity: components.Vec3 = undefined;
        var has_contact = false;

        {
            const entity = &world.entities.items[index];
            const body = entity.rigidbody orelse continue;
            if (body.motion_type != .dynamic or isTriggerOnly(entity)) {
                continue;
            }

            current_transform = entity.world_transform_cache;
            current_velocity = body.linear_velocity;
        }

        var self_bounds = colliderBoundsForEntityTransform(world, entity_id, current_transform) orelse continue;

        var other_index: usize = 0;
        while (other_index < world.entities.items.len) : (other_index += 1) {
            if (other_index == index) {
                continue;
            }

            const other = &world.entities.items[other_index];
            if (!isStaticCollisionTarget(other) or isTriggerOnly(other)) {
                continue;
            }

            const other_bounds = colliderBoundsForEntityTransform(world, other.id, other.world_transform_cache) orelse continue;
            const resolution = resolveAabbPenetration(self_bounds, other_bounds, current_velocity, config.contact_offset) orelse continue;

            current_transform.translation = vec3.add(current_transform.translation, resolution.translation);
            current_velocity = zeroVelocityOnResolvedAxes(current_velocity, resolution.translation);
            self_bounds = translateBounds(self_bounds, resolution.translation);
            contact_count += 1;
            has_contact = true;
        }

        if (!has_contact) {
            continue;
        }

        _ = world.setEntityWorldTransform(entity_id, current_transform);
        if (world.getEntity(entity_id)) |entity| {
            if (entity.rigidbody) |body_val| {
                var new_body = body_val;
                new_body.linear_velocity = current_velocity;
                entity.rigidbody = new_body;
            }
        }
    }

    return contact_count;
}

fn colliderBoundsForEntityTransform(
    world: *const scene_mod.World,
    entity_id: scene_mod.EntityId,
    world_transform: components.Transform,
) ?AABB {
    const entity = world.getEntityConst(entity_id) orelse return null;
    var combined = AABB.empty();

    if (entity.box_collider) |collider| {
        const local_bounds = AABB{
            .min = vec3.sub(collider.center, collider.half_extents),
            .max = vec3.add(collider.center, collider.half_extents),
        };
        combined.expandAABB(local_bounds.transformed(world_transform));
    }

    if (entity.sphere_collider) |collider| {
        const radius_vec: components.Vec3 = .{ collider.radius, collider.radius, collider.radius };
        const local_bounds = AABB{
            .min = vec3.sub(collider.center, radius_vec),
            .max = vec3.add(collider.center, radius_vec),
        };
        combined.expandAABB(local_bounds.transformed(world_transform));
    }

    if (entity.mesh_collider) |collider| {
        if (resolveAttachedMeshBounds(world, entity, collider)) |mesh_bounds| {
            combined.expandAABB(mesh_bounds.transformed(world_transform));
        }
    }

    return if (combined.isValid()) combined else null;
}

fn resolveAttachedMeshBounds(
    world: *const scene_mod.World,
    entity: *const scene_mod.Entity,
    collider: components.MeshCollider,
) ?AABB {
    if (!collider.use_attached_mesh) {
        return null;
    }

    if (entity.mesh) |mesh| {
        if (mesh.handle) |handle| {
            if (world.resources.mesh(handle)) |mesh_resource| {
                return mesh_resource.local_bounds;
            }
        }
    }

    if (entity.skinned_mesh) |skinned_mesh| {
        if (skinned_mesh.mesh_handle) |handle| {
            if (world.resources.mesh(handle)) |mesh_resource| {
                return mesh_resource.local_bounds;
            }
        }
    }

    return null;
}

fn hasAnyCollider(entity: *const scene_mod.Entity) bool {
    return entity.box_collider != null or entity.sphere_collider != null or
        entity.mesh_collider != null or entity.capsule_collider != null;
}

fn isStaticCollisionTarget(entity: *const scene_mod.Entity) bool {
    if (!hasAnyCollider(entity)) {
        return false;
    }

    if (entity.rigidbody) |body| {
        return body.motion_type != .dynamic;
    }

    return true;
}

fn isTriggerOnly(entity: *const scene_mod.Entity) bool {
    var has_collider = false;
    var has_solid = false;

    if (entity.box_collider) |collider| {
        has_collider = true;
        if (!collider.is_trigger) {
            has_solid = true;
        }
    }
    if (entity.sphere_collider) |collider| {
        has_collider = true;
        if (!collider.is_trigger) {
            has_solid = true;
        }
    }
    if (entity.mesh_collider) |collider| {
        has_collider = true;
        if (!collider.is_trigger) {
            has_solid = true;
        }
    }
    if (entity.capsule_collider) |collider| {
        has_collider = true;
        if (!collider.is_trigger) {
            has_solid = true;
        }
    }

    return has_collider and !has_solid;
}

fn queryFilterMatches(entity: *const scene_mod.Entity, filter: QueryFilter) bool {
    if (filter.exclude_entity) |excluded| {
        if (entity.id == excluded) {
            return false;
        }
    }

    if (!hasAnyCollider(entity)) {
        return false;
    }

    if (!filter.include_triggers and isTriggerOnly(entity)) {
        return false;
    }

    const layer_info = extractLayerInfo(entity);
    if (filter.layer_id) |required_layer_id| {
        if (layer_info.id != required_layer_id) {
            return false;
        }
    }

    return (layer_info.group & filter.layer_group_mask) != 0;
}

fn aabbIntersects(lhs: AABB, rhs: AABB) bool {
    if (!lhs.isValid() or !rhs.isValid()) {
        return false;
    }

    return !(lhs.max[0] < rhs.min[0] or lhs.min[0] > rhs.max[0] or
        lhs.max[1] < rhs.min[1] or lhs.min[1] > rhs.max[1] or
        lhs.max[2] < rhs.min[2] or lhs.min[2] > rhs.max[2]);
}

fn aabbContainsPoint(bounds: AABB, point: components.Vec3) bool {
    if (!bounds.isValid()) {
        return false;
    }

    return point[0] >= bounds.min[0] and point[0] <= bounds.max[0] and
        point[1] >= bounds.min[1] and point[1] <= bounds.max[1] and
        point[2] >= bounds.min[2] and point[2] <= bounds.max[2];
}

fn expandAabb(bounds: AABB, half_extents: components.Vec3) AABB {
    return .{
        .min = vec3.sub(bounds.min, half_extents),
        .max = vec3.add(bounds.max, half_extents),
    };
}

const AabbRayHit = struct {
    distance: f32,
    position: components.Vec3,
    normal: components.Vec3,
};

fn raycastAabb(
    bounds: AABB,
    origin: components.Vec3,
    direction: components.Vec3,
    max_distance: f32,
) ?AabbRayHit {
    if (!bounds.isValid() or max_distance < 0.0) {
        return null;
    }

    const inside = aabbContainsPoint(bounds, origin);
    var t_min: f32 = 0.0;
    var t_max: f32 = max_distance;
    var enter_normal: components.Vec3 = .{ 0.0, 0.0, 0.0 };

    var axis: usize = 0;
    while (axis < 3) : (axis += 1) {
        const axis_direction = direction[axis];
        if (@abs(axis_direction) <= epsilon) {
            if (origin[axis] < bounds.min[axis] or origin[axis] > bounds.max[axis]) {
                return null;
            }
            continue;
        }

        const inverse_direction = 1.0 / axis_direction;
        var t1 = (bounds.min[axis] - origin[axis]) * inverse_direction;
        var t2 = (bounds.max[axis] - origin[axis]) * inverse_direction;

        var near_normal: components.Vec3 = .{ 0.0, 0.0, 0.0 };
        var far_normal: components.Vec3 = .{ 0.0, 0.0, 0.0 };
        near_normal[axis] = -1.0;
        far_normal[axis] = 1.0;

        if (t1 > t2) {
            std.mem.swap(f32, &t1, &t2);
            std.mem.swap(components.Vec3, &near_normal, &far_normal);
        }

        if (t1 > t_min) {
            t_min = t1;
            enter_normal = near_normal;
        }

        t_max = @min(t_max, t2);
        if (t_max < t_min) {
            return null;
        }
    }

    if (t_max < 0.0) {
        return null;
    }

    const distance = if (inside) 0.0 else t_min;
    if (distance > max_distance) {
        return null;
    }

    return .{
        .distance = distance,
        .position = vec3.add(origin, vec3.scale(direction, distance)),
        .normal = if (inside) vec3.scale(direction, -1.0) else enter_normal,
    };
}

fn translateBounds(bounds: AABB, offset: components.Vec3) AABB {
    return .{
        .min = vec3.add(bounds.min, offset),
        .max = vec3.add(bounds.max, offset),
    };
}

fn resolveAabbPenetration(
    dynamic_bounds: AABB,
    static_bounds: AABB,
    velocity: components.Vec3,
    contact_offset: f32,
) ?ContactResolution {
    if (!dynamic_bounds.isValid() or !static_bounds.isValid()) {
        return null;
    }

    if (dynamic_bounds.max[0] <= static_bounds.min[0] or dynamic_bounds.min[0] >= static_bounds.max[0] or
        dynamic_bounds.max[1] <= static_bounds.min[1] or dynamic_bounds.min[1] >= static_bounds.max[1] or
        dynamic_bounds.max[2] <= static_bounds.min[2] or dynamic_bounds.min[2] >= static_bounds.max[2])
    {
        return null;
    }

    const move_x = chooseSeparation(
        dynamic_bounds.min[0],
        dynamic_bounds.max[0],
        static_bounds.min[0],
        static_bounds.max[0],
        velocity[0],
        contact_offset,
    );
    const move_y = chooseSeparation(
        dynamic_bounds.min[1],
        dynamic_bounds.max[1],
        static_bounds.min[1],
        static_bounds.max[1],
        velocity[1],
        contact_offset,
    );
    const move_z = chooseSeparation(
        dynamic_bounds.min[2],
        dynamic_bounds.max[2],
        static_bounds.min[2],
        static_bounds.max[2],
        velocity[2],
        contact_offset,
    );

    var translation: components.Vec3 = .{ move_x, 0.0, 0.0 };
    var min_axis_move = @abs(move_x);

    if (@abs(move_y) < min_axis_move) {
        min_axis_move = @abs(move_y);
        translation = .{ 0.0, move_y, 0.0 };
    }
    if (@abs(move_z) < min_axis_move) {
        translation = .{ 0.0, 0.0, move_z };
    }

    return .{ .translation = translation };
}

fn chooseSeparation(
    dynamic_min: f32,
    dynamic_max: f32,
    static_min: f32,
    static_max: f32,
    axis_velocity: f32,
    contact_offset: f32,
) f32 {
    const move_negative = static_min - dynamic_max - contact_offset;
    const move_positive = static_max - dynamic_min + contact_offset;

    if (axis_velocity > epsilon) {
        return move_negative;
    }
    if (axis_velocity < -epsilon) {
        return move_positive;
    }

    return if (@abs(move_negative) < @abs(move_positive)) move_negative else move_positive;
}

fn zeroVelocityOnResolvedAxes(velocity: components.Vec3, translation: components.Vec3) components.Vec3 {
    var result = velocity;
    if (@abs(translation[0]) > epsilon) {
        result[0] = 0.0;
    }
    if (@abs(translation[1]) > epsilon) {
        result[1] = 0.0;
    }
    if (@abs(translation[2]) > epsilon) {
        result[2] = 0.0;
    }
    return result;
}

fn absVec3(value: components.Vec3) components.Vec3 {
    return .{ @abs(value[0]), @abs(value[1]), @abs(value[2]) };
}

fn maxComponent(value: components.Vec3) f32 {
    return @max(value[0], @max(value[1], value[2]));
}

fn maxVec3(value: components.Vec3, min_value: components.Vec3) components.Vec3 {
    return .{
        @max(value[0], min_value[0]),
        @max(value[1], min_value[1]),
        @max(value[2], min_value[2]),
    };
}

fn saturatingAddU32(lhs: u32, rhs: u32) u32 {
    const sum, const overflowed = @addWithOverflow(lhs, rhs);
    return if (overflowed != 0) std.math.maxInt(u32) else sum;
}

fn saturatingMulU32(lhs: u32, rhs: u32) u32 {
    const product, const overflowed = @mulWithOverflow(lhs, rhs);
    return if (overflowed != 0) std.math.maxInt(u32) else product;
}

fn runGroundContactScenario(config: Config) !void {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    var physics = PhysicsState.init(std.testing.allocator);
    defer physics.deinit();

    _ = try world.createEntity(.{
        .name = "Ground",
        .rigidbody = .{ .motion_type = .static },
        .box_collider = .{ .half_extents = .{ 5.0, 0.5, 5.0 } },
    });
    const body_id = try world.createEntity(.{
        .name = "Body",
        .rigidbody = .{
            .motion_type = .dynamic,
            .linear_damping = 0.0,
        },
        .box_collider = .{ .half_extents = .{ 0.5, 0.5, 0.5 } },
        .local_transform = .{
            .translation = .{ 0.0, 3.0, 0.0 },
        },
    });

    var step_index: usize = 0;
    while (step_index < 180) : (step_index += 1) {
        _ = physics.step(&world, 1.0 / 60.0, config);
    }
    world.updateHierarchy();

    const body = world.getEntityConst(body_id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), body.world_transform_cache.translation[1], 0.08);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), body.rigidbody.?.linear_velocity[1], 0.08);
}

fn runKinematicWallScenario(config: Config) !void {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    var physics = PhysicsState.init(std.testing.allocator);
    defer physics.deinit();

    _ = try world.createEntity(.{
        .name = "Wall",
        .rigidbody = .{ .motion_type = .kinematic },
        .box_collider = .{ .half_extents = .{ 0.5, 2.0, 2.0 } },
        .local_transform = .{
            .translation = .{ 2.0, 0.0, 0.0 },
        },
    });
    const body_id = try world.createEntity(.{
        .name = "Body",
        .rigidbody = .{
            .motion_type = .dynamic,
            .linear_velocity = .{ 5.0, 0.0, 0.0 },
            .gravity_scale = 0.0,
            .linear_damping = 0.0,
        },
        .box_collider = .{ .half_extents = .{ 0.5, 0.5, 0.5 } },
    });

    var step_index: usize = 0;
    while (step_index < 30) : (step_index += 1) {
        _ = physics.step(&world, 1.0 / 60.0, config);
    }
    world.updateHierarchy();

    const body = world.getEntityConst(body_id).?;
    try std.testing.expect(body.world_transform_cache.translation[0] <= 1.0 + 0.08);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), body.rigidbody.?.linear_velocity[0], 0.08);
}

test "physics builtin step integrates gravity and resolves static box contact" {
    try runGroundContactScenario(.{
        .backend = .builtin,
    });
}

test "physics jolt step integrates gravity and resolves static box contact" {
    try runGroundContactScenario(.{
        .backend = .jolt,
    });
}

test "physics builtin step preserves kinematic bodies as static colliders" {
    try runKinematicWallScenario(.{
        .backend = .builtin,
    });
}

test "physics jolt step preserves kinematic bodies as static colliders" {
    try runKinematicWallScenario(.{
        .backend = .jolt,
    });
}

test "physics builtin sphere collider integration" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    var physics = PhysicsState.init(std.testing.allocator);
    defer physics.deinit();

    _ = try world.createEntity(.{
        .name = "Ground",
        .rigidbody = .{ .motion_type = .static },
        .box_collider = .{ .half_extents = .{ 5.0, 0.5, 5.0 } },
    });
    const body_id = try world.createEntity(.{
        .name = "Body",
        .rigidbody = .{
            .motion_type = .dynamic,
            .linear_damping = 0.0,
        },
        .sphere_collider = .{ .radius = 0.5 },
        .local_transform = .{
            .translation = .{ 0.0, 3.0, 0.0 },
        },
    });

    var step_index: usize = 0;
    while (step_index < 120) : (step_index += 1) {
        _ = physics.step(&world, 1.0 / 60.0, .{ .backend = .builtin });
    }
    world.updateHierarchy();

    const body = world.getEntityConst(body_id).?;
    try std.testing.expect(body.world_transform_cache.translation[1] < 2.0);
    try std.testing.expect(body.world_transform_cache.translation[1] > 0.4);
}

test "physics builtin angular velocity initialization" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const body_id = try world.createEntity(.{
        .name = "Body",
        .rigidbody = .{
            .motion_type = .dynamic,
            .angular_velocity = .{ 0.0, 10.0, 0.0 },
        },
        .box_collider = .{ .half_extents = .{ 0.5, 0.5, 0.5 } },
    });

    world.updateHierarchy();
    const body = world.getEntityConst(body_id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), body.rigidbody.?.angular_velocity[1], epsilon);
}

test "physics builtin multiple body stacking" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    var physics = PhysicsState.init(std.testing.allocator);
    defer physics.deinit();

    _ = try world.createEntity(.{
        .name = "Ground",
        .rigidbody = .{ .motion_type = .static },
        .box_collider = .{ .half_extents = .{ 5.0, 0.5, 5.0 } },
    });

    _ = try world.createEntity(.{
        .name = "Body1",
        .rigidbody = .{ .motion_type = .dynamic },
        .box_collider = .{ .half_extents = .{ 0.5, 0.5, 0.5 } },
        .local_transform = .{ .translation = .{ 0.0, 2.0, 0.0 } },
    });

    _ = try world.createEntity(.{
        .name = "Body2",
        .rigidbody = .{ .motion_type = .dynamic },
        .box_collider = .{ .half_extents = .{ 0.5, 0.5, 0.5 } },
        .local_transform = .{ .translation = .{ 0.0, 4.0, 0.0 } },
    });

    var step_index: usize = 0;
    while (step_index < 180) : (step_index += 1) {
        _ = physics.step(&world, 1.0 / 60.0, .{ .backend = .builtin });
    }
    world.updateHierarchy();

    const stats = physics.step(&world, 1.0 / 60.0, .{ .backend = .builtin });
    try std.testing.expectEqual(@as(usize, 1), stats.static_bodies);
    try std.testing.expectEqual(@as(usize, 2), stats.dynamic_bodies);
}

test "physics trigger event detection" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    var physics = PhysicsState.init(std.testing.allocator);
    defer physics.deinit();

    _ = try world.createEntity(.{
        .name = "Trigger",
        .rigidbody = .{ .motion_type = .static },
        .box_collider = .{ .half_extents = .{ 1.0, 1.0, 1.0 }, .is_trigger = true },
    });
    const body_id = try world.createEntity(.{
        .name = "Body",
        .rigidbody = .{
            .motion_type = .dynamic,
            .linear_velocity = .{ 0.0, -2.0, 0.0 },
            .gravity_scale = 0.0,
        },
        .box_collider = .{ .half_extents = .{ 0.5, 0.5, 0.5 } },
        .local_transform = .{ .translation = .{ 0.0, 3.0, 0.0 } },
    });

    var step_index: usize = 0;
    while (step_index < 60) : (step_index += 1) {
        _ = physics.step(&world, 1.0 / 60.0, .{ .backend = .builtin });
    }

    physics.clearTriggerEvents();
    _ = physics.step(&world, 1.0 / 60.0, .{ .backend = .builtin });

    world.updateHierarchy();
    const body = world.getEntityConst(body_id).?;
    try std.testing.expect(body.world_transform_cache.translation[1] < 2.0);
}

test "physics raycast returns nearest collider hit" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    var physics = PhysicsState.init(std.testing.allocator);
    defer physics.deinit();

    const front = try world.createEntity(.{
        .name = "Front",
        .rigidbody = .{ .motion_type = .static },
        .box_collider = .{ .half_extents = .{ 0.5, 0.5, 0.5 } },
        .local_transform = .{
            .translation = .{ 0.0, 0.0, 1.0 },
        },
    });
    _ = try world.createEntity(.{
        .name = "Back",
        .rigidbody = .{ .motion_type = .static },
        .box_collider = .{ .half_extents = .{ 0.5, 0.5, 0.5 } },
        .local_transform = .{
            .translation = .{ 0.0, 0.0, 4.0 },
        },
    });

    const hit = physics.raycast(&world, .{
        .origin = .{ 0.0, 0.0, -2.0 },
        .direction = .{ 0.0, 0.0, 1.0 },
        .max_distance = 10.0,
    }, .{}) orelse return error.TestExpectedNonNull;

    try std.testing.expectEqual(front, hit.entity_id);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), hit.distance, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), hit.normal[2], 0.0001);
}

test "physics overlap excludes triggers by default" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    var physics = PhysicsState.init(std.testing.allocator);
    defer physics.deinit();

    const solid = try world.createEntity(.{
        .name = "Solid",
        .rigidbody = .{ .motion_type = .static },
        .box_collider = .{
            .half_extents = .{ 0.5, 0.5, 0.5 },
            .layer_group = 0b0001,
        },
    });
    const trigger = try world.createEntity(.{
        .name = "Trigger",
        .rigidbody = .{ .motion_type = .static },
        .box_collider = .{
            .half_extents = .{ 0.5, 0.5, 0.5 },
            .is_trigger = true,
            .layer_group = 0b0010,
        },
    });

    const query_bounds = AABB{
        .min = .{ -1.0, -1.0, -1.0 },
        .max = .{ 1.0, 1.0, 1.0 },
    };

    const default_hits = try physics.overlapAabb(&world, std.testing.allocator, query_bounds, .{});
    defer std.testing.allocator.free(default_hits);
    try std.testing.expectEqual(@as(usize, 1), default_hits.len);
    try std.testing.expectEqual(solid, default_hits[0].entity_id);

    const filtered_hits = try physics.overlapAabb(&world, std.testing.allocator, query_bounds, .{
        .include_triggers = true,
        .layer_group_mask = 0b0010,
    });
    defer std.testing.allocator.free(filtered_hits);
    try std.testing.expectEqual(@as(usize, 1), filtered_hits.len);
    try std.testing.expectEqual(trigger, filtered_hits[0].entity_id);
    try std.testing.expect(filtered_hits[0].is_trigger);
}

test "physics sweep aabb reports first blocking collider" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    var physics = PhysicsState.init(std.testing.allocator);
    defer physics.deinit();

    const wall = try world.createEntity(.{
        .name = "Wall",
        .rigidbody = .{ .motion_type = .static },
        .box_collider = .{ .half_extents = .{ 0.5, 0.5, 0.5 } },
        .local_transform = .{
            .translation = .{ 2.0, 0.0, 0.0 },
        },
    });

    const hit = physics.sweepAabb(&world, .{
        .min = .{ -0.5, -0.5, -0.5 },
        .max = .{ 0.5, 0.5, 0.5 },
    }, .{ 5.0, 0.0, 0.0 }, .{}) orelse return error.TestExpectedNonNull;

    try std.testing.expectEqual(wall, hit.entity_id);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hit.distance, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), hit.fraction, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), hit.normal[0], 0.0001);
}

test "physics native queries avoid rotated box AABB false positives" {
    const quat = @import("../math/quat.zig");

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    var physics = PhysicsState.init(std.testing.allocator);
    defer physics.deinit();

    _ = try world.createEntity(.{
        .name = "RotatedThinBox",
        .rigidbody = .{ .motion_type = .static },
        .box_collider = .{ .half_extents = .{ 1.0, 0.01, 0.5 } },
        .local_transform = .{
            .rotation = quat.fromAxisAngle(.{ 0.0, 0.0, 1.0 }, std.math.pi / 4.0),
        },
    });

    try std.testing.expect(physics.raycast(&world, .{
        .origin = .{ 0.7, -0.7, -2.0 },
        .direction = .{ 0.0, 0.0, 1.0 },
        .max_distance = 10.0,
    }, .{}) == null);

    const hits = try physics.overlapAabb(
        &world,
        std.testing.allocator,
        aabbFromCenterHalfExtents(.{ 0.7, -0.7, 0.0 }, .{ 0.05, 0.05, 0.05 }),
        .{},
    );
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}
