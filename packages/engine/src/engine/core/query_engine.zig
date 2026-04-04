const std = @import("std");
const components = @import("../scene/components.zig");
const world_mod = @import("../scene/world.zig");
const spatial_index_mod = @import("../scene/spatial_index.zig");
const aabb_mod = @import("../math/aabb.zig");

pub const EntityId = world_mod.EntityId;

pub const Filter = struct {
    id: ?EntityId = null,
    name_contains: ?[]const u8 = null,
    has_component: ?[]const u8 = null,
    has_components: ?[]const []const u8 = null,
    parent_id: ?EntityId = null,
    visible: ?bool = null,
    origin: ?components.Vec3 = null,
    radius: ?f32 = null,
    aabb_min: ?components.Vec3 = null,
    aabb_max: ?components.Vec3 = null,
    is_dynamic: ?bool = null,
    is_root: ?bool = null,
    has_collider: ?bool = null,
    has_rigidbody: ?bool = null,
    sort_by: ?SortBy = null,
    limit: usize = 50,
    offset: usize = 0,
    count_only: bool = false,

    pub const SortBy = enum {
        distance,
        name_asc,
        name_desc,
        id_asc,
    };

    pub fn normalized(self: Filter) Filter {
        var copy = self;
        if (copy.limit == 0) {
            copy.limit = 50;
        }
        if (copy.limit > 200) {
            copy.limit = 200;
        }
        if (copy.radius) |radius| {
            copy.radius = @max(radius, 0.0);
        }
        if (copy.aabb_min != null and copy.aabb_max != null) {
            const min_v = copy.aabb_min.?;
            const max_v = copy.aabb_max.?;
            copy.aabb_min = .{
                @min(min_v[0], max_v[0]),
                @min(min_v[1], max_v[1]),
                @min(min_v[2], max_v[2]),
            };
            copy.aabb_max = .{
                @max(min_v[0], max_v[0]),
                @max(min_v[1], max_v[1]),
                @max(min_v[2], max_v[2]),
            };
        }
        return copy;
    }
};

pub const ResultItem = struct {
    id: EntityId,
    name: []const u8,
    parent_id: ?EntityId = null,
    visible: bool,
    editor_only: bool,
    is_folder: bool,
    world_translation: components.Vec3,
    distance: ?f32 = null,
};

pub const ResultSet = struct {
    total: usize,
    offset: usize,
    limit: usize,
    count_only: bool,
    truncated: bool,
    items: []ResultItem,

    pub fn deinit(self: *ResultSet, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const SpatialIndices = struct {
    static_bvh: ?*const spatial_index_mod.StaticBoundsBvh = null,
    dynamic_bvh: ?*const spatial_index_mod.StaticBoundsBvh = null,
};

pub fn queryAlloc(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    filter_in: Filter,
    spatial: SpatialIndices,
) !ResultSet {
    const filter = filter_in.normalized();

    var items = std.ArrayList(ResultItem).empty;
    defer items.deinit(allocator);

    if (!filter.count_only) {
        try items.ensureTotalCapacity(allocator, filter.limit);
    }

    var total: usize = 0;

    const use_bvh = filter.aabb_min != null and filter.aabb_max != null and
        (spatial.static_bvh != null or spatial.dynamic_bvh != null);

    if (use_bvh) {
        const min_v = filter.aabb_min.?;
        const max_v = filter.aabb_max.?;
        const query_bounds = aabb_mod.AABB{
            .min = min_v,
            .max = max_v,
        };

        var candidate_set = std.AutoHashMap(EntityId, void).init(allocator);
        defer candidate_set.deinit();

        if (spatial.static_bvh) |bvh| {
            const candidates = try bvh.queryAabbCandidates(allocator, query_bounds);
            defer allocator.free(candidates);
            for (candidates) |id| {
                try candidate_set.put(id, {});
            }
        }
        if (spatial.dynamic_bvh) |bvh| {
            const candidates = try bvh.queryAabbCandidates(allocator, query_bounds);
            defer allocator.free(candidates);
            for (candidates) |id| {
                try candidate_set.put(id, {});
            }
        }

        for (world.entities.items) |entity| {
            if (!candidate_set.contains(entity.id)) continue;
            const world_translation = entityWorldTranslation(world, entity.id, entity.local_transform.translation);
            const distance = if (filter.origin) |origin| distanceBetween(origin, world_translation) else null;
            if (!matchesEntity(&entity, filter, world_translation, distance)) continue;

            total += 1;
            if (filter.count_only) continue;
            if (total <= filter.offset) continue;
            if (items.items.len >= filter.limit) continue;

            items.appendAssumeCapacity(.{
                .id = entity.id,
                .name = entity.name,
                .parent_id = entity.parent,
                .visible = entity.visible,
                .editor_only = entity.editor_only,
                .is_folder = entity.is_folder,
                .world_translation = world_translation,
                .distance = distance,
            });
        }
    } else {
        for (world.entities.items) |entity| {
            const world_translation = entityWorldTranslation(world, entity.id, entity.local_transform.translation);
            const distance = if (filter.origin) |origin| distanceBetween(origin, world_translation) else null;
            if (!matchesEntity(&entity, filter, world_translation, distance)) continue;

            total += 1;
            if (filter.count_only) continue;
            if (total <= filter.offset) continue;
            if (items.items.len >= filter.limit) continue;

            items.appendAssumeCapacity(.{
                .id = entity.id,
                .name = entity.name,
                .parent_id = entity.parent,
                .visible = entity.visible,
                .editor_only = entity.editor_only,
                .is_folder = entity.is_folder,
                .world_translation = world_translation,
                .distance = distance,
            });
        }
    }

    if (filter.sort_by) |sort_by| {
        sortItems(items.items, sort_by, filter.origin);
    }

    return .{
        .total = total,
        .offset = filter.offset,
        .limit = filter.limit,
        .count_only = filter.count_only,
        .truncated = !filter.count_only and total > filter.offset + items.items.len,
        .items = try items.toOwnedSlice(allocator),
    };
}

pub fn isComponentNameSupported(name: []const u8) bool {
    return componentTag(name) != null;
}

fn matchesEntity(
    entity: *const world_mod.Entity,
    filter: Filter,
    world_translation: components.Vec3,
    distance: ?f32,
) bool {
    if (filter.id) |id| {
        if (entity.id != id) return false;
    }
    if (filter.name_contains) |needle| {
        if (!containsIgnoreCase(entity.name, needle)) return false;
    }
    if (filter.has_component) |component_name| {
        if (!entityHasComponent(entity, component_name)) return false;
    }
    if (filter.has_components) |component_names| {
        for (component_names) |component_name| {
            if (!entityHasComponent(entity, component_name)) return false;
        }
    }
    if (filter.parent_id) |parent_id| {
        if (entity.parent != parent_id) return false;
    }
    if (filter.visible) |visible| {
        if (entity.visible != visible) return false;
    }
    if (filter.origin != null) {
        const radius = filter.radius orelse return false;
        const resolved_distance = distance orelse distanceBetween(filter.origin.?, world_translation);
        if (resolved_distance > radius) return false;
    }
    if (filter.aabb_min != null or filter.aabb_max != null) {
        const min_v = filter.aabb_min orelse return false;
        const max_v = filter.aabb_max orelse return false;
        if (world_translation[0] < min_v[0] or world_translation[0] > max_v[0]) return false;
        if (world_translation[1] < min_v[1] or world_translation[1] > max_v[1]) return false;
        if (world_translation[2] < min_v[2] or world_translation[2] > max_v[2]) return false;
    }
    if (filter.is_dynamic) |dynamic| {
        const has_rigidbody = entity.rigidbody != null;
        if (dynamic) {
            if (!has_rigidbody) return false;
        } else {
            if (has_rigidbody) return false;
        }
    }
    if (filter.is_root) |root| {
        const is_root_entity = entity.parent == null;
        if (root != is_root_entity) return false;
    }
    if (filter.has_collider) |has_collider| {
        const has_any_collider = entity.box_collider != null or
            entity.sphere_collider != null or
            entity.mesh_collider != null;
        if (has_collider != has_any_collider) return false;
    }
    if (filter.has_rigidbody) |has_rb| {
        if (has_rb != (entity.rigidbody != null)) return false;
    }
    return true;
}

fn entityWorldTranslation(
    world: *const world_mod.World,
    entity_id: EntityId,
    fallback: components.Vec3,
) components.Vec3 {
    const world_transform = world.worldTransformConst(entity_id) orelse return fallback;
    return world_transform.translation;
}

fn distanceBetween(a: components.Vec3, b: components.Vec3) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    const dz = a[2] - b[2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) {
        return true;
    }
    if (needle.len > haystack.len) {
        return false;
    }
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) {
            return true;
        }
    }
    return false;
}

fn entityHasComponent(entity: *const world_mod.Entity, component_name: []const u8) bool {
    const tag = componentTag(component_name) orelse return false;
    return switch (tag) {
        .camera => entity.camera != null,
        .mesh => entity.mesh != null,
        .skinned_mesh => entity.skinned_mesh != null,
        .animator => entity.animator != null,
        .rigidbody => entity.rigidbody != null,
        .box_collider => entity.box_collider != null,
        .sphere_collider => entity.sphere_collider != null,
        .mesh_collider => entity.mesh_collider != null,
        .constraint => entity.constraint != null,
        .material => entity.material != null,
        .light => entity.light != null,
        .vfx => entity.vfx != null,
        .script => entity.script != null,
    };
}

const ComponentTag = enum {
    camera,
    mesh,
    skinned_mesh,
    animator,
    rigidbody,
    box_collider,
    sphere_collider,
    mesh_collider,
    constraint,
    material,
    light,
    vfx,
    script,
};

fn componentTag(name: []const u8) ?ComponentTag {
    if (std.mem.eql(u8, name, "camera")) return .camera;
    if (std.mem.eql(u8, name, "mesh")) return .mesh;
    if (std.mem.eql(u8, name, "skinned_mesh")) return .skinned_mesh;
    if (std.mem.eql(u8, name, "animator")) return .animator;
    if (std.mem.eql(u8, name, "rigidbody")) return .rigidbody;
    if (std.mem.eql(u8, name, "box_collider")) return .box_collider;
    if (std.mem.eql(u8, name, "sphere_collider")) return .sphere_collider;
    if (std.mem.eql(u8, name, "mesh_collider")) return .mesh_collider;
    if (std.mem.eql(u8, name, "constraint")) return .constraint;
    if (std.mem.eql(u8, name, "material")) return .material;
    if (std.mem.eql(u8, name, "light")) return .light;
    if (std.mem.eql(u8, name, "vfx")) return .vfx;
    if (std.mem.eql(u8, name, "script")) return .script;
    return null;
}

fn sortItems(items: []ResultItem, sort_by: Filter.SortBy, origin: ?components.Vec3) void {
    switch (sort_by) {
        .distance => {
            if (origin == null) return;
            std.sort.block(ResultItem, items, origin.?, struct {
                fn lessThan(ctx: components.Vec3, a: ResultItem, b: ResultItem) bool {
                    const dist_a = a.distance orelse distanceBetween(ctx, a.world_translation);
                    const dist_b = b.distance orelse distanceBetween(ctx, b.world_translation);
                    return dist_a < dist_b;
                }
            }.lessThan);
        },
        .name_asc => {
            std.sort.block(ResultItem, items, {}, struct {
                fn lessThan(_: void, a: ResultItem, b: ResultItem) bool {
                    return std.mem.order(u8, a.name, b.name) == .lt;
                }
            }.lessThan);
        },
        .name_desc => {
            std.sort.block(ResultItem, items, {}, struct {
                fn lessThan(_: void, a: ResultItem, b: ResultItem) bool {
                    return std.mem.order(u8, a.name, b.name) == .gt;
                }
            }.lessThan);
        },
        .id_asc => {
            std.sort.block(ResultItem, items, {}, struct {
                fn lessThan(_: void, a: ResultItem, b: ResultItem) bool {
                    return a.id < b.id;
                }
            }.lessThan);
        },
    }
}

test "QueryEngine filters by component and paginates results" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    _ = try world.createEntity(.{ .name = "Camera", .camera = .{} });
    _ = try world.createEntity(.{ .name = "Tree A", .mesh = .{ .primitive = .cube } });
    _ = try world.createEntity(.{ .name = "Tree B", .mesh = .{ .primitive = .sphere } });
    world.updateHierarchy();

    var result = try queryAlloc(std.testing.allocator, &world, .{
        .has_component = "mesh",
        .limit = 1,
        .offset = 0,
    }, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.total);
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqualStrings("Tree A", result.items[0].name);
}

test "QueryEngine supports radius filters and count_only mode" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    _ = try world.createEntity(.{
        .name = "NearLight",
        .local_transform = .{ .translation = .{ 1.0, 0.0, 0.0 } },
        .light = .{},
    });
    _ = try world.createEntity(.{
        .name = "FarLight",
        .local_transform = .{ .translation = .{ 10.0, 0.0, 0.0 } },
        .light = .{},
    });
    world.updateHierarchy();

    var result = try queryAlloc(std.testing.allocator, &world, .{
        .has_component = "light",
        .origin = .{ 0.0, 0.0, 0.0 },
        .radius = 2.0,
        .count_only = true,
    }, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.total);
    try std.testing.expectEqual(@as(usize, 0), result.items.len);
    try std.testing.expect(!result.truncated);
}

test "QueryEngine supports AABB filters" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    _ = try world.createEntity(.{
        .name = "Inside",
        .local_transform = .{ .translation = .{ 1.0, 2.0, 3.0 } },
    });
    _ = try world.createEntity(.{
        .name = "Outside",
        .local_transform = .{ .translation = .{ 20.0, 2.0, 3.0 } },
    });
    world.updateHierarchy();

    var result = try queryAlloc(std.testing.allocator, &world, .{
        .aabb_min = .{ 0.0, 0.0, 0.0 },
        .aabb_max = .{ 10.0, 10.0, 10.0 },
        .limit = 10,
        .offset = 0,
    }, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.total);
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings("Inside", result.items[0].name);
}
