///! handlers/entity.zig — per-entity inspection & mutation.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const EntityId = ctx_mod.EntityId;

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
            try serializeFields(&buf, ctx.allocator, @TypeOf(comp.*), comp);
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

// ═══════════════════════════════════════════════════════════════════
//  Component field serialization — comptime inspects struct fields
// ═══════════════════════════════════════════════════════════════════

fn serializeFields(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime T: type, ptr: *const T) !void {
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
            try serializeValue(buf, alloc, field.type, @field(ptr, field.name));
            // For enums, also emit options array
            if (comptime @typeInfo(field.type) == .@"enum") {
                try appendSlice(buf, alloc, ",\"options\":[");
                try emitEnumOptions(buf, alloc, field.type);
                try appendSlice(buf, alloc, "]");
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
    return switch (@typeInfo(T)) {
        .@"enum" => "enum",
        else => null, // Skip handles, unions, slices, optionals, etc.
    };
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
