// host/parameters.zig — 脚本参数桥接
const std = @import("std");
const mod = @import("./mod.zig");
const context = @import("../context.zig");

/// 从当前活跃实体的脚本组件中查找参数 JSON
fn resolveActiveScriptParameters(ctx_ptr: *context.ScriptContext) ?[]const u8 {
    const entity = ctx_ptr.world.getEntity(ctx_ptr.entity) orelse return null;
    // Match by instance_id to find the correct script component
    if (entity.script) |script| {
        if (script.instance_id) |iid| {
            if (iid == ctx_ptr.instance.id and script.parameters.len > 0) return script.parameters;
        }
    }
    for (entity.scripts) |script| {
        if (script.instance_id) |iid| {
            if (iid == ctx_ptr.instance.id and script.parameters.len > 0) return script.parameters;
        }
    }
    // Fallback: use legacy script if only one exists
    if (entity.script) |script| {
        if (script.parameters.len > 0) return script.parameters;
    }
    return null;
}

pub fn guavaHostGetParameterFloat(userdata: ?*anyopaque, name_ptr: [*]const u8, name_len: usize, default_val: f32) callconv(.c) f32 {
    const ctx_ptr = mod.activeContext(userdata) orelse return default_val;
    const params_json = resolveActiveScriptParameters(ctx_ptr) orelse return default_val;
    var parsed = std.json.parseFromSlice(std.json.Value, ctx_ptr.allocator, params_json, .{}) catch return default_val;
    defer parsed.deinit();
    if (parsed.value != .object) return default_val;
    const val = parsed.value.object.get(name_ptr[0..name_len]) orelse return default_val;
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => default_val,
    };
}

pub fn guavaHostGetParameterInt(userdata: ?*anyopaque, name_ptr: [*]const u8, name_len: usize, default_val: i32) callconv(.c) i32 {
    const ctx_ptr = mod.activeContext(userdata) orelse return default_val;
    const params_json = resolveActiveScriptParameters(ctx_ptr) orelse return default_val;
    var parsed = std.json.parseFromSlice(std.json.Value, ctx_ptr.allocator, params_json, .{}) catch return default_val;
    defer parsed.deinit();
    if (parsed.value != .object) return default_val;
    const val = parsed.value.object.get(name_ptr[0..name_len]) orelse return default_val;
    return switch (val) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        else => default_val,
    };
}

pub fn guavaHostGetParameterBool(userdata: ?*anyopaque, name_ptr: [*]const u8, name_len: usize, default_val: u32) callconv(.c) u32 {
    const ctx_ptr = mod.activeContext(userdata) orelse return default_val;
    const params_json = resolveActiveScriptParameters(ctx_ptr) orelse return default_val;
    var parsed = std.json.parseFromSlice(std.json.Value, ctx_ptr.allocator, params_json, .{}) catch return default_val;
    defer parsed.deinit();
    if (parsed.value != .object) return default_val;
    const val = parsed.value.object.get(name_ptr[0..name_len]) orelse return default_val;
    return switch (val) {
        .bool => |b| if (b) @as(u32, 1) else @as(u32, 0),
        .integer => |i| if (i != 0) @as(u32, 1) else @as(u32, 0),
        else => default_val,
    };
}
