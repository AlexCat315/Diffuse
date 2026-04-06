///! handlers/scene.zig — scene hierarchy & entity lifecycle.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const scene_io = @import("../../scene/scene_io.zig");
const components = @import("../../scene/components.zig");
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

const fallback_scene_path = "assets/scenes/editor_autosave.guava_scene";

pub fn save(ctx: *Ctx) !void {
    const explicit = try ctx.paramOpt([]const u8, "path");
    const path = explicit orelse
        if (ctx.layer.scene_manager) |sm| sm.current_scene_path orelse fallback_scene_path else fallback_scene_path;
    scene_io.saveWorldToPath(ctx.allocator, ctx.layer.world, path) catch |e| {
        std.log.err("scene.save failed: {}", .{e});
        return error.InternalError;
    };
    try ctx.reply(.{ .path = path });
}

pub fn load(ctx: *Ctx) !void {
    const path = try ctx.param([]const u8, "path");
    scene_io.loadWorldFromPath(ctx.allocator, ctx.layer.world, path) catch |e| {
        std.log.err("scene.load failed: {}", .{e});
        return error.InternalError;
    };
    // Track the loaded path so scene.save can write back to the same file.
    if (ctx.layer.scene_manager) |sm| {
        sm.setCurrentScenePath(path) catch {};
    }
    ctx.layer.world.markSceneChanged();
    try ctx.reply(.{ .path = path });
}

pub fn listScenes(ctx: *Ctx) !void {
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(ctx.allocator);

    const scenes_dir = std.fs.cwd().openDir("assets/scenes", .{ .iterate = true }) catch {
        try ctx.reply(.{ .scenes = @as([]const []const u8, &.{}) });
        return;
    };

    var iter = scenes_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".guava_scene") or
            std.mem.endsWith(u8, entry.name, ".json"))
        {
            const owned = try ctx.allocator.dupe(u8, entry.name);
            try names.append(ctx.allocator, owned);
        }
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

// ── Helpers (scene-domain only) ─────────────────────────────────

const EntityNodeJson = struct {
    id: u64,
    name: []const u8,
    visible: bool,
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
        .children = try children_list.toOwnedSlice(allocator),
    };
}
