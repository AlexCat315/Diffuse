///! handlers/entity.zig — per-entity inspection & mutation.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const EntityId = ctx_mod.EntityId;
const handles = @import("../../assets/handles.zig");
const library_mod = @import("../../assets/library.zig");

pub fn getTransform(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntityConst(eid) orelse return error.EntityNotFound;
    const t = entity.local_transform;
    try ctx.reply(.{
        .position = .{ .x = t.translation[0], .y = t.translation[1], .z = t.translation[2] },
        .rotation = .{ .x = t.rotation[0], .y = t.rotation[1], .z = t.rotation[2], .w = t.rotation[3] },
        .scale = .{ .x = t.scale[0], .y = t.scale[1], .z = t.scale[2] },
    });
}

pub fn setTransform(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntity(eid) orelse return error.EntityNotFound;

    const t_obj = try ctx.paramObj("transform");
    if (t_obj.get("position")) |pos| {
        if (ctx_mod.readVec3(pos)) |v| entity.local_transform.translation = v;
    }
    if (t_obj.get("rotation")) |rot| {
        if (ctx_mod.readQuat(rot)) |q| entity.local_transform.rotation = q;
    }
    if (t_obj.get("scale")) |scale| {
        if (ctx_mod.readVec3(scale)) |v| entity.local_transform.scale = v;
    }
    ctx.layer.world.markDirty(eid);
    try ctx.reply(.{});
}

pub fn setName(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const name = try ctx.param([]const u8, "name");
    const entity = ctx.layer.world.getEntity(eid) orelse return error.EntityNotFound;

    ctx.layer.world.allocator.free(entity.name);
    entity.name = try ctx.layer.world.allocator.dupe(u8, name);
    ctx.layer.world.markSceneChanged();
    try ctx.reply(.{});
}

pub fn getComponents(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntityConst(eid) orelse return error.EntityNotFound;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(ctx.allocator);

    try appendSlice(&buf, ctx.allocator, "{\"components\":[");
    var first_comp = true;

    inline for (ctx_mod.component_fields) |cf| {
        if (@field(entity, cf.name)) |*comp| {
            if (!first_comp) try appendSlice(&buf, ctx.allocator, ",");
            first_comp = false;
            try appendSlice(&buf, ctx.allocator, "{\"type\":\"");
            try appendSlice(&buf, ctx.allocator, cf.display_name);
            try appendSlice(&buf, ctx.allocator, "\",\"fields\":[");
            try serializeFields(&buf, ctx.allocator, @TypeOf(comp.*), comp, &ctx.layer.world.resources);
            try appendSlice(&buf, ctx.allocator, "]}");
        }
    }

    try appendSlice(&buf, ctx.allocator, "]}");
    ctx.replyRaw(try buf.toOwnedSlice(ctx.allocator));
}

pub fn setComponentField(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const comp_type = try ctx.param([]const u8, "componentType");
    const field_name = try ctx.param([]const u8, "fieldName");
    const p = ctx.params orelse return error.InvalidArguments;
    const raw_val = p.object.get("value") orelse return error.InvalidArguments;

    const entity = ctx.layer.world.getEntity(eid) orelse return error.EntityNotFound;

    var found = false;
    inline for (ctx_mod.component_fields) |cf| {
        if (std.ascii.eqlIgnoreCase(comp_type, cf.display_name)) {
            if (@field(entity, cf.name)) |*comp| {
                found = setField(@TypeOf(comp.*), comp, field_name, raw_val) catch false;
            }
        }
    }

    if (!found) return error.InvalidArguments;
    ctx.layer.world.markSceneChanged();
    try ctx.reply(.{});
}

pub fn addComponent(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const comp_type = try ctx.param([]const u8, "componentType");
    const entity = ctx.layer.world.getEntity(eid) orelse return error.EntityNotFound;

    var found = false;
    inline for (ctx_mod.component_fields) |cf| {
        if (std.ascii.eqlIgnoreCase(comp_type, cf.display_name)) {
            const FT = @TypeOf(@field(entity.*, cf.name));
            // FT is ?ComponentType — inner type must be default-initializable
            if (comptime canDefaultInit(@typeInfo(FT).optional.child)) {
                @field(entity, cf.name) = .{};
                found = true;
            }
        }
    }

    if (!found) return error.InvalidArguments;
    ctx.layer.world.markSceneChanged();
    try ctx.reply(.{});
}

pub fn removeComponent(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const comp_type = try ctx.param([]const u8, "componentType");
    const entity = ctx.layer.world.getEntity(eid) orelse return error.EntityNotFound;

    var found = false;
    inline for (ctx_mod.component_fields) |cf| {
        if (std.ascii.eqlIgnoreCase(comp_type, cf.display_name)) {
            @field(entity, cf.name) = null;
            found = true;
        }
    }

    if (!found) return error.InvalidArguments;
    ctx.layer.world.markSceneChanged();
    try ctx.reply(.{});
}

/// Set an asset-reference field on a component by asset path.
///
/// Params: entityId, componentType, fieldName, assetPath (string or null)
///
/// The engine resolves the asset path to an internal resource handle.
pub fn setAssetField(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const comp_type = try ctx.param([]const u8, "componentType");
    const field_name = try ctx.param([]const u8, "fieldName");
    const p = ctx.params orelse return error.InvalidArguments;
    // assetPath may be a string, null, or absent (all treated as "clear the field")
    const raw_val = p.object.get("assetPath") orelse std.json.Value.null;

    const entity = ctx.layer.world.getEntity(eid) orelse {
        std.log.warn("setAssetField: entity {d} not found", .{eid});
        return error.EntityNotFound;
    };
    const resources = &ctx.layer.world.resources;

    var found = false;
    var comp_type_matched = false;
    inline for (ctx_mod.component_fields) |cf| {
        if (std.ascii.eqlIgnoreCase(comp_type, cf.display_name)) {
            comp_type_matched = true;
            if (@field(entity, cf.name)) |*comp| {
                found = setHandleField(@TypeOf(comp.*), comp, field_name, raw_val, resources) catch |e| blk: {
                    std.log.warn("setAssetField: setHandleField error for '{s}'.'{s}' on entity {d}: {s}", .{ cf.display_name, field_name, eid, @errorName(e) });
                    break :blk false;
                };
            } else {
                std.log.warn("setAssetField: entity {d} matched component type '{s}' but field '{s}' is null (component not present)", .{ eid, cf.display_name, cf.name });
            }
        }
    }

    if (!found) {
        if (!comp_type_matched) {
            std.log.warn("setAssetField: unknown component type '{s}' on entity {d}", .{ comp_type, eid });
        }
        return error.InvalidArguments;
    }
    ctx.layer.world.markSceneChanged();
    try ctx.reply(.{});
}

// ═══════════════════════════════════════════════════════════════════
//  Component field serialization — comptime inspects struct fields
// ═══════════════════════════════════════════════════════════════════

fn serializeFields(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime T: type, ptr: *const T, resources: *const library_mod.ResourceLibrary) !void {
    const fields = @typeInfo(T).@"struct".fields;
    var first = true;
    inline for (fields) |field| {
        const ft = classifyField(field.type);
        if (ft) |field_type| {
            if (!first) try appendSlice(buf, alloc, ",");
            first = false;
            try appendSlice(buf, alloc, "{\"name\":\"");
            try appendSlice(buf, alloc, field.name);
            try appendSlice(buf, alloc, "\",\"fieldType\":\"");
            try appendSlice(buf, alloc, field_type);
            try appendSlice(buf, alloc, "\",\"value\":");
            if (comptime isOptionalHandle(field.type)) {
                try serializeHandleValue(buf, alloc, field.type, @field(ptr, field.name), resources);
            } else {
                try serializeValue(buf, alloc, field.type, @field(ptr, field.name));
            }
            // For enums, also emit options array
            if (comptime @typeInfo(field.type) == .@"enum") {
                try appendSlice(buf, alloc, ",\"options\":[");
                try emitEnumOptions(buf, alloc, field.type);
                try appendSlice(buf, alloc, "]");
            }
            // For asset_ref, emit assetType
            if (comptime isOptionalHandle(field.type)) {
                try appendSlice(buf, alloc, ",\"assetType\":\"");
                try appendSlice(buf, alloc, comptime assetTypeForHandle(field.type));
                try appendSlice(buf, alloc, "\"");
            }
            try appendSlice(buf, alloc, "}");
        }
    }
}

fn classifyField(comptime T: type) ?[]const u8 {
    if (T == f32) return "float";
    if (T == bool) return "bool";
    if (T == [3]f32) return "vec3";
    if (T == [4]f32) return "color";
    if (comptime isOptionalHandle(T)) return "asset_ref";
    return switch (@typeInfo(T)) {
        .@"enum" => "enum",
        else => null, // Skip unions, slices, non-handle optionals, etc.
    };
}

/// Check whether T is an optional handle type (e.g. ?MeshHandle).
fn isOptionalHandle(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .optional) return false;
    const child = info.optional.child;
    return child == handles.MeshHandle or
        child == handles.MaterialHandle or
        child == handles.ScriptHandle or
        child == handles.TextureHandle or
        child == handles.SkeletonHandle or
        child == handles.SkinHandle or
        child == handles.AnimationClipHandle or
        child == handles.AudioClipHandle;
}

/// Map an optional handle type to its asset category string.
fn assetTypeForHandle(comptime T: type) []const u8 {
    const child = @typeInfo(T).optional.child;
    if (child == handles.MeshHandle) return "mesh";
    if (child == handles.MaterialHandle) return "material";
    if (child == handles.ScriptHandle) return "script";
    if (child == handles.TextureHandle) return "texture";
    if (child == handles.SkeletonHandle) return "skeleton";
    if (child == handles.SkinHandle) return "skin";
    if (child == handles.AnimationClipHandle) return "animation_clip";
    if (child == handles.AudioClipHandle) return "audio_clip";
    unreachable;
}

/// Serialize an optional handle field as its asset_id string (or null).
fn serializeHandleValue(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime T: type, value: T, resources: *const library_mod.ResourceLibrary) !void {
    const child = @typeInfo(T).optional.child;
    if (value) |h| {
        const asset_id = resolveAssetId(child, resources, h);
        if (asset_id) |id| {
            try appendSlice(buf, alloc, "\"");
            try appendSlice(buf, alloc, id);
            try appendSlice(buf, alloc, "\"");
        } else {
            try appendSlice(buf, alloc, "null");
        }
    } else {
        try appendSlice(buf, alloc, "null");
    }
}

/// Reverse-lookup: handle → asset_id via ResourceLibrary.
fn resolveAssetId(comptime HandleT: type, resources: *const library_mod.ResourceLibrary, handle: HandleT) ?[]const u8 {
    if (HandleT == handles.MeshHandle) return resources.meshAssetId(handle);
    if (HandleT == handles.MaterialHandle) return resources.materialAssetId(handle);
    if (HandleT == handles.ScriptHandle) return resources.scriptAssetId(handle);
    if (HandleT == handles.TextureHandle) return resources.textureAssetId(handle);
    if (HandleT == handles.SkeletonHandle) return resources.skeletonAssetId(handle);
    if (HandleT == handles.SkinHandle) return resources.skinAssetId(handle);
    if (HandleT == handles.AnimationClipHandle) return resources.animationClipAssetId(handle);
    // AudioClipHandle — not yet in library (no reverse map); return null for now
    return null;
}

fn serializeValue(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime T: type, value: T) !void {
    if (T == f32) {
        var tmp: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d:.6}", .{value}) catch "0";
        try appendSlice(buf, alloc, s);
    } else if (T == bool) {
        try appendSlice(buf, alloc, if (value) "true" else "false");
    } else if (T == [3]f32) {
        var tmp: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{{\"x\":{d:.4},\"y\":{d:.4},\"z\":{d:.4}}}", .{ value[0], value[1], value[2] }) catch "null";
        try appendSlice(buf, alloc, s);
    } else if (T == [4]f32) {
        var tmp: [164]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{{\"x\":{d:.4},\"y\":{d:.4},\"z\":{d:.4},\"w\":{d:.4}}}", .{ value[0], value[1], value[2], value[3] }) catch "null";
        try appendSlice(buf, alloc, s);
    } else if (@typeInfo(T) == .@"enum") {
        try appendSlice(buf, alloc, "\"");
        try appendSlice(buf, alloc, @tagName(value));
        try appendSlice(buf, alloc, "\"");
    } else {
        try appendSlice(buf, alloc, "null");
    }
}

fn emitEnumOptions(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime T: type) !void {
    const fields = @typeInfo(T).@"enum".fields;
    inline for (fields, 0..) |field, i| {
        if (i > 0) try appendSlice(buf, alloc, ",");
        try appendSlice(buf, alloc, "\"");
        try appendSlice(buf, alloc, field.name);
        try appendSlice(buf, alloc, "\"");
    }
}

fn appendSlice(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, data: []const u8) !void {
    try buf.appendSlice(alloc, data);
}

// ═══════════════════════════════════════════════════════════════════
//  Component field mutation — sets a single field by runtime name
// ═══════════════════════════════════════════════════════════════════

fn setField(comptime T: type, ptr: *T, name: []const u8, val: std.json.Value) !bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            const FT = field.type;
            if (FT == f32) {
                @field(ptr, field.name) = jsonToFloat(val);
                return true;
            } else if (FT == bool) {
                @field(ptr, field.name) = switch (val) {
                    .bool => |b| b,
                    else => return error.InvalidArguments,
                };
                return true;
            } else if (FT == [3]f32) {
                @field(ptr, field.name) = ctx_mod.readVec3(val) orelse return error.InvalidArguments;
                return true;
            } else if (FT == [4]f32) {
                @field(ptr, field.name) = ctx_mod.readVec4(val) orelse return error.InvalidArguments;
                return true;
            } else if (@typeInfo(FT) == .@"enum") {
                const s = switch (val) {
                    .string => |s| s,
                    else => return error.InvalidArguments,
                };
                @field(ptr, field.name) = std.meta.stringToEnum(FT, s) orelse return error.InvalidArguments;
                return true;
            }
        }
    }
    return false;
}

fn jsonToFloat(val: std.json.Value) f32 {
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    };
}

fn canDefaultInit(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .@"struct" => |s| {
            for (s.fields) |field| {
                if (field.default_value_ptr == null) return false;
            }
            return true;
        },
        else => false,
    };
}

// ═══════════════════════════════════════════════════════════════════
//  Asset-reference field mutation — resolves path → handle
// ═══════════════════════════════════════════════════════════════════

fn setHandleField(comptime T: type, ptr: *T, name: []const u8, val: std.json.Value, resources: *const library_mod.ResourceLibrary) !bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            const FT = field.type;
            if (comptime isOptionalHandle(FT)) {
                switch (val) {
                    .null => {
                        @field(ptr, field.name) = null;
                        return true;
                    },
                    .string => |s| {
                        const child = @typeInfo(FT).optional.child;
                        const h = lookupHandle(child, resources, s) orelse {
                            std.log.warn("setHandleField: lookupHandle failed for field '{s}' with value '{s}' (len={d})", .{ field.name, s, s.len });
                            return error.InvalidArguments;
                        };
                        @field(ptr, field.name) = h;
                        return true;
                    },
                    else => {
                        std.log.warn("setHandleField: unexpected json type for field '{s}': {s}", .{ field.name, @tagName(val) });
                        return error.InvalidArguments;
                    },
                }
            }
        }
    }
    return false;
}

/// Forward-lookup: asset_id → handle via ResourceLibrary.
fn lookupHandle(comptime HandleT: type, resources: *const library_mod.ResourceLibrary, asset_id: []const u8) ?HandleT {
    if (HandleT == handles.MeshHandle) return resources.meshHandleByAssetId(asset_id);
    if (HandleT == handles.MaterialHandle) return resources.materialHandleByAssetId(asset_id);
    if (HandleT == handles.ScriptHandle) return resources.scriptHandleByAssetId(asset_id);
    if (HandleT == handles.TextureHandle) return resources.textureHandleByAssetId(asset_id);
    if (HandleT == handles.SkeletonHandle) return resources.skeletonHandleByAssetId(asset_id);
    if (HandleT == handles.SkinHandle) return resources.skinHandleByAssetId(asset_id);
    if (HandleT == handles.AnimationClipHandle) return resources.animationClipHandleByAssetId(asset_id);
    // AudioClipHandle — no by-asset-id lookup yet
    return null;
}
