///! RPC call context — shared infrastructure for all handler modules.
///!
///! Each handler receives a `*Ctx` with helpers for parameter decoding
///! and result serialization.  The heavy JSON plumbing lives here so
///! that handler files stay focused on engine logic.
const std = @import("std");
const core = @import("../core/layer.zig");
const world_mod = @import("../scene/world.zig");
const settings_mod = @import("settings.zig");
const mesh_ops_mod = @import("mesh_ops.zig");

pub const MeshOps = mesh_ops_mod.MeshOps;
pub const World = world_mod.World;
pub const Entity = world_mod.Entity;
pub const EntityId = world_mod.EntityId;

pub const Ctx = struct {
    allocator: std.mem.Allocator,
    params: ?std.json.Value,
    layer: *core.LayerContext,
    settings: *settings_mod.EditorSettings,
    mesh_ops: ?*const MeshOps = null,
    project_root: ?[]const u8 = null,
    scripts_dir: []const u8 = "Content/Scripts",
    _result: ?[]u8 = null,

    // ── Parameter readers ───────────────────────────────────────

    /// Required parameter by key, auto-coercing JSON type to `T`.
    pub fn param(self: *Ctx, comptime T: type, key: []const u8) !T {
        const p = self.params orelse return error.InvalidArguments;
        const val = p.object.get(key) orelse return error.InvalidArguments;
        return coerce(T, val);
    }

    /// Optional parameter — returns `null` when the key is absent.
    pub fn paramOpt(self: *Ctx, comptime T: type, key: []const u8) !?T {
        const p = self.params orelse return null;
        const val = p.object.get(key) orelse return null;
        return try coerce(T, val);
    }

    /// Required JSON array parameter.
    pub fn paramArray(self: *Ctx, key: []const u8) !std.json.Array {
        const p = self.params orelse return error.InvalidArguments;
        const val = p.object.get(key) orelse return error.InvalidArguments;
        return switch (val) {
            .array => |a| a,
            else => error.InvalidArguments,
        };
    }

    /// Required JSON object parameter.
    pub fn paramObj(self: *Ctx, key: []const u8) !std.json.ObjectMap {
        const p = self.params orelse return error.InvalidArguments;
        const val = p.object.get(key) orelse return error.InvalidArguments;
        return switch (val) {
            .object => |o| o,
            else => error.InvalidArguments,
        };
    }

    // ── Result writer ───────────────────────────────────────────

    /// Serialize `value` as the JSON-RPC result. Call exactly once.
    pub fn reply(self: *Ctx, value: anytype) !void {
        self._result = try json(self.allocator, value);
    }

    /// Set a pre-built JSON string as the result (for dynamic responses).
    pub fn replyRaw(self: *Ctx, raw_json: []u8) void {
        self._result = raw_json;
    }

    // ── Internal ────────────────────────────────────────────────

    fn coerce(comptime T: type, val: std.json.Value) !T {
        return switch (T) {
            u64 => switch (val) {
                .integer => |i| @intCast(i),
                .float => |f| @intFromFloat(f),
                else => error.InvalidArguments,
            },
            i64 => switch (val) {
                .integer => |i| i,
                .float => |f| @intFromFloat(f),
                else => error.InvalidArguments,
            },
            f32 => switch (val) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => error.InvalidArguments,
            },
            f64 => switch (val) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => error.InvalidArguments,
            },
            bool => switch (val) {
                .bool => |b| b,
                else => error.InvalidArguments,
            },
            []const u8 => switch (val) {
                .string => |s| s,
                else => error.InvalidArguments,
            },
            else => @compileError("Unsupported param type: " ++ @typeName(T)),
        };
    }
};

// ═══════════════════════════════════════════════════════════════════
//  JSON utilities — used by Ctx and by dispatch.zig
// ═══════════════════════════════════════════════════════════════════

pub fn json(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var writer = output.writer(allocator);
    var buf: [4096]u8 = undefined;
    var adapter = writer.adaptToNewApi(&buf);
    try std.json.Stringify.value(value, .{}, &adapter.new_interface);
    try adapter.new_interface.flush();
    if (adapter.err) |err| return err;
    return try output.toOwnedSlice(allocator);
}

pub fn readVec3(val: std.json.Value) ?[3]f32 {
    const obj = switch (val) {
        .object => |o| o,
        else => return null,
    };
    return .{
        jsonFloat(obj.get("x") orelse return null),
        jsonFloat(obj.get("y") orelse return null),
        jsonFloat(obj.get("z") orelse return null),
    };
}

pub fn readQuat(val: std.json.Value) ?[4]f32 {
    const obj = switch (val) {
        .object => |o| o,
        else => return null,
    };
    return .{
        jsonFloat(obj.get("x") orelse return null),
        jsonFloat(obj.get("y") orelse return null),
        jsonFloat(obj.get("z") orelse return null),
        jsonFloat(obj.get("w") orelse return null),
    };
}

/// Alias for readQuat — used for color [4]f32 {x,y,z,w} objects.
pub const readVec4 = readQuat;

fn jsonFloat(val: std.json.Value) f32 {
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    };
}

pub const ComponentField = struct { name: []const u8, display_name: []const u8 };
pub const component_fields = [_]ComponentField{
    .{ .name = "camera", .display_name = "Camera" },
    .{ .name = "mesh", .display_name = "Mesh" },
    .{ .name = "skinned_mesh", .display_name = "SkinnedMesh" },
    .{ .name = "animator", .display_name = "Animator" },
    .{ .name = "rigidbody", .display_name = "Rigidbody" },
    .{ .name = "box_collider", .display_name = "BoxCollider" },
    .{ .name = "sphere_collider", .display_name = "SphereCollider" },
    .{ .name = "mesh_collider", .display_name = "MeshCollider" },
    .{ .name = "capsule_collider", .display_name = "CapsuleCollider" },
    .{ .name = "character_controller", .display_name = "CharacterController" },
    .{ .name = "tag", .display_name = "Tag" },
    .{ .name = "sky", .display_name = "Sky" },
    .{ .name = "constraint", .display_name = "Constraint" },
    .{ .name = "material", .display_name = "Material" },
    .{ .name = "light", .display_name = "Light" },
    .{ .name = "vfx", .display_name = "Vfx" },
    .{ .name = "script", .display_name = "Script" },
    .{ .name = "audio_source", .display_name = "AudioSource" },
    .{ .name = "audio_listener", .display_name = "AudioListener" },
    .{ .name = "nav_agent", .display_name = "NavAgent" },
};
