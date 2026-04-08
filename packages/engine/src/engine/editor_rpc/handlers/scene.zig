///! handlers/scene.zig — scene hierarchy & entity lifecycle.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const scene_io = @import("../../scene/scene_io.zig");
const components = @import("../../scene/components.zig");
const query_engine = @import("../../core/query_engine.zig");
const Ctx = ctx_mod.Ctx;
const World = ctx_mod.World;
const EntityId = ctx_mod.EntityId;

pub fn getHierarchy(ctx: *Ctx) !void {
    const world = ctx.layer.world;
    var roots = std.ArrayList(EntityNodeJson).empty;
    defer {
        for (roots.items) |*node| freeEntityNode(ctx.allocator, node);
        roots.deinit(ctx.allocator);
    }

    for (world.entities.items) |entity| {
        if (entity.parent == null) {
            const node = buildEntityNode(ctx.allocator, world, entity.id) catch continue;
            try roots.append(ctx.allocator, node);
        }
    }
    try ctx.reply(.{ .roots = roots.items });
}

pub fn createEntity(ctx: *Ctx) !void {
    const name_str = (try ctx.paramOpt([]const u8, "name")) orelse "New Entity";
    const owned = try ctx.layer.world.allocator.dupe(u8, name_str);
    const eid = try ctx.layer.world.createEntity(.{ .name = owned });
    try ctx.reply(.{ .entityId = eid });
}

pub fn deleteEntity(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    _ = ctx.layer.world.destroyEntity(eid);
    try ctx.reply(.{});
}

pub fn duplicateEntity(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntityConst(eid) orelse return error.EntityNotFound;

    const copy_name = try std.fmt.allocPrint(ctx.allocator, "{s} (Copy)", .{entity.name});
    defer ctx.allocator.free(copy_name);

    const owned = try ctx.layer.world.allocator.dupe(u8, copy_name);
    const new_id = try ctx.layer.world.createEntity(.{
        .name = owned,
        .parent = entity.parent,
        .local_transform = entity.local_transform,
    });
    try ctx.reply(.{ .entityId = new_id });
}

const fallback_scene_rel = "assets/scenes/editor_autosave.guava_scene";

pub fn save(ctx: *Ctx) !void {
    const explicit = try ctx.paramOpt([]const u8, "path");
    const path = explicit orelse
        if (ctx.layer.scene_manager) |sm| sm.current_scene_path orelse null else null;

    // If we have a path (either explicit or from scene_manager), use it directly.
    // Otherwise, build fallback as absolute path under project root (or CWD).
    var fallback_buf: [512]u8 = undefined;
    const final_path = path orelse blk: {
        if (ctx.project_root) |root| {
            break :blk std.fmt.bufPrint(&fallback_buf, "{s}/{s}", .{ root, fallback_scene_rel }) catch fallback_scene_rel;
        }
        break :blk fallback_scene_rel;
    };

    // Capture revision *before* saving so the frontend knows exactly which
    // version was persisted (avoids race if scene changes during I/O).
    const saved_revision = ctx.layer.world.sceneRevision();
    scene_io.saveWorldToPath(ctx.allocator, ctx.layer.world, final_path) catch |e| {
        std.log.err("scene.save failed: {}", .{e});
        return error.InternalError;
    };
    try ctx.reply(.{ .path = final_path, .revision = saved_revision });
}

pub fn load(ctx: *Ctx) !void {
    const path = try ctx.param([]const u8, "path");

    // If path is relative and we have a project root, resolve to absolute.
    var abs_buf: [512]u8 = undefined;
    const resolved_path = if (!std.fs.path.isAbsolute(path)) blk: {
        if (ctx.project_root) |root| {
            break :blk std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ root, path }) catch path;
        }
        break :blk path;
    } else path;

    scene_io.loadWorldFromPath(ctx.allocator, ctx.layer.world, resolved_path) catch |e| {
        std.log.err("scene.load failed: {}", .{e});
        return error.InternalError;
    };
    // Track the loaded path so scene.save can write back to the same file.
    if (ctx.layer.scene_manager) |sm| {
        sm.setCurrentScenePath(resolved_path) catch {};
    }
    ctx.layer.world.markSceneChanged();
    try ctx.reply(.{ .path = resolved_path });
}

pub fn listScenes(ctx: *Ctx) !void {
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(ctx.allocator);

    // Try project-relative scenes directories, then fall back to CWD.
    const scene_dirs = [_][]const u8{ "Content/Scenes", "assets/scenes" };

    var owned_base: ?std.fs.Dir = if (ctx.project_root) |root|
        (std.fs.openDirAbsolute(root, .{}) catch null)
    else
        null;
    defer if (owned_base) |*d| d.close();
    const base_dir: std.fs.Dir = owned_base orelse std.fs.cwd();

    var found = false;
    for (scene_dirs) |scene_rel| {
        var dir = base_dir.openDir(scene_rel, .{ .iterate = true }) catch continue;
        defer dir.close();
        found = true;

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.endsWith(u8, entry.name, ".guava_scene") or
                std.mem.endsWith(u8, entry.name, ".json"))
            {
                // Return full relative path so scene.load can resolve it.
                const full_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ scene_rel, entry.name });
                try names.append(ctx.allocator, full_path);
            }
        }
        break; // Use the first directory that exists.
    }

    if (!found) {
        try ctx.reply(.{ .scenes = @as([]const []const u8, &.{}) });
        return;
    }

    try ctx.reply(.{ .scenes = names.items });
    for (names.items) |n| ctx.allocator.free(n);
}

pub fn spawnActor(ctx: *Ctx) !void {
    const kind = try ctx.param([]const u8, "kind");
    const world = ctx.layer.world;
    const transform = components.Transform.identity();

    const entity_id: u64 = if (std.mem.eql(u8, kind, "empty"))
        try world.createEmptyEntity(transform)
    else if (std.mem.eql(u8, kind, "camera"))
        try world.createCameraEntity(transform)
    else if (std.mem.eql(u8, kind, "cube"))
        try world.createPrimitiveEntity(.cube, transform)
    else if (std.mem.eql(u8, kind, "sphere"))
        try world.createPrimitiveEntity(.sphere, transform)
    else if (std.mem.eql(u8, kind, "plane"))
        try world.createPrimitiveEntity(.plane, transform)
    else if (std.mem.eql(u8, kind, "point_light"))
        try world.createLightEntity(.point, transform, 24.0)
    else if (std.mem.eql(u8, kind, "spot_light"))
        try world.createLightEntity(.spot, transform, 24.0)
    else if (std.mem.eql(u8, kind, "directional_light"))
        try world.createLightEntity(.directional, transform, 3.0)
    else if (std.mem.eql(u8, kind, "vfx_fountain"))
        try world.createVfxEntity(.fountain, transform)
    else if (std.mem.eql(u8, kind, "vfx_orbit"))
        try world.createVfxEntity(.orbit, transform)
    else
        return error.InvalidArguments;

    try ctx.reply(.{ .entityId = entity_id });
}

pub fn queryEntities(ctx: *Ctx) !void {
    const world = ctx.layer.world;

    var origin: ?components.Vec3 = null;
    if (try ctx.paramOpt(f32, "originX")) |ox| {
        const oy = (try ctx.paramOpt(f32, "originY")) orelse 0;
        const oz = (try ctx.paramOpt(f32, "originZ")) orelse 0;
        origin = .{ ox, oy, oz };
    }

    const filter = query_engine.Filter{
        .name_contains = try ctx.paramOpt([]const u8, "nameContains"),
        .has_component = try ctx.paramOpt([]const u8, "hasComponent"),
        .parent_id = try ctx.paramOpt(u64, "parentId"),
        .visible = try ctx.paramOpt(bool, "visible"),
        .is_root = try ctx.paramOpt(bool, "isRoot"),
        .origin = origin,
        .radius = try ctx.paramOpt(f32, "radius"),
        .limit = if (try ctx.paramOpt(u32, "limit")) |l| @intCast(l) else 50,
        .offset = if (try ctx.paramOpt(u32, "offset")) |o| @intCast(o) else 0,
        .count_only = (try ctx.paramOpt(bool, "countOnly")) orelse false,
    };

    var result = try query_engine.queryAlloc(ctx.allocator, world, filter, .{
        .static_bvh = if (world.renderable_spatial_index) |*idx| idx else null,
        .dynamic_bvh = if (world.dynamic_renderable_spatial_index) |*idx| idx else null,
    });
    defer result.deinit(ctx.allocator);

    const Item = struct {
        id: u64,
        name: []const u8,
        parentId: ?u64 = null,
        visible: bool,
        worldX: f32,
        worldY: f32,
        worldZ: f32,
    };
    var items = try ctx.allocator.alloc(Item, result.items.len);
    defer ctx.allocator.free(items);

    for (result.items, 0..) |item, i| {
        items[i] = .{
            .id = item.id,
            .name = item.name,
            .parentId = item.parent_id,
            .visible = item.visible,
            .worldX = item.world_translation[0],
            .worldY = item.world_translation[1],
            .worldZ = item.world_translation[2],
        };
    }

    try ctx.reply(.{ .total = result.total, .items = items });
}

// ── Helpers (scene-domain only) ─────────────────────────────────

const EntityNodeJson = struct {
    id: u64,
    name: []const u8,
    visible: bool,
    selectable: bool,
    children: []EntityNodeJson,
};

fn freeEntityNode(allocator: std.mem.Allocator, node: *EntityNodeJson) void {
    for (node.children) |*child| freeEntityNode(allocator, @constCast(child));
    allocator.free(node.children);
}

fn buildEntityNode(allocator: std.mem.Allocator, world: *World, entity_id: EntityId) !EntityNodeJson {
    const entity = world.getEntityConst(entity_id) orelse return error.EntityNotFound;
    var children_list = std.ArrayList(EntityNodeJson).empty;
    defer children_list.deinit(allocator);

    for (entity.children.items) |child_id| {
        const child_node = buildEntityNode(allocator, world, child_id) catch continue;
        try children_list.append(allocator, child_node);
    }

    return .{
        .id = entity_id,
        .name = entity.name,
        .visible = entity.visible,
        .selectable = entity.selectable,
        .children = try children_list.toOwnedSlice(allocator),
    };
}
