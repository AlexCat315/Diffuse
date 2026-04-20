const std = @import("std");
const io_globals = @import("io_globals");
const collaboration_mod = @import("collaboration.zig");
const core = @import("../core/layer.zig");
const protocol = @import("protocol.zig");
const resources_mod = @import("resources/mod.zig");
const scene_mod = @import("../scene/scene.zig");
const tools_mod = @import("tools.zig");
const schema = @import("../editor_rpc/schema/mod.zig");

const EmptyObject = struct {};

pub const SyncLayer = struct {
    store: *resources_mod.SnapshotStore,
    tool_bridge: *tools_mod.Bridge,
    collaboration_bridge: *collaboration_mod.Bridge,
    exit_requested: *std.atomic.Value(bool),
    active_clients: *std.atomic.Value(u32),
    idle_publish_interval_frames: u32 = 60,
    last_published_world_revision: u64 = 0,
    last_selection_signature: u64 = 0,
    last_environment_signature: u64 = 0,
    has_published_once: bool = false,
    idle_frames_since_publish: u32 = 0,

    pub fn asLayer(self: *SyncLayer) core.Layer {
        return .{
            .name = "McpSync",
            .context = self,
            .hooks = .{
                .on_attach = onAttach,
                .on_update = onUpdate,
            },
        };
    }

    fn onAttach(context: *anyopaque, layer_context: *core.LayerContext) !void {
        const self: *SyncLayer = @ptrCast(@alignCast(context));
        try self.publish(layer_context);
        self.recordPublishedState(layer_context);
    }

    fn onUpdate(context: *anyopaque, layer_context: *core.LayerContext) !void {
        const self: *SyncLayer = @ptrCast(@alignCast(context));
        if (self.exit_requested.load(.acquire)) {
            layer_context.window.should_close = true;
            return;
        }

        const tool_result = try self.tool_bridge.processPending(layer_context);
        const collaboration_world_changed = try self.collaboration_bridge.processPending(layer_context);

        const state = self.capturePublishState(layer_context);
        const clients_active = self.active_clients.load(.acquire) != 0;

        var should_publish = false;
        if (!self.has_published_once) {
            should_publish = true;
        }
        if (tool_result.snapshot_dirty or collaboration_world_changed) {
            should_publish = true;
        }
        if (clients_active and self.publishStateChanged(state)) {
            should_publish = true;
        }
        if (clients_active and !should_publish and self.idle_frames_since_publish >= self.idle_publish_interval_frames) {
            should_publish = true;
        }

        if (should_publish) {
            try self.publish(layer_context);
            self.recordPublishedStateFromState(state);
        } else if (self.idle_frames_since_publish < std.math.maxInt(u32)) {
            self.idle_frames_since_publish += 1;
        }
    }

    fn publish(self: *SyncLayer, layer_context: *core.LayerContext) !void {
        try self.store.replaceFromRenderer(layer_context.world, layer_context.renderer);
    }

    const PublishState = struct {
        world_revision: u64,
        selection_signature: u64,
        environment_signature: u64,
    };

    fn capturePublishState(self: *const SyncLayer, layer_context: *core.LayerContext) PublishState {
        _ = self;
        return .{
            .world_revision = layer_context.world.sceneRevision(),
            .selection_signature = selectionSignature(
                layer_context.renderer.selectedEntity(),
                layer_context.renderer.selectedEntities(),
            ),
            .environment_signature = environmentSignature(layer_context),
        };
    }

    fn recordPublishedState(self: *SyncLayer, layer_context: *core.LayerContext) void {
        self.recordPublishedStateFromState(self.capturePublishState(layer_context));
    }

    fn recordPublishedStateFromState(self: *SyncLayer, state: PublishState) void {
        self.last_published_world_revision = state.world_revision;
        self.last_selection_signature = state.selection_signature;
        self.last_environment_signature = state.environment_signature;
        self.has_published_once = true;
        self.idle_frames_since_publish = 0;
    }

    fn publishStateChanged(self: *const SyncLayer, state: PublishState) bool {
        return state.world_revision != self.last_published_world_revision or
            state.selection_signature != self.last_selection_signature or
            state.environment_signature != self.last_environment_signature;
    }

    fn selectionSignature(primary: ?scene_mod.EntityId, selected_entities: []const scene_mod.EntityId) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const primary_value: u64 = if (primary) |entity_id| @intCast(entity_id) else 0;
        hasher.update(std.mem.asBytes(&primary_value));
        const count: u64 = @intCast(selected_entities.len);
        hasher.update(std.mem.asBytes(&count));
        for (selected_entities) |entity_id| {
            const resolved_id: u64 = @intCast(entity_id);
            hasher.update(std.mem.asBytes(&resolved_id));
        }
        return hasher.final();
    }

    fn environmentSignature(layer_context: *core.LayerContext) u64 {
        var hasher = std.hash.Wyhash.init(0);
        if (layer_context.world.resources.sceneEnvironmentAssetId()) |asset_id| {
            hasher.update(asset_id);
        } else {
            hasher.update("none");
        }
        return hasher.final();
    }
};

pub fn spawn(
    store: *resources_mod.SnapshotStore,
    tool_bridge: *tools_mod.Bridge,
    collaboration_bridge: *collaboration_mod.Bridge,
    exit_requested: *std.atomic.Value(bool),
    active_clients: *std.atomic.Value(u32),
) !std.Thread {
    const server = try std.heap.page_allocator.create(Server);
    errdefer std.heap.page_allocator.destroy(server);
    server.* = .{
        .store = store,
        .tool_bridge = tool_bridge,
        .collaboration_bridge = collaboration_bridge,
        .exit_requested = exit_requested,
        .active_clients = active_clients,
    };

    return try std.Thread.spawn(.{}, serverMain, .{server});
}

const Server = struct {
    store: *resources_mod.SnapshotStore,
    tool_bridge: *tools_mod.Bridge,
    collaboration_bridge: *collaboration_mod.Bridge,
    exit_requested: *std.atomic.Value(bool),
    active_clients: *std.atomic.Value(u32),
    initialized: bool = false,
    client_registered: bool = false,
    shutdown_received: bool = false,
    negotiated_protocol_version: []const u8 = protocol.default_protocol_version,

    fn requestExit(self: *Server) void {
        self.exit_requested.store(true, .release);
    }

    fn registerClient(self: *Server) void {
        if (self.client_registered) {
            return;
        }
        _ = self.active_clients.fetchAdd(1, .acq_rel);
        self.client_registered = true;
    }

    fn unregisterClient(self: *Server) void {
        if (!self.client_registered) {
            return;
        }
        const previous = self.active_clients.fetchSub(1, .acq_rel);
        if (previous == 0) {
            self.active_clients.store(0, .release);
        }
        self.client_registered = false;
    }

    fn run(self: *Server) !void {
        const io = io_globals.global_io;
        var pending = std.ArrayList(u8).empty;
        defer pending.deinit(std.heap.page_allocator);
        defer self.unregisterClient();

        const stdin_file = std.Io.File.stdin();
        const stdout_file = std.Io.File.stdout();
        var read_buffer: [4096]u8 = undefined;

        while (true) {
            var iovecs: [1][]u8 = .{read_buffer[0..]};
            const bytes_read = try stdin_file.readStreaming(io, &iovecs);
            if (bytes_read == 0) {
                self.requestExit();
                return;
            }

            try pending.appendSlice(std.heap.page_allocator, read_buffer[0..bytes_read]);

            while (try protocol.tryExtractMessageAlloc(std.heap.page_allocator, &pending)) |body| {
                defer std.heap.page_allocator.free(body);
                const should_stop = try self.handleMessage(stdout_file, body);
                if (should_stop) {
                    self.requestExit();
                    return;
                }
            }
        }
    }

    fn handleMessage(self: *Server, stdout_file: std.Io.File, body: []const u8) !bool {
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch |err| {
            try writeErrorResponse(stdout_file, null, protocol.ErrorCode.parse_error, @errorName(err), null);
            return false;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            try writeErrorResponse(stdout_file, null, protocol.ErrorCode.invalid_request, "Request must be a JSON object.", null);
            return false;
        }

        const method_value = root.object.get("method") orelse {
            try writeErrorResponse(stdout_file, root.object.get("id"), protocol.ErrorCode.invalid_request, "Missing method.", null);
            return false;
        };
        const method = switch (method_value) {
            .string => |text| text,
            else => {
                try writeErrorResponse(stdout_file, root.object.get("id"), protocol.ErrorCode.invalid_request, "Method must be a string.", null);
                return false;
            },
        };
        const id = root.object.get("id");
        const params = root.object.get("params");

        if (id == null) {
            return self.handleNotification(method);
        }

        return try self.handleRequest(stdout_file, id.?, method, params);
    }

    fn handleNotification(self: *Server, method: []const u8) bool {
        if (std.mem.eql(u8, method, "notifications/initialized")) {
            self.initialized = true;
            return false;
        }
        if (std.mem.eql(u8, method, "notifications/cancelled")) {
            return false;
        }
        if (std.mem.eql(u8, method, "exit")) {
            return true;
        }
        return false;
    }

    fn handleRequest(
        self: *Server,
        stdout_file: std.Io.File,
        id: std.json.Value,
        method: []const u8,
        params: ?std.json.Value,
    ) !bool {
        if (std.mem.eql(u8, method, "initialize")) {
            const ServerCapabilities = struct {
                resources: EmptyObject = .{},
                tools: EmptyObject = .{},
            };
            const requested_protocol = if (params) |value|
                stringField(value, "protocolVersion") orelse protocol.default_protocol_version
            else
                protocol.default_protocol_version;
            self.negotiated_protocol_version = requested_protocol;
            self.registerClient();

            try writeResult(stdout_file, id, .{
                .protocolVersion = requested_protocol,
                .capabilities = ServerCapabilities{},
                .serverInfo = .{
                    .name = "guava-engine",
                    .title = "Guava Engine MCP",
                    .version = "0.1.0",
                },
                .instructions = "Guava Engine MCP bridge — unified with the RPC handler system. All scene manipulation, entity management, material editing, animation, playback, viewport control, and collaboration tools are auto-generated from the RPC schema. Use tools/list to discover available tools. Resources: scene://hierarchy, selection://current, entity://{id}, schema://components, editor://context, editor://intent-log, preview://staged, script://runtime-status, editor://utilities.",
            });
            return false;
        }

        if (std.mem.eql(u8, method, "ping")) {
            try writeResult(stdout_file, id, EmptyObject{});
            return false;
        }

        if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown_received = true;
            try writeResult(stdout_file, id, EmptyObject{});
            return false;
        }

        if (std.mem.eql(u8, method, "logging/setLevel")) {
            try writeResult(stdout_file, id, EmptyObject{});
            return false;
        }

        if (std.mem.eql(u8, method, "tools/list")) {
            try writeToolList(stdout_file, id);
            return false;
        }

        if (std.mem.eql(u8, method, "tools/call")) {
            const tool_name = if (params) |value| stringField(value, "name") else null;
            if (tool_name == null) {
                try writeErrorResponse(stdout_file, id, protocol.ErrorCode.invalid_params, "tools/call requires params.name.", null);
                return false;
            }

            const arguments = if (params) |value|
                objectField(value, "arguments")
            else
                null;
            const arguments_value = if (arguments) |value| std.json.Value{ .object = value } else null;

            // Convert MCP tool name (underscores) to RPC method name (dots).
            // e.g. "entity_setTransform" → "entity.setTransform"
            var rpc_method_buf: [256]u8 = undefined;
            const rpc_method = mcpNameToRpcMethod(tool_name.?, &rpc_method_buf);

            // Forward all tools through the RPC dispatch system via the tool bridge.
            var response = self.tool_bridge.submitRpcDispatch(tool_name.?, rpc_method, arguments_value) catch |err| switch (err) {
                error.ShuttingDown => {
                    try writeErrorResponse(stdout_file, id, protocol.ErrorCode.internal_error, "Tool bridge is shutting down.", null);
                    return false;
                },
                else => {
                    try writeErrorResponse(stdout_file, id, protocol.ErrorCode.internal_error, "Tool bridge error.", null);
                    return false;
                },
            };
            defer response.deinit(self.tool_bridge.allocator);

            const result_json = response.result.result_json orelse "{}";
            try writeResult(stdout_file, id, .{
                .content = &.{
                    .{
                        .type = "text",
                        .text = result_json,
                    },
                },
                .isError = response.result.error_message != null,
            });
            return false;
        }

        if (std.mem.eql(u8, method, "prompts/list")) {
            try writeResult(stdout_file, id, .{
                .prompts = &.{},
            });
            return false;
        }

        if (std.mem.eql(u8, method, "resources/templates/list")) {
            try writeResult(stdout_file, id, .{
                .resourceTemplates = resources_mod.resource_templates[0..],
            });
            return false;
        }

        if (std.mem.eql(u8, method, "resources/list")) {
            try self.waitUntilReady();
            const listed = try self.store.listAlloc(std.heap.page_allocator);
            defer resources_mod.freeResourceDescriptors(std.heap.page_allocator, listed);
            try writeResult(stdout_file, id, .{
                .resources = listed,
            });
            return false;
        }

        if (std.mem.eql(u8, method, "resources/read")) {
            const uri = if (params) |value| stringField(value, "uri") else null;
            if (uri == null) {
                try writeErrorResponse(stdout_file, id, protocol.ErrorCode.invalid_params, "resources/read requires params.uri.", null);
                return false;
            }

            try self.waitUntilReady();
            const content = try self.store.readAlloc(std.heap.page_allocator, uri.?);
            if (content == null) {
                try writeErrorResponse(stdout_file, id, protocol.ErrorCode.resource_not_found, "Resource not found.", .{
                    .uri = uri.?,
                });
                return false;
            }
            defer resources_mod.freeTextResourceContents(std.heap.page_allocator, content.?);

            try writeResult(stdout_file, id, .{
                .contents = &.{content.?},
            });
            return false;
        }

        try writeErrorResponse(stdout_file, id, protocol.ErrorCode.method_not_found, "Method not found.", .{
            .method = method,
        });
        return false;
    }

    fn waitUntilReady(self: *Server) !void {
        while (!self.store.isReady()) {
            if (self.exit_requested.load(.acquire)) {
                return error.ShuttingDown;
            }
            try std.Io.sleep(io_globals.global_io, std.Io.Duration.fromMilliseconds(5), .real);
        }
    }
};

fn serverMain(server: *Server) void {
    defer std.heap.page_allocator.destroy(server);
    server.run() catch |err| {
        std.log.err("mcp server failed: {s}", .{@errorName(err)});
        server.requestExit();
    };
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) {
        return null;
    }
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn objectField(value: std.json.Value, name: []const u8) ?std.json.ObjectMap {
    if (value != .object) {
        return null;
    }
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .object => |object| object,
        .null => null,
        else => null,
    };
}

fn appendResourceDescriptorsAlloc(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(protocol.ResourceDescriptor),
    descriptors: []const protocol.ResourceDescriptor,
) !void {
    try list.ensureTotalCapacity(allocator, list.items.len + descriptors.len);
    for (descriptors) |descriptor| {
        const copy = try copyResourceDescriptorAlloc(allocator, descriptor);
        list.append(allocator, copy) catch |err| {
            freeResourceDescriptorOwned(allocator, copy);
            return err;
        };
    }
}

fn copyResourceDescriptorAlloc(
    allocator: std.mem.Allocator,
    descriptor: protocol.ResourceDescriptor,
) !protocol.ResourceDescriptor {
    var copy: protocol.ResourceDescriptor = .{
        .uri = "",
        .name = "",
        .title = null,
        .description = null,
        .mimeType = null,
        .size = descriptor.size,
    };

    copy.uri = try allocator.dupe(u8, descriptor.uri);
    errdefer allocator.free(copy.uri);
    copy.name = try allocator.dupe(u8, descriptor.name);
    errdefer allocator.free(copy.name);
    if (descriptor.title) |title| {
        copy.title = try allocator.dupe(u8, title);
        errdefer allocator.free(copy.title.?);
    }
    if (descriptor.description) |description| {
        copy.description = try allocator.dupe(u8, description);
        errdefer allocator.free(copy.description.?);
    }
    if (descriptor.mimeType) |mime_type| {
        copy.mimeType = try allocator.dupe(u8, mime_type);
        errdefer allocator.free(copy.mimeType.?);
    }

    return copy;
}

fn freeResourceDescriptorOwned(allocator: std.mem.Allocator, descriptor: protocol.ResourceDescriptor) void {
    allocator.free(descriptor.uri);
    allocator.free(descriptor.name);
    if (descriptor.title) |title| allocator.free(title);
    if (descriptor.description) |description| allocator.free(description);
    if (descriptor.mimeType) |mime_type| allocator.free(mime_type);
}

fn writeToolList(stdout_file: std.Io.File, id: std.json.Value) !void {
    // Pre-rendered JSON for the tools array (generated at comptime from the RPC schema)
    const tools_json = comptime generateMcpToolsJson();
    const allocator = std.heap.page_allocator;

    // Serialize the "id" field
    const id_json = try std.json.Stringify.valueAlloc(allocator, id, .{});
    defer allocator.free(id_json);

    // Compose the full JSON-RPC response body
    const body = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"{s}\",\"id\":{s},\"result\":{{\"tools\":{s}}}}}", .{
        protocol.jsonrpc_version,
        id_json,
        tools_json,
    });
    defer allocator.free(body);

    // Frame with Content-Length header
    const header = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{body.len});
    defer allocator.free(header);
    const io = io_globals.global_io;
    try stdout_file.writeStreamingAll(io, header);
    try stdout_file.writeStreamingAll(io, body);
}

fn writeCollaborationToolResult(
    stdout_file: std.Io.File,
    id: std.json.Value,
    response: collaboration_mod.CallResponse,
    summary: []const u8,
) !void {
    switch (response.outcome) {
        .staged => |result| {
            try writeResult(stdout_file, id, .{
                .content = &.{
                    .{
                        .type = "text",
                        .text = summary,
                    },
                },
                .structuredContent = .{
                    .tool = response.tool_name,
                    .transaction_id = result.transaction_id,
                    .command_count = result.command_count,
                    .preview_count = result.preview_count,
                    .error_count = result.error_count,
                    .base_revision_conflict_count = result.base_revision_conflict_count,
                },
                .isError = false,
            });
        },
        .applied => |result| {
            try writeResult(stdout_file, id, .{
                .content = &.{
                    .{
                        .type = "text",
                        .text = summary,
                    },
                },
                .structuredContent = .{
                    .tool = response.tool_name,
                    .had_transaction = result.had_transaction,
                    .transaction_id = result.transaction_id,
                    .command_count = result.command_count,
                    .changed_count = result.changed_count,
                    .error_count = result.error_count,
                    .base_revision_conflict_count = result.base_revision_conflict_count,
                    .kept_staged = result.kept_staged,
                },
                .isError = false,
            });
        },
        .discarded => |result| {
            try writeResult(stdout_file, id, .{
                .content = &.{
                    .{
                        .type = "text",
                        .text = summary,
                    },
                },
                .structuredContent = .{
                    .tool = response.tool_name,
                    .had_transaction = result.had_transaction,
                    .transaction_id = result.transaction_id,
                    .command_count = result.command_count,
                },
                .isError = false,
            });
        },
    }
}

fn writeResult(stdout_file: std.Io.File, id: std.json.Value, result: anytype) !void {
    const framed = try protocol.encodeMessageAlloc(std.heap.page_allocator, .{
        .jsonrpc = protocol.jsonrpc_version,
        .id = id,
        .result = result,
    });
    defer std.heap.page_allocator.free(framed);
    try stdout_file.writeStreamingAll(io_globals.global_io, framed);
}

fn writeErrorResponse(
    stdout_file: std.Io.File,
    id: ?std.json.Value,
    code: i64,
    message: []const u8,
    data: anytype,
) !void {
    const framed = try protocol.encodeMessageAlloc(std.heap.page_allocator, .{
        .jsonrpc = protocol.jsonrpc_version,
        .id = if (id) |request_id| request_id else std.json.Value{ .null = {} },
        .@"error" = .{
            .code = code,
            .message = message,
            .data = data,
        },
    });
    defer std.heap.page_allocator.free(framed);
    try stdout_file.writeStreamingAll(io_globals.global_io, framed);
}

// ═══════════════════════════════════════════════════════════════════
//  Comptime MCP Tool List Generation from RPC Schema
// ═══════════════════════════════════════════════════════════════════

/// Convert an MCP tool name (underscores) back to an RPC method name (dots).
/// Uses the first underscore as the namespace separator.
/// e.g. "entity_setTransform" → "entity.setTransform"
fn mcpNameToRpcMethod(tool_name: []const u8, buf: *[256]u8) []const u8 {
    if (tool_name.len > 255) return tool_name;
    var found_sep = false;
    for (tool_name, 0..) |c, i| {
        if (!found_sep and c == '_') {
            buf[i] = '.';
            found_sep = true;
        } else {
            buf[i] = c;
        }
    }
    return buf[0..tool_name.len];
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn unwrap(comptime T: type) type {
    return @typeInfo(T).optional.child;
}

/// Convert a Zig field type to a JSON Schema snippet string (valid JSON).
fn mcpFieldSchema(comptime T: type) []const u8 {
    const U = if (isOptional(T)) unwrap(T) else T;
    if (U == schema.types.JsonValue) return "{\"type\":\"string\"}";
    return switch (@typeInfo(U)) {
        .bool => "{\"type\":\"boolean\"}",
        .int => "{\"type\":\"integer\"}",
        .float => "{\"type\":\"number\"}",
        .pointer => |p| if (p.child == u8)
            "{\"type\":\"string\"}"
        else
            "{\"type\":\"array\",\"items\":" ++ mcpFieldSchema(p.child) ++ "}",
        .array => |a| "{\"type\":\"array\",\"items\":" ++ mcpFieldSchema(a.child) ++ "}",
        .@"struct" => |s| blk: {
            if (s.fields.len == 0) break :blk "{\"type\":\"object\"}";
            var r: []const u8 = "{\"type\":\"object\",\"properties\":{";
            for (s.fields, 0..) |field, i| {
                if (i > 0) r = r ++ ",";
                r = r ++ "\"" ++ field.name ++ "\":" ++ mcpFieldSchema(field.type);
            }
            break :blk r ++ "}}";
        },
        else => "{\"type\":\"string\"}",
    };
}

/// Convert a Zig struct Params type to a JSON Schema object snippet (valid JSON).
fn mcpParamsSchema(comptime T: type) []const u8 {
    const fields = @typeInfo(T).@"struct".fields;
    if (fields.len == 0) return "{\"type\":\"object\",\"properties\":{}}";

    var props: []const u8 = "";
    var req: []const u8 = "";
    var req_count: usize = 0;

    for (fields, 0..) |field, i| {
        if (i > 0) props = props ++ ",";
        props = props ++ "\"" ++ field.name ++ "\":" ++ mcpFieldSchema(field.type);
        if (!isOptional(field.type) and field.default_value_ptr == null) {
            if (req_count > 0) req = req ++ ",";
            req = req ++ "\"" ++ field.name ++ "\"";
            req_count += 1;
        }
    }

    var r: []const u8 = "{\"type\":\"object\",\"properties\":{" ++ props ++ "}";
    if (req_count > 0) {
        r = r ++ ",\"required\":[" ++ req ++ "]";
    }
    return r ++ "}";
}

/// Escape a comptime string for embedding in JSON (escape " and \ characters).
fn escapeJson(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (s) |c| {
            if (c == '"') {
                out = out ++ "\\\"";
            } else if (c == '\\') {
                out = out ++ "\\\\";
            } else if (c == '\n') {
                out = out ++ "\\n";
            } else {
                out = out ++ &[1]u8{c};
            }
        }
        return out;
    }
}

/// Convert RPC method name dots to underscores for MCP compatibility.
fn mcpToolName(comptime method_name: []const u8) []const u8 {
    comptime {
        var out: [method_name.len]u8 = undefined;
        for (method_name, 0..) |c, i| {
            out[i] = if (c == '.') '_' else c;
        }
        return &out;
    }
}

/// Look up the Params type for a given RPC method name across all schema modules.
fn findSchemaParamsType(comptime method_name: []const u8) ?type {
    inline for (schema.method_modules) |mod| {
        for (@typeInfo(mod).@"struct".decls) |decl| {
            if (comptime std.mem.eql(u8, decl.name, method_name)) {
                return @field(mod, decl.name).Params;
            }
        }
    }
    return null;
}

/// Generate the complete JSON array of MCP tools from the RPC schema at comptime.
fn generateMcpToolsJson() []const u8 {
    @setEvalBranchQuota(200_000);
    comptime {
        var r: []const u8 = "[";
        var count: usize = 0;

        for (schema.method_modules) |mod| {
            for (@typeInfo(mod).@"struct".decls) |decl| {
                const M = @field(mod, decl.name);
                if (@hasDecl(M, "ai_tool")) {
                    const tool_meta: schema.types.AiTool = M.ai_tool;
                    const Params = findSchemaParamsType(decl.name) orelse
                        @compileError("ai_tool on method with no Params type: " ++ decl.name);

                    if (count > 0) r = r ++ ",";
                    r = r ++ "{\"name\":\"" ++ mcpToolName(decl.name) ++ "\"";
                    r = r ++ ",\"description\":\"" ++ escapeJson(tool_meta.description) ++ "\"";
                    r = r ++ ",\"inputSchema\":" ++ mcpParamsSchema(Params);
                    r = r ++ "}";
                    count += 1;
                }
            }
        }

        return r ++ "]";
    }
}

test "stringField reads string params from JSON objects" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"params\":{\"uri\":\"scene://hierarchy\"}}", .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const params = parsed.value.object.get("params").?;
    try std.testing.expectEqualStrings("scene://hierarchy", stringField(params, "uri").?);
}
