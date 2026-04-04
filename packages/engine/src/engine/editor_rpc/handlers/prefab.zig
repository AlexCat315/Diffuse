///! handlers/prefab.zig — Prefab library inspection, editing & management.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

const prefab_mod = @import("../../scene/prefab.zig");
const PrefabResource = prefab_mod.PrefabResource;
const PrefabEntityData = prefab_mod.PrefabEntityData;

// ── helpers ─────────────────────────────────────────────────────

fn appendJsonEscaped(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => try buf.append(a, c),
        }
    }
}

fn appendNumber(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: anytype) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{}", .{v}) catch "0";
    try buf.appendSlice(a, s);
}

fn appendFloat(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: f32) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d:.6}", .{@as(f64, v)}) catch "0";
    try buf.appendSlice(a, s);
}

// ── RPC handlers ────────────────────────────────────────────────

/// List all prefabs in the library.
pub fn list(ctx: *Ctx) !void {
    const world = ctx.layer.world;
    const a = ctx.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"prefabs\":[");

    var first = true;
    var it = world.prefab_library.prefabs.iterator();
    while (it.next()) |entry| {
        const prefab: *PrefabResource = entry.value_ptr.*;
        if (!first) try buf.appendSlice(a, ",");
        first = false;

        try buf.appendSlice(a, "{\"id\":\"");
        try appendJsonEscaped(&buf, a, prefab.id);
        try buf.appendSlice(a, "\",\"name\":\"");
        try appendJsonEscaped(&buf, a, prefab.name);
        try buf.appendSlice(a, "\",\"version\":");
        try appendNumber(&buf, a, prefab.version);
        try buf.appendSlice(a, ",\"entityCount\":");
        try appendNumber(&buf, a, prefab.entities.len);
        if (prefab.source_path) |sp| {
            try buf.appendSlice(a, ",\"sourcePath\":\"");
            try appendJsonEscaped(&buf, a, sp);
            try buf.appendSlice(a, "\"");
        }
        try buf.appendSlice(a, "}");
    }

    try buf.appendSlice(a, "]}");
    ctx.replyRaw(try buf.toOwnedSlice(a));
}

/// Get entity hierarchy for a specific prefab.
pub fn getEntities(ctx: *Ctx) !void {
    const prefab_id = try ctx.param([]const u8, "prefabId");
    const world = ctx.layer.world;
    const a = ctx.allocator;

    const prefab = world.prefab_library.getPrefab(prefab_id) orelse {
        try ctx.reply(.{ .found = false, .entities = &[0]u8{} });
        return;
    };

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"found\":true,\"entities\":[");

    for (prefab.entities, 0..) |entity, i| {
        if (i > 0) try buf.appendSlice(a, ",");
        try buf.appendSlice(a, "{\"prefabEntityId\":");
        try appendNumber(&buf, a, entity.prefab_entity_id);
        try buf.appendSlice(a, ",\"name\":\"");
        try appendJsonEscaped(&buf, a, entity.name);
        try buf.appendSlice(a, "\"");

        // parentId
        if (entity.parent) |pid| {
            try buf.appendSlice(a, ",\"parentId\":");
            try appendNumber(&buf, a, pid);
        }

        try buf.appendSlice(a, ",\"visible\":");
        try buf.appendSlice(a, if (entity.visible) "true" else "false");
        try buf.appendSlice(a, ",\"isFolder\":");
        try buf.appendSlice(a, if (entity.is_folder) "true" else "false");

        // component flags
        try buf.appendSlice(a, ",\"hasTransform\":true");
        try buf.appendSlice(a, ",\"hasMesh\":");
        try buf.appendSlice(a, if (entity.mesh != null) "true" else "false");
        try buf.appendSlice(a, ",\"hasMaterial\":");
        try buf.appendSlice(a, if (entity.material != null) "true" else "false");
        try buf.appendSlice(a, ",\"hasLight\":");
        try buf.appendSlice(a, if (entity.light != null) "true" else "false");
        try buf.appendSlice(a, ",\"hasCamera\":");
        try buf.appendSlice(a, if (entity.camera != null) "true" else "false");
        try buf.appendSlice(a, ",\"hasScript\":");
        try buf.appendSlice(a, if (entity.script != null) "true" else "false");
        try buf.appendSlice(a, ",\"hasVfx\":");
        try buf.appendSlice(a, if (entity.vfx != null) "true" else "false");

        try buf.appendSlice(a, "}");
    }

    try buf.appendSlice(a, "]}");
    ctx.replyRaw(try buf.toOwnedSlice(a));
}

/// Get detailed info for a specific entity within a prefab.
pub fn getEntityDetail(ctx: *Ctx) !void {
    const prefab_id = try ctx.param([]const u8, "prefabId");
    const entity_id: u32 = @intCast(try ctx.param(u64, "prefabEntityId"));
    const world = ctx.layer.world;
    const a = ctx.allocator;

    const prefab = world.prefab_library.getPrefab(prefab_id) orelse {
        try ctx.reply(.{ .found = false });
        return;
    };

    // Find entity
    var found_entity: ?*const PrefabEntityData = null;
    for (prefab.entities) |*entity| {
        if (entity.prefab_entity_id == entity_id) {
            found_entity = entity;
            break;
        }
    }

    const entity = found_entity orelse {
        try ctx.reply(.{ .found = false });
        return;
    };

    // Build components list
    var components = std.ArrayList(u8).empty;
    defer components.deinit(a);
    try components.appendSlice(a, "[");
    var first_comp = true;

    const comp_checks = .{
        .{ entity.camera != null, "Camera" },
        .{ entity.mesh != null, "Mesh" },
        .{ entity.material != null, "Material" },
        .{ entity.light != null, "Light" },
        .{ entity.rigidbody != null, "Rigidbody" },
        .{ entity.box_collider != null, "BoxCollider" },
        .{ entity.sphere_collider != null, "SphereCollider" },
        .{ entity.mesh_collider != null, "MeshCollider" },
        .{ entity.vfx != null, "Vfx" },
        .{ entity.script != null, "Script" },
        .{ entity.animator != null, "Animator" },
    };

    inline for (comp_checks) |check| {
        if (check[0]) {
            if (!first_comp) try components.appendSlice(a, ",");
            first_comp = false;
            try components.appendSlice(a, "\"");
            try components.appendSlice(a, check[1]);
            try components.appendSlice(a, "\"");
        }
    }

    try components.appendSlice(a, "]");

    // Build full response
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"found\":true,\"entity\":{");
    try buf.appendSlice(a, "\"prefabEntityId\":");
    try appendNumber(&buf, a, entity.prefab_entity_id);
    try buf.appendSlice(a, ",\"name\":\"");
    try appendJsonEscaped(&buf, a, entity.name);
    try buf.appendSlice(a, "\",\"visible\":");
    try buf.appendSlice(a, if (entity.visible) "true" else "false");
    try buf.appendSlice(a, ",\"isFolder\":");
    try buf.appendSlice(a, if (entity.is_folder) "true" else "false");

    // Transform
    const t = entity.local_transform;
    try buf.appendSlice(a, ",\"posX\":");
    try appendFloat(&buf, a, t.translation[0]);
    try buf.appendSlice(a, ",\"posY\":");
    try appendFloat(&buf, a, t.translation[1]);
    try buf.appendSlice(a, ",\"posZ\":");
    try appendFloat(&buf, a, t.translation[2]);
    try buf.appendSlice(a, ",\"rotX\":");
    try appendFloat(&buf, a, t.rotation[0]);
    try buf.appendSlice(a, ",\"rotY\":");
    try appendFloat(&buf, a, t.rotation[1]);
    try buf.appendSlice(a, ",\"rotZ\":");
    try appendFloat(&buf, a, t.rotation[2]);
    try buf.appendSlice(a, ",\"rotW\":");
    try appendFloat(&buf, a, t.rotation[3]);
    try buf.appendSlice(a, ",\"scaleX\":");
    try appendFloat(&buf, a, t.scale[0]);
    try buf.appendSlice(a, ",\"scaleY\":");
    try appendFloat(&buf, a, t.scale[1]);
    try buf.appendSlice(a, ",\"scaleZ\":");
    try appendFloat(&buf, a, t.scale[2]);

    try buf.appendSlice(a, ",\"components\":");
    try buf.appendSlice(a, components.items);

    try buf.appendSlice(a, "}}");
    ctx.replyRaw(try buf.toOwnedSlice(a));
}

/// Update transform fields of a prefab entity.
pub fn setEntityTransform(ctx: *Ctx) !void {
    const prefab_id = try ctx.param([]const u8, "prefabId");
    const entity_id: u32 = @intCast(try ctx.param(u64, "prefabEntityId"));
    const world = ctx.layer.world;

    const prefab = world.prefab_library.getPrefab(prefab_id) orelse
        return error.InvalidArguments;

    var found: ?*PrefabEntityData = null;
    for (prefab.entities) |*entity| {
        if (entity.prefab_entity_id == entity_id) {
            found = entity;
            break;
        }
    }

    const entity = found orelse return error.InvalidArguments;

    if (try ctx.paramOpt(f64, "posX")) |v| entity.local_transform.translation[0] = @floatCast(v);
    if (try ctx.paramOpt(f64, "posY")) |v| entity.local_transform.translation[1] = @floatCast(v);
    if (try ctx.paramOpt(f64, "posZ")) |v| entity.local_transform.translation[2] = @floatCast(v);
    if (try ctx.paramOpt(f64, "rotX")) |v| entity.local_transform.rotation[0] = @floatCast(v);
    if (try ctx.paramOpt(f64, "rotY")) |v| entity.local_transform.rotation[1] = @floatCast(v);
    if (try ctx.paramOpt(f64, "rotZ")) |v| entity.local_transform.rotation[2] = @floatCast(v);
    if (try ctx.paramOpt(f64, "rotW")) |v| entity.local_transform.rotation[3] = @floatCast(v);
    if (try ctx.paramOpt(f64, "scaleX")) |v| entity.local_transform.scale[0] = @floatCast(v);
    if (try ctx.paramOpt(f64, "scaleY")) |v| entity.local_transform.scale[1] = @floatCast(v);
    if (try ctx.paramOpt(f64, "scaleZ")) |v| entity.local_transform.scale[2] = @floatCast(v);

    try ctx.reply(.{ .success = true });
}

/// Set a simple field on a prefab entity (name, visible, isFolder).
pub fn setEntityField(ctx: *Ctx) !void {
    const prefab_id = try ctx.param([]const u8, "prefabId");
    const entity_id: u32 = @intCast(try ctx.param(u64, "prefabEntityId"));
    const field = try ctx.param([]const u8, "field");
    const value = try ctx.param([]const u8, "value");
    const world = ctx.layer.world;

    const prefab = world.prefab_library.getPrefab(prefab_id) orelse
        return error.InvalidArguments;

    var found: ?*PrefabEntityData = null;
    for (prefab.entities) |*entity| {
        if (entity.prefab_entity_id == entity_id) {
            found = entity;
            break;
        }
    }

    const entity = found orelse return error.InvalidArguments;

    if (std.mem.eql(u8, field, "name")) {
        const alloc = world.allocator;
        alloc.free(entity.name);
        entity.name = try alloc.dupe(u8, value);
    } else if (std.mem.eql(u8, field, "visible")) {
        entity.visible = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, field, "isFolder")) {
        entity.is_folder = std.mem.eql(u8, value, "true");
    } else {
        return error.InvalidArguments;
    }

    try ctx.reply(.{ .success = true });
}

/// Create a prefab from a scene entity.
pub fn create(ctx: *Ctx) !void {
    const entity_id = try ctx.param(u64, "entityId");
    const name = try ctx.param([]const u8, "name");

    // Generate prefab ID
    var id_buf: [256]u8 = undefined;
    const prefab_id = std.fmt.bufPrint(&id_buf, "prefab://assets/prefabs/{s}/v1", .{name}) catch
        return error.InvalidArguments;

    try ctx.layer.world.createPrefab(entity_id, prefab_id);
    try ctx.reply(.{ .success = true, .prefabId = prefab_id });
}

/// Instantiate a prefab into the scene.
pub fn instantiate(ctx: *Ctx) !void {
    const prefab_id = try ctx.param([]const u8, "prefabId");
    const world = ctx.layer.world;

    const pos_x: f32 = if (try ctx.paramOpt(f64, "posX")) |v| @floatCast(v) else 0;
    const pos_y: f32 = if (try ctx.paramOpt(f64, "posY")) |v| @floatCast(v) else 0;
    const pos_z: f32 = if (try ctx.paramOpt(f64, "posZ")) |v| @floatCast(v) else 0;

    const eid = try world.instantiatePrefab(prefab_id, .{
        .transform = .{
            .translation = .{ pos_x, pos_y, pos_z },
        },
    });

    try ctx.reply(.{ .success = true, .entityId = eid });
}

/// Save a prefab to its default path.
pub fn save(ctx: *Ctx) !void {
    const prefab_id = try ctx.param([]const u8, "prefabId");
    const world = ctx.layer.world;

    // Build path from prefab name
    const prefab = world.prefab_library.getPrefab(prefab_id) orelse
        return error.InvalidArguments;

    // Use existing source_path or generate one
    if (prefab.source_path) |sp| {
        try world.savePrefab(prefab_id, sp);
    } else {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "assets/prefabs/{s}.prefab.json", .{prefab.name}) catch
            return error.InvalidArguments;
        try world.savePrefab(prefab_id, path);
    }

    try ctx.reply(.{ .success = true });
}

/// Delete a prefab from the library.
pub fn delete(ctx: *Ctx) !void {
    const prefab_id = try ctx.param([]const u8, "prefabId");
    try ctx.layer.world.removePrefab(prefab_id);
    try ctx.reply(.{ .success = true });
}
