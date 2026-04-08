///! MCP tool bridge — thin RPC forwarding layer.
///!
///! The Bridge shuttles MCP tool calls from the stdio server thread to the
///! main game thread via the unified RPC dispatch system.  All tool logic
///! lives in RPC handlers; this module is purely a cross-thread relay.
///!
///! The only non-Bridge public API is `parseCommandAlloc`, retained for the
///! collaboration staged-transaction system which parses sub-commands into
///! `command_mod.Command` objects.
const std = @import("std");
const handles = @import("../assets/handles.zig");
const command_mod = @import("../core/command.zig");
const core = @import("../core/layer.zig");
const scene_mod = @import("../scene/scene.zig");
const components = @import("../scene/components.zig");
const dispatch_mod = @import("../editor_rpc/dispatch.zig");
const ctx_mod = @import("../editor_rpc/ctx.zig");
const settings_mod = @import("../editor_rpc/settings.zig");

pub const Error = error{
    ToolNotFound,
    InvalidArguments,
    ShuttingDown,
};

// ── RPC dispatch types ───────────────────────────────────────────

const RpcDispatchRequest = struct {
    tool_name: []u8,
    rpc_payload: []u8,

    fn deinit(self: *RpcDispatchRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        allocator.free(self.rpc_payload);
    }
};

pub const ToolResult = struct {
    result_json: ?[]u8 = null,
    error_message: ?[]u8 = null,

    fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        if (self.result_json) |json| allocator.free(json);
        if (self.error_message) |msg| allocator.free(msg);
        self.* = undefined;
    }
};

pub const CallResponse = struct {
    tool_name: []u8,
    result: ToolResult,

    pub fn deinit(self: *CallResponse, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        allocator.free(self.tool_name);
        self.* = undefined;
    }
};

pub const ProcessPendingOutcome = struct {
    handled: bool = false,
    snapshot_dirty: bool = false,
};

// ── Bridge ───────────────────────────────────────────────────────

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    pending: ?RpcDispatchRequest = null,
    response: ?CallResponse = null,
    shutting_down: bool = false,

    /// RPC dispatch context for forwarding MCP tool calls to the unified handler system.
    rpc_ctx: RpcDispatchCtx = .{},

    pub const RpcDispatchCtx = struct {
        settings: ?*settings_mod.EditorSettings = null,
        mesh_ops: ?*const ctx_mod.MeshOps = null,
        collaboration_store: ?*ctx_mod.CollaborationStore = null,
        project_root: ?[]const u8 = null,
        scripts_dir: []const u8 = "Content/Scripts",
    };

    pub fn init(allocator: std.mem.Allocator) Bridge {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bridge) void {
        self.shutdown();

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending) |*pending| {
            pending.deinit(self.allocator);
            self.pending = null;
        }
        if (self.response) |*response| {
            response.deinit(self.allocator);
            self.response = null;
        }
    }

    pub fn shutdown(self: *Bridge) void {
        self.mutex.lock();
        self.shutting_down = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }

    /// Submit an MCP tool call that maps to an RPC method.
    /// Builds a JSON-RPC payload and dispatches through the unified RPC handler system.
    pub fn submitRpcDispatch(self: *Bridge, tool_name: []const u8, rpc_method: []const u8, arguments: ?std.json.Value) !CallResponse {
        // Build a JSON-RPC payload: {"jsonrpc":"2.0","id":1,"method":"<rpc_method>","params":{...}}
        var payload_buf = std.ArrayList(u8).empty;
        defer payload_buf.deinit(self.allocator);
        const w = payload_buf.writer(self.allocator);
        try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"");
        try w.writeAll(rpc_method);
        try w.writeAll("\"");
        if (arguments) |args| {
            try w.writeAll(",\"params\":");
            var adapter_buf: [4096]u8 = undefined;
            var writer_adapter = w.adaptToNewApi(&adapter_buf);
            try std.json.Stringify.value(args, .{}, &writer_adapter.new_interface);
            try writer_adapter.new_interface.flush();
        }
        try w.writeAll("}");

        const owned_tool_name = try self.allocator.dupe(u8, tool_name);
        errdefer self.allocator.free(owned_tool_name);
        const owned_payload = try self.allocator.dupe(u8, payload_buf.items);
        errdefer self.allocator.free(owned_payload);

        var request: RpcDispatchRequest = .{
            .tool_name = owned_tool_name,
            .rpc_payload = owned_payload,
        };
        errdefer request.deinit(self.allocator);

        self.mutex.lock();
        defer self.mutex.unlock();

        while ((self.pending != null or self.response != null) and !self.shutting_down) {
            self.condition.wait(&self.mutex);
        }
        if (self.shutting_down) {
            return error.ShuttingDown;
        }

        self.pending = request;
        self.condition.broadcast();

        while (self.response == null and !self.shutting_down) {
            self.condition.wait(&self.mutex);
        }
        if (self.shutting_down and self.response == null) {
            return error.ShuttingDown;
        }

        const response = self.response.?;
        self.response = null;
        self.condition.broadcast();
        return response;
    }

    pub fn processPending(self: *Bridge, layer_context: *core.LayerContext) !ProcessPendingOutcome {
        self.mutex.lock();
        if (self.pending == null or self.response != null) {
            self.mutex.unlock();
            return .{};
        }
        var request = self.pending.?;
        self.pending = null;
        self.mutex.unlock();

        const response = try self.executeRpcRequest(layer_context, &request);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.response = response;
        self.condition.broadcast();
        return .{
            .handled = true,
            .snapshot_dirty = true,
        };
    }

    fn executeRpcRequest(
        self: *Bridge,
        layer_context: *core.LayerContext,
        request: *RpcDispatchRequest,
    ) !CallResponse {
        const response_tool_name = try self.allocator.dupe(u8, request.tool_name);
        errdefer self.allocator.free(response_tool_name);

        const rpc = &self.rpc_ctx;
        const result = dispatch_mod.dispatch(
            self.allocator,
            request.rpc_payload,
            layer_context,
            rpc.settings orelse {
                request.deinit(self.allocator);
                return error.InvalidArguments;
            },
            rpc.mesh_ops,
            rpc.collaboration_store,
            rpc.project_root,
            rpc.scripts_dir,
        ) catch |err| {
            request.deinit(self.allocator);
            return .{
                .tool_name = response_tool_name,
                .result = .{
                    .error_message = try std.fmt.allocPrint(self.allocator, "RPC dispatch error: {s}", .{@errorName(err)}),
                },
            };
        };
        request.deinit(self.allocator);

        return .{
            .tool_name = response_tool_name,
            .result = .{
                .result_json = result,
            },
        };
    }
};

pub fn buildSummaryAlloc(allocator: std.mem.Allocator, response: CallResponse) ![]u8 {
    if (response.result.error_message) |message| {
        return std.fmt.allocPrint(allocator, "{s} failed: {s}", .{
            response.tool_name,
            message,
        });
    }
    const json_len = if (response.result.result_json) |j| j.len else 0;
    return std.fmt.allocPrint(allocator, "{s} ok: rpc result ({d} bytes)", .{
        response.tool_name,
        json_len,
    });
}

// ── Command parsing (for collaboration staged transactions) ──────

/// Result of parsing a legacy command tool call (create_entity, set_parent, etc.).
/// Used by the collaboration staged-transaction system to parse sub-commands.
pub const CommandParseResult = struct {
    tool_name: []u8,
    command: command_mod.Command,
    meta: command_mod.CommandMeta = .{},

    pub fn deinit(self: *CommandParseResult, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        self.command.deinit(allocator);
        self.meta.deinit(allocator);
        self.* = undefined;
    }
};

/// Parse a legacy command tool call.  Returns error.ToolNotFound for
/// non-command tools (query, screenshot, etc.) since commands are all
/// that staged transactions support.
pub fn parseCommandAlloc(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    arguments: ?std.json.Value,
) !CommandParseResult {
    return parseCommandWithMetaAlloc(allocator, tool_name, arguments, null);
}

pub fn parseCommandWithMetaAlloc(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    arguments: ?std.json.Value,
    meta_override: ?*const command_mod.CommandMeta,
) !CommandParseResult {
    const owned_tool_name = try allocator.dupe(u8, tool_name);
    errdefer allocator.free(owned_tool_name);

    const meta = try parseEffectiveCommandMetaAlloc(allocator, arguments, meta_override);
    errdefer {
        var m = meta;
        m.deinit(allocator);
    }

    const command: command_mod.Command = if (std.mem.eql(u8, tool_name, "create_entity"))
        .{ .create_entity = try parseCreateEntityAlloc(allocator, arguments) }
    else if (std.mem.eql(u8, tool_name, "delete_entity"))
        .{ .delete_entity = .{ .entity_id = try parseRequiredEntityId(arguments, "entity_id") } }
    else if (std.mem.eql(u8, tool_name, "rename_entity"))
        .{ .rename_entity = .{
            .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
            .name = try parseRequiredStringAlloc(allocator, arguments, "name"),
        } }
    else if (std.mem.eql(u8, tool_name, "set_parent"))
        .{ .set_parent = .{
            .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
            .parent_id = try parseOptionalEntityId(arguments, "parent_id"),
        } }
    else if (std.mem.eql(u8, tool_name, "set_local_transform"))
        .{ .set_local_transform = .{
            .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
            .transform = try parseRequiredTransform(arguments, "transform"),
        } }
    else if (std.mem.eql(u8, tool_name, "set_world_transform"))
        .{ .set_world_transform = .{
            .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
            .transform = try parseRequiredTransform(arguments, "transform"),
        } }
    else if (std.mem.eql(u8, tool_name, "set_visible"))
        .{ .set_visible = .{
            .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
            .visible = try parseRequiredBool(arguments, "visible"),
        } }
    else
        return error.ToolNotFound;

    return .{
        .tool_name = owned_tool_name,
        .command = command,
        .meta = meta,
    };
}

// ── JSON parsing helpers ─────────────────────────────────────────

fn requireObject(arguments: ?std.json.Value) Error!std.json.ObjectMap {
    const value = arguments orelse return error.InvalidArguments;
    return switch (value) {
        .object => |object| object,
        else => error.InvalidArguments,
    };
}

fn parseRequiredStringAlloc(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    field_name: []const u8,
) ![]u8 {
    return parseRequiredStringAllocFromObject(allocator, try requireObject(arguments), field_name);
}

fn parseRequiredStringAllocFromObject(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) ![]u8 {
    const value = object.get(field_name) orelse return error.InvalidArguments;
    return switch (value) {
        .string => |text| try allocator.dupe(u8, text),
        else => error.InvalidArguments,
    };
}

fn optionalStringField(object: std.json.ObjectMap, field_name: []const u8) ?[]const u8 {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => null,
    };
}

fn parseRequiredEntityId(arguments: ?std.json.Value, field_name: []const u8) !scene_mod.EntityId {
    return parseRequiredEntityIdFromObject(try requireObject(arguments), field_name);
}

fn parseOptionalEntityId(arguments: ?std.json.Value, field_name: []const u8) !?scene_mod.EntityId {
    return parseOptionalEntityIdFromObject(try requireObject(arguments), field_name);
}

fn parseRequiredEntityIdFromObject(object: std.json.ObjectMap, field_name: []const u8) !scene_mod.EntityId {
    const value = object.get(field_name) orelse return error.InvalidArguments;
    return try parseEntityIdValue(value);
}

fn parseOptionalEntityIdFromObject(object: std.json.ObjectMap, field_name: []const u8) !?scene_mod.EntityId {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
        else => try parseEntityIdValue(value),
    };
}

fn parseEntityIdValue(value: std.json.Value) !scene_mod.EntityId {
    return switch (value) {
        .integer => |number| std.math.cast(scene_mod.EntityId, number) orelse error.InvalidArguments,
        .float => |number| blk: {
            if (@round(number) != number) return error.InvalidArguments;
            break :blk std.math.cast(scene_mod.EntityId, @as(i128, @intFromFloat(number))) orelse error.InvalidArguments;
        },
        else => error.InvalidArguments,
    };
}

fn parseRequiredBool(arguments: ?std.json.Value, field_name: []const u8) !bool {
    return parseRequiredBoolFromObject(try requireObject(arguments), field_name);
}

fn parseRequiredBoolFromObject(object: std.json.ObjectMap, field_name: []const u8) !bool {
    const value = object.get(field_name) orelse return error.InvalidArguments;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidArguments,
    };
}

fn parseBoolFromObject(object: std.json.ObjectMap, field_name: []const u8, default_value: bool) !bool {
    const value = object.get(field_name) orelse return default_value;
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.InvalidArguments,
    };
}

fn parseRequiredTransform(arguments: ?std.json.Value, field_name: []const u8) !components.Transform {
    return parseTransformFromObject(try requireObject(arguments), field_name, null);
}

fn parseTransformFromObject(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: ?components.Transform,
) !components.Transform {
    const value = object.get(field_name) orelse return default_value orelse error.InvalidArguments;
    return try parseTransformValue(value);
}

fn parseTransformValue(value: std.json.Value) !components.Transform {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidArguments,
    };
    return .{
        .translation = try parseVec3FromObject(object, "translation", .{ 0.0, 0.0, 0.0 }),
        .rotation = try parseQuatFromObject(object, "rotation", .{ 0.0, 0.0, 0.0, 1.0 }),
        .scale = try parseVec3FromObject(object, "scale", .{ 1.0, 1.0, 1.0 }),
    };
}

fn parseF32Value(value: std.json.Value) !f32 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| @floatCast(number),
        else => error.InvalidArguments,
    };
}

fn parseF32FromObject(object: std.json.ObjectMap, field_name: []const u8, default_value: f32) !f32 {
    const value = object.get(field_name) orelse return default_value;
    return try parseF32Value(value);
}

fn parseVec3FromObject(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: [3]f32,
) ![3]f32 {
    const value = object.get(field_name) orelse return default_value;
    return try parseVec3Value(value);
}

fn parseVec3Value(value: std.json.Value) ![3]f32 {
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidArguments,
    };
    if (array.items.len != 3) return error.InvalidArguments;
    return .{
        try parseF32Value(array.items[0]),
        try parseF32Value(array.items[1]),
        try parseF32Value(array.items[2]),
    };
}

fn parseVec4FromObject(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: [4]f32,
) ![4]f32 {
    const value = object.get(field_name) orelse return default_value;
    return try parseVec4Value(value);
}

fn parseVec4Value(value: std.json.Value) ![4]f32 {
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidArguments,
    };
    if (array.items.len != 4) return error.InvalidArguments;
    return .{
        try parseF32Value(array.items[0]),
        try parseF32Value(array.items[1]),
        try parseF32Value(array.items[2]),
        try parseF32Value(array.items[3]),
    };
}

fn parseQuatFromObject(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: [4]f32,
) ![4]f32 {
    return try parseVec4FromObject(object, field_name, default_value);
}

fn optionalObjectField(object: std.json.ObjectMap, field_name: []const u8) ?std.json.ObjectMap {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .object => |child| child,
        .null => null,
        else => null,
    };
}

fn parseEnumFromObject(
    comptime T: type,
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: T,
) !T {
    const value = object.get(field_name) orelse return default_value;
    const text = switch (value) {
        .string => |text| text,
        else => return error.InvalidArguments,
    };
    return std.meta.stringToEnum(T, text) orelse error.InvalidArguments;
}

fn parseOptionalHandleFromObject(comptime T: type, object: std.json.ObjectMap, field_name: []const u8) !?T {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
        else => @enumFromInt(try parseHandleIntValue(value)),
    };
}

fn parseHandleIntValue(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |number| std.math.cast(u32, number) orelse error.InvalidArguments,
        .float => |number| blk: {
            if (@round(number) != number) return error.InvalidArguments;
            break :blk std.math.cast(u32, @as(i128, @intFromFloat(number))) orelse error.InvalidArguments;
        },
        else => error.InvalidArguments,
    };
}

fn parseU16FromObject(object: std.json.ObjectMap, field_name: []const u8, default_value: u16) !u16 {
    const value = object.get(field_name) orelse return default_value;
    return switch (value) {
        .integer => |number| std.math.cast(u16, number) orelse error.InvalidArguments,
        .float => |number| blk: {
            if (@round(number) != number) return error.InvalidArguments;
            break :blk std.math.cast(u16, @as(i128, @intFromFloat(number))) orelse error.InvalidArguments;
        },
        else => error.InvalidArguments,
    };
}

// ── create_entity sub-parsers ────────────────────────────────────

fn parseCreateEntityAlloc(allocator: std.mem.Allocator, arguments: ?std.json.Value) !command_mod.Command.CreateEntity {
    const args = try requireObject(arguments);
    return .{
        .name = try parseRequiredStringAllocFromObject(allocator, args, "name"),
        .parent = try parseOptionalEntityIdFromObject(args, "parent"),
        .local_transform = try parseTransformFromObject(args, "local_transform", .{}),
        .camera = if (optionalObjectField(args, "camera")) |camera_value| try parseCamera(camera_value) else null,
        .mesh = if (optionalObjectField(args, "mesh")) |mesh_value| try parseMesh(mesh_value) else null,
        .material = if (optionalObjectField(args, "material")) |material_value| try parseMaterial(material_value) else null,
        .light = if (optionalObjectField(args, "light")) |light_value| try parseLight(light_value) else null,
        .vfx = if (optionalObjectField(args, "vfx")) |vfx_value| try parseVfx(vfx_value) else null,
        .visible = try parseBoolFromObject(args, "visible", true),
        .editor_only = try parseBoolFromObject(args, "editor_only", false),
        .is_folder = try parseBoolFromObject(args, "is_folder", false),
    };
}

fn parseCamera(object: std.json.ObjectMap) !components.Camera {
    var camera = components.Camera{};
    camera.is_primary = try parseBoolFromObject(object, "is_primary", camera.is_primary);

    if (optionalObjectField(object, "projection")) |projection_value| {
        if (optionalObjectField(projection_value, "perspective")) |perspective_value| {
            camera.projection = .{
                .perspective = .{
                    .fov_y_radians = try parseF32FromObject(perspective_value, "fov_y_radians", 1.0471976),
                    .near_clip = try parseF32FromObject(perspective_value, "near_clip", 0.1),
                    .far_clip = try parseF32FromObject(perspective_value, "far_clip", 1000.0),
                },
            };
        } else if (optionalObjectField(projection_value, "orthographic")) |orthographic_value| {
            camera.projection = .{
                .orthographic = .{
                    .size = try parseF32FromObject(orthographic_value, "size", 10.0),
                    .near_clip = try parseF32FromObject(orthographic_value, "near_clip", -1.0),
                    .far_clip = try parseF32FromObject(orthographic_value, "far_clip", 1.0),
                },
            };
        } else {
            return error.InvalidArguments;
        }
    }

    return camera;
}

fn parseMesh(object: std.json.ObjectMap) !components.Mesh {
    return .{
        .handle = try parseOptionalHandleFromObject(handles.MeshHandle, object, "handle"),
        .primitive = try parseEnumFromObject(components.Primitive, object, "primitive", .custom),
    };
}

fn parseMaterial(object: std.json.ObjectMap) !components.Material {
    return .{
        .handle = try parseOptionalHandleFromObject(handles.MaterialHandle, object, "handle"),
        .shading = try parseEnumFromObject(components.ShadingModel, object, "shading", .pbr_metallic_roughness),
        .base_color_factor = try parseVec4FromObject(object, "base_color_factor", .{ 1.0, 1.0, 1.0, 1.0 }),
        .emissive_factor = try parseVec3FromObject(object, "emissive_factor", .{ 0.0, 0.0, 0.0 }),
        .metallic_factor = try parseF32FromObject(object, "metallic_factor", 1.0),
        .roughness_factor = try parseF32FromObject(object, "roughness_factor", 1.0),
        .alpha_cutoff = try parseF32FromObject(object, "alpha_cutoff", 0.5),
        .double_sided = try parseBoolFromObject(object, "double_sided", false),
    };
}

fn parseLight(object: std.json.ObjectMap) !components.Light {
    return .{
        .kind = try parseEnumFromObject(components.LightKind, object, "kind", .directional),
        .color = try parseVec3FromObject(object, "color", .{ 1.0, 1.0, 1.0 }),
        .intensity = try parseF32FromObject(object, "intensity", 1.0),
        .range = try parseF32FromObject(object, "range", 10.0),
    };
}

fn parseVfx(object: std.json.ObjectMap) !components.Vfx {
    return .{
        .kind = try parseEnumFromObject(components.VfxKind, object, "kind", .fountain),
        .looping = try parseBoolFromObject(object, "looping", true),
        .emission_rate = try parseF32FromObject(object, "emission_rate", 18.0),
        .particle_lifetime = try parseF32FromObject(object, "particle_lifetime", 1.25),
        .speed = try parseF32FromObject(object, "speed", 2.2),
        .max_particles = try parseU16FromObject(object, "max_particles", 24),
        .radius = try parseF32FromObject(object, "radius", 0.55),
        .spread = try parseF32FromObject(object, "spread", 0.35),
        .size = try parseF32FromObject(object, "size", 0.12),
        .color = try parseVec3FromObject(object, "color", .{ 1.0, 0.58, 0.26 }),
    };
}

// ── Command metadata parsing ─────────────────────────────────────

fn parseEffectiveCommandMetaAlloc(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    meta_override: ?*const command_mod.CommandMeta,
) !command_mod.CommandMeta {
    var meta = try parseCommandMetaAlloc(allocator, arguments);
    errdefer meta.deinit(allocator);
    if (meta_override) |override_meta| {
        meta.deinit(allocator);
        meta = try override_meta.cloneAlloc(allocator);
    }
    return meta;
}

fn parseCommandMetaAlloc(allocator: std.mem.Allocator, arguments: ?std.json.Value) !command_mod.CommandMeta {
    var meta: command_mod.CommandMeta = .{};
    errdefer meta.deinit(allocator);

    const object = try requireObject(arguments);
    if (object.get("meta")) |meta_value| {
        switch (meta_value) {
            .object => |meta_object| try applyCommandMetaFieldsAlloc(allocator, meta_object, &meta),
            .null => {},
            else => return error.InvalidArguments,
        }
    }
    try applyCommandMetaFieldsAlloc(allocator, object, &meta);
    return meta;
}

fn applyCommandMetaFieldsAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    meta: *command_mod.CommandMeta,
) !void {
    if (optionalStringField(object, "actor")) |value| {
        try replaceMetaFieldAlloc(allocator, &meta.actor, value);
    }
    if (optionalStringField(object, "client")) |value| {
        try replaceMetaFieldAlloc(allocator, &meta.client, value);
    }
    if (optionalStringField(object, "session")) |value| {
        try replaceMetaFieldAlloc(allocator, &meta.session, value);
    }
    if (optionalStringField(object, "request")) |value| {
        try replaceMetaFieldAlloc(allocator, &meta.request, value);
    }
    if (optionalStringField(object, "trace")) |value| {
        try replaceMetaFieldAlloc(allocator, &meta.trace, value);
    }
    if (optionalStringField(object, "approval")) |value| {
        meta.approval = parseApprovalState(value) orelse return error.InvalidArguments;
    }
    if (object.get("base_revision")) |value| {
        switch (value) {
            .integer => |revision| {
                if (revision < 0) return error.InvalidArguments;
                meta.base_revision = @intCast(revision);
            },
            .null => meta.base_revision = null,
            else => return error.InvalidArguments,
        }
    }
}

fn replaceMetaFieldAlloc(allocator: std.mem.Allocator, field: *?[]u8, value: []const u8) !void {
    if (field.*) |existing| {
        allocator.free(existing);
    }
    field.* = try allocator.dupe(u8, value);
}

fn parseApprovalState(value: []const u8) ?command_mod.ApprovalState {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "previewed")) return .previewed;
    if (std.mem.eql(u8, value, "user_approved")) return .user_approved;
    if (std.mem.eql(u8, value, "rejected")) return .rejected;
    return null;
}

// ── Tests ────────────────────────────────────────────────────────

test "parseCommandAlloc parses create_entity with nested components" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "name": "create_entity",
        \\  "arguments": {
        \\    "name": "McpLight",
        \\    "parent": 4,
        \\    "local_transform": {
        \\      "translation": [1, 2, 3],
        \\      "rotation": [0, 0, 0, 1],
        \\      "scale": [0.5, 0.5, 0.5]
        \\    },
        \\    "light": {
        \\      "kind": "spot",
        \\      "intensity": 24.0,
        \\      "range": 12.0
        \\    },
        \\    "visible": false
        \\  }
        \\}
    , .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var request = try parseCommandAlloc(
        std.testing.allocator,
        parsed.value.object.get("name").?.string,
        parsed.value.object.get("arguments").?,
    );
    defer request.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("create_entity", request.tool_name);
    switch (request.command) {
        .create_entity => |create| {
            try std.testing.expectEqualStrings("McpLight", create.name);
            try std.testing.expectEqual(@as(?scene_mod.EntityId, 4), create.parent);
            try std.testing.expectApproxEqAbs(@as(f32, 3.0), create.local_transform.translation[2], 0.0001);
            try std.testing.expect(!create.visible);
            try std.testing.expect(create.light != null);
            try std.testing.expectEqual(components.LightKind.spot, create.light.?.kind);
            try std.testing.expectApproxEqAbs(@as(f32, 24.0), create.light.?.intensity, 0.0001);
        },
        else => return error.UnexpectedCommandTag,
    }
}

test "parseCommandAlloc rejects invalid transform payloads" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "entity_id": 42,
        \\  "transform": {
        \\    "translation": [1, 2]
        \\  }
        \\}
    , .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectError(
        error.InvalidArguments,
        parseCommandAlloc(std.testing.allocator, "set_local_transform", parsed.value),
    );
}

test "parseCommandWithMetaAlloc applies override metadata" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "entity_id": 99,
        \\  "visible": true
        \\}
    , .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var override_meta: command_mod.CommandMeta = .{};
    defer override_meta.deinit(std.testing.allocator);
    override_meta.actor = try std.testing.allocator.dupe(u8, "ai_chat");
    override_meta.client = try std.testing.allocator.dupe(u8, "editor");
    override_meta.session = try std.testing.allocator.dupe(u8, "session-1");
    override_meta.request = try std.testing.allocator.dupe(u8, "req-1");
    override_meta.trace = try std.testing.allocator.dupe(u8, "trace-1");
    override_meta.approval = .user_approved;
    override_meta.base_revision = 42;

    var request = try parseCommandWithMetaAlloc(
        std.testing.allocator,
        "set_visible",
        parsed.value,
        &override_meta,
    );
    defer request.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ai_chat", request.meta.actor.?);
    try std.testing.expectEqualStrings("editor", request.meta.client.?);
    try std.testing.expectEqualStrings("session-1", request.meta.session.?);
    try std.testing.expectEqualStrings("req-1", request.meta.request.?);
    try std.testing.expectEqualStrings("trace-1", request.meta.trace.?);
    try std.testing.expectEqual(command_mod.ApprovalState.user_approved, request.meta.approval);
    try std.testing.expectEqual(@as(?u64, 42), request.meta.base_revision);
}

test "parseCommandAlloc returns ToolNotFound for unsupported tools" {
    try std.testing.expectError(error.ToolNotFound, parseCommandAlloc(std.testing.allocator, "screenshot_png", null));
    try std.testing.expectError(error.ToolNotFound, parseCommandAlloc(std.testing.allocator, "query_entities", null));
    try std.testing.expectError(error.ToolNotFound, parseCommandAlloc(std.testing.allocator, "unknown_tool", null));
}
