const std = @import("std");
const handles = @import("../assets/handles.zig");
const command_mod = @import("../core/command.zig");
const command_queue_mod = @import("../core/command_queue.zig");
const query_engine = @import("../core/query_engine.zig");
const core = @import("../core/layer.zig");
const script_resource_mod = @import("../assets/script_resource.zig");
const scene_mod = @import("../scene/scene.zig");
const components = @import("../scene/components.zig");
const screenshot_tool = @import("screenshot_tool.zig");

pub const Error = error{
    ToolNotFound,
    InvalidArguments,
    ShuttingDown,
};

const CommandRequest = struct {
    tool_name: []u8,
    command: command_mod.Command,
    meta: command_mod.CommandMeta = .{},

    fn deinit(self: *CommandRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        self.command.deinit(allocator);
        self.meta.deinit(allocator);
        self.* = undefined;
    }
};

const CompileScriptRequest = struct {
    tool_name: []u8,
    script_handle: ?handles.ScriptHandle = null,
    entity_id: ?scene_mod.EntityId = null,
    source: ?[]u8 = null,
    source_path: ?[]u8 = null,
    description: ?[]u8 = null,
    enabled: bool = true,

    fn deinit(self: *CompileScriptRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        if (self.source) |source| allocator.free(source);
        if (self.source_path) |source_path| allocator.free(source_path);
        if (self.description) |description| allocator.free(description);
        self.* = undefined;
    }
};

const CompileEditorUtilityRequest = struct {
    tool_name: []u8,
    script_handle: ?handles.ScriptHandle = null,
    source: ?[]u8 = null,
    source_path: ?[]u8 = null,
    description: ?[]u8 = null,
    utility_name: ?[]u8 = null,
    open: bool = true,

    fn deinit(self: *CompileEditorUtilityRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        if (self.source) |source| allocator.free(source);
        if (self.source_path) |source_path| allocator.free(source_path);
        if (self.description) |description| allocator.free(description);
        if (self.utility_name) |utility_name| allocator.free(utility_name);
        self.* = undefined;
    }
};

const ScreenshotRequest = struct {
    tool_name: []u8,

    fn deinit(self: *ScreenshotRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        self.* = undefined;
    }
};

const QueryRequest = struct {
    tool_name: []u8,
    id: ?scene_mod.EntityId = null,
    name_contains: ?[]u8 = null,
    has_component: ?[]u8 = null,
    has_components: ?[][]u8 = null,
    parent_id: ?scene_mod.EntityId = null,
    visible: ?bool = null,
    origin: ?components.Vec3 = null,
    radius: ?f32 = null,
    aabb_min: ?components.Vec3 = null,
    aabb_max: ?components.Vec3 = null,
    is_dynamic: ?bool = null,
    is_root: ?bool = null,
    has_collider: ?bool = null,
    has_rigidbody: ?bool = null,
    sort_by: ?query_engine.Filter.SortBy = null,
    limit: usize = 50,
    offset: usize = 0,
    count_only: bool = false,

    fn deinit(self: *QueryRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        if (self.name_contains) |name_contains| allocator.free(name_contains);
        if (self.has_component) |has_component| allocator.free(has_component);
        if (self.has_components) |has_components| {
            for (has_components) |comp| allocator.free(comp);
            allocator.free(has_components);
        }
        self.* = undefined;
    }

    fn filter(self: QueryRequest) query_engine.Filter {
        return .{
            .id = self.id,
            .name_contains = self.name_contains,
            .has_component = self.has_component,
            .has_components = self.has_components,
            .parent_id = self.parent_id,
            .visible = self.visible,
            .origin = self.origin,
            .radius = self.radius,
            .aabb_min = self.aabb_min,
            .aabb_max = self.aabb_max,
            .is_dynamic = self.is_dynamic,
            .is_root = self.is_root,
            .has_collider = self.has_collider,
            .has_rigidbody = self.has_rigidbody,
            .sort_by = self.sort_by,
            .limit = self.limit,
            .offset = self.offset,
            .count_only = self.count_only,
        };
    }
};

pub const PendingRequest = union(enum) {
    command: CommandRequest,
    compile_script: CompileScriptRequest,
    compile_editor_utility: CompileEditorUtilityRequest,
    screenshot_png: ScreenshotRequest,
    query_entities: QueryRequest,

    pub fn deinit(self: *PendingRequest, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .command => |*command| command.deinit(allocator),
            .compile_script => |*compile| compile.deinit(allocator),
            .compile_editor_utility => |*compile| compile.deinit(allocator),
            .screenshot_png => |*screenshot| screenshot.deinit(allocator),
            .query_entities => |*query| query.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ToolResult = struct {
    kind: enum {
        command,
        compile_script,
        compile_editor_utility,
        screenshot,
        query,
    } = .command,
    changed: bool = false,
    entity_id: ?scene_mod.EntityId = null,
    script_handle: ?handles.ScriptHandle = null,
    command_error: ?command_mod.CommandError = null,
    script_error: ?[]u8 = null,
    compiled: bool = false,
    attached: bool = false,
    utility_registered: bool = false,
    screenshot_data_uri: ?[]u8 = null,
    screenshot_width: ?u32 = null,
    screenshot_height: ?u32 = null,
    query_result: ?query_engine.ResultSet = null,

    fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        if (self.script_error) |message| allocator.free(message);
        if (self.screenshot_data_uri) |data_uri| allocator.free(data_uri);
        if (self.query_result) |*query_result| query_result.deinit(allocator);
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

pub const ExecuteOutcome = struct {
    response: CallResponse,
    snapshot_dirty: bool = false,
};

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    pending: ?PendingRequest = null,
    response: ?CallResponse = null,
    shutting_down: bool = false,

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

    pub fn submitJson(self: *Bridge, tool_name: []const u8, arguments: ?std.json.Value) !CallResponse {
        return self.submitJsonWithMeta(tool_name, arguments, null);
    }

    pub fn submitJsonWithMeta(
        self: *Bridge,
        tool_name: []const u8,
        arguments: ?std.json.Value,
        meta: ?*const command_mod.CommandMeta,
    ) !CallResponse {
        var request = try parseToolCallWithMetaAlloc(self.allocator, tool_name, arguments, meta);
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

    pub fn executeJsonImmediate(
        self: *Bridge,
        layer_context: *core.LayerContext,
        tool_name: []const u8,
        arguments: ?std.json.Value,
    ) !ExecuteOutcome {
        return self.executeJsonImmediateWithMeta(layer_context, tool_name, arguments, null);
    }

    pub fn executeJsonImmediateWithMeta(
        self: *Bridge,
        layer_context: *core.LayerContext,
        tool_name: []const u8,
        arguments: ?std.json.Value,
        meta: ?*const command_mod.CommandMeta,
    ) !ExecuteOutcome {
        var request = try parseToolCallWithMetaAlloc(self.allocator, tool_name, arguments, meta);
        return try self.executeOwnedRequest(layer_context, &request);
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
        const execution = try self.executeOwnedRequest(layer_context, &request);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.response = execution.response;
        self.condition.broadcast();
        return .{
            .handled = true,
            .snapshot_dirty = execution.snapshot_dirty,
        };
    }

    fn executeOwnedRequest(
        self: *Bridge,
        layer_context: *core.LayerContext,
        request: *PendingRequest,
    ) !ExecuteOutcome {
        const response_tool_name = try self.allocator.dupe(u8, switch (request.*) {
            .command => |command_request| command_request.tool_name,
            .compile_script => |compile_request| compile_request.tool_name,
            .compile_editor_utility => |compile_request| compile_request.tool_name,
            .screenshot_png => |screenshot_request| screenshot_request.tool_name,
            .query_entities => |query_request| query_request.tool_name,
        });
        errdefer self.allocator.free(response_tool_name);

        const result = switch (request.*) {
            .command => |command_request| blk: {
                const execution = command_queue_mod.executeOneWithMeta(
                    layer_context.world,
                    command_request.command,
                    .ai,
                    &command_request.meta,
                ) catch |err| {
                    request.deinit(self.allocator);
                    return err;
                };
                break :blk ToolResult{
                    .kind = .command,
                    .changed = execution.changed,
                    .entity_id = execution.entity_id,
                    .command_error = execution.err,
                };
            },
            .compile_script => |compile_request| blk: {
                break :blk try processCompileScriptRequest(self.allocator, layer_context, compile_request);
            },
            .compile_editor_utility => |compile_request| blk: {
                break :blk try processCompileEditorUtilityRequest(self.allocator, layer_context, compile_request);
            },
            .screenshot_png => |_| blk: {
                const data_uri = screenshot_tool.screenshotAsDataUriAlloc(self.allocator, layer_context) catch |err| {
                    break :blk ToolResult{
                        .kind = .screenshot,
                        .script_error = try std.fmt.allocPrint(self.allocator, "screenshot capture failed: {s}", .{@errorName(err)}),
                    };
                };
                const viewport_size = layer_context.renderer.sceneViewportSize();
                break :blk ToolResult{
                    .kind = .screenshot,
                    .screenshot_data_uri = data_uri,
                    .screenshot_width = viewport_size[0],
                    .screenshot_height = viewport_size[1],
                };
            },
            .query_entities => |query_request| blk: {
                break :blk ToolResult{
                    .kind = .query,
                    .query_result = try query_engine.queryAlloc(self.allocator, layer_context.world, query_request.filter(), .{
                        .static_bvh = &layer_context.world.renderable_spatial_index,
                        .dynamic_bvh = &layer_context.world.dynamic_renderable_spatial_index,
                    }),
                };
            },
        };
        request.deinit(self.allocator);

        return .{
            .response = .{
                .tool_name = response_tool_name,
                .result = result,
            },
            .snapshot_dirty = switch (result.kind) {
                .command => result.changed,
                .compile_script, .compile_editor_utility => true,
                .screenshot, .query => false,
            },
        };
    }
};

pub fn parseToolCallAlloc(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    arguments: ?std.json.Value,
) !PendingRequest {
    return parseToolCallWithMetaAlloc(allocator, tool_name, arguments, null);
}

fn parseToolCallWithMetaAlloc(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    arguments: ?std.json.Value,
    meta_override: ?*const command_mod.CommandMeta,
) !PendingRequest {
    const owned_tool_name = try allocator.dupe(u8, tool_name);
    errdefer allocator.free(owned_tool_name);

    if (std.mem.eql(u8, tool_name, "compile_script")) {
        return .{
            .compile_script = .{
                .tool_name = owned_tool_name,
                .script_handle = try parseOptionalScriptHandle(arguments, "script_handle"),
                .entity_id = try parseOptionalEntityId(arguments, "entity_id"),
                .source = try parseOptionalStringAlloc(allocator, arguments, "source"),
                .source_path = try parseOptionalStringAlloc(allocator, arguments, "source_path"),
                .description = try parseOptionalStringAlloc(allocator, arguments, "description"),
                .enabled = try parseBoolFromObject(try requireObject(arguments), "enabled", true),
            },
        };
    }

    if (std.mem.eql(u8, tool_name, "compile_editor_utility")) {
        return .{
            .compile_editor_utility = .{
                .tool_name = owned_tool_name,
                .script_handle = try parseOptionalScriptHandle(arguments, "script_handle"),
                .source = try parseOptionalStringAlloc(allocator, arguments, "source"),
                .source_path = try parseOptionalStringAlloc(allocator, arguments, "source_path"),
                .description = try parseOptionalStringAlloc(allocator, arguments, "description"),
                .utility_name = try parseOptionalStringAlloc(allocator, arguments, "utility_name"),
                .open = try parseBoolFromObject(try requireObject(arguments), "open", true),
            },
        };
    }

    if (std.mem.eql(u8, tool_name, "screenshot_png")) {
        return .{
            .screenshot_png = .{
                .tool_name = owned_tool_name,
            },
        };
    }

    if (std.mem.eql(u8, tool_name, "query_entities")) {
        return .{
            .query_entities = try parseQueryRequestAlloc(allocator, owned_tool_name, arguments),
        };
    }

    if (std.mem.eql(u8, tool_name, "create_entity")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .meta = try parseEffectiveCommandMetaAlloc(allocator, arguments, meta_override),
                .command = .{
                    .create_entity = try parseCreateEntityAlloc(allocator, arguments),
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "delete_entity")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .meta = try parseEffectiveCommandMetaAlloc(allocator, arguments, meta_override),
                .command = .{
                    .delete_entity = .{
                        .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                    },
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "rename_entity")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .meta = try parseEffectiveCommandMetaAlloc(allocator, arguments, meta_override),
                .command = .{
                    .rename_entity = .{
                        .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                        .name = try parseRequiredStringAlloc(allocator, arguments, "name"),
                    },
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "set_parent")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .meta = try parseEffectiveCommandMetaAlloc(allocator, arguments, meta_override),
                .command = .{
                    .set_parent = .{
                        .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                        .parent_id = try parseOptionalEntityId(arguments, "parent_id"),
                    },
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "set_local_transform")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .meta = try parseEffectiveCommandMetaAlloc(allocator, arguments, meta_override),
                .command = .{
                    .set_local_transform = .{
                        .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                        .transform = try parseRequiredTransform(arguments, "transform"),
                    },
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "set_world_transform")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .meta = try parseEffectiveCommandMetaAlloc(allocator, arguments, meta_override),
                .command = .{
                    .set_world_transform = .{
                        .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                        .transform = try parseRequiredTransform(arguments, "transform"),
                    },
                },
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "set_visible")) {
        return .{
            .command = .{
                .tool_name = owned_tool_name,
                .meta = try parseEffectiveCommandMetaAlloc(allocator, arguments, meta_override),
                .command = .{
                    .set_visible = .{
                        .entity_id = try parseRequiredEntityId(arguments, "entity_id"),
                        .visible = try parseRequiredBool(arguments, "visible"),
                    },
                },
            },
        };
    }

    return error.ToolNotFound;
}

pub fn buildSummaryAlloc(allocator: std.mem.Allocator, response: CallResponse) ![]u8 {
    if (response.result.script_error) |message| {
        return std.fmt.allocPrint(allocator, "{s} failed: {s}", .{
            response.tool_name,
            message,
        });
    }

    if (response.result.command_error) |err| {
        return std.fmt.allocPrint(allocator, "{s} failed: {s}", .{
            response.tool_name,
            @tagName(err),
        });
    }

    if (response.result.kind == .compile_script) {
        return std.fmt.allocPrint(allocator, "{s} ok: script_handle={any}, compiled={}, attached={}", .{
            response.tool_name,
            response.result.script_handle,
            response.result.compiled,
            response.result.attached,
        });
    }

    if (response.result.kind == .compile_editor_utility) {
        return std.fmt.allocPrint(allocator, "{s} ok: script_handle={any}, compiled={}, registered={}", .{
            response.tool_name,
            response.result.script_handle,
            response.result.compiled,
            response.result.utility_registered,
        });
    }

    if (response.result.kind == .screenshot) {
        return std.fmt.allocPrint(allocator, "{s} ok: png data uri ready ({}x{})", .{
            response.tool_name,
            response.result.screenshot_width orelse 0,
            response.result.screenshot_height orelse 0,
        });
    }

    if (response.result.kind == .query) {
        const query = response.result.query_result.?;
        return std.fmt.allocPrint(allocator, "{s} ok: total={}, returned={}, offset={}, limit={}, truncated={}, count_only={}", .{
            response.tool_name,
            query.total,
            query.items.len,
            query.offset,
            query.limit,
            query.truncated,
            query.count_only,
        });
    }

    if (response.result.entity_id) |entity_id| {
        return std.fmt.allocPrint(allocator, "{s} ok: entity {d}, changed={}", .{
            response.tool_name,
            entity_id,
            response.result.changed,
        });
    }

    return std.fmt.allocPrint(allocator, "{s} ok: changed={}", .{
        response.tool_name,
        response.result.changed,
    });
}

fn processCompileScriptRequest(
    allocator: std.mem.Allocator,
    layer_context: *core.LayerContext,
    request: CompileScriptRequest,
) !ToolResult {
    const runtime = layer_context.script_runtime orelse return .{
        .kind = .compile_script,
        .script_error = try allocator.dupe(u8, "script runtime is not available in this context"),
    };

    runtime.bindWorld(layer_context.world);
    if (layer_context.command_queue) |queue| {
        runtime.bindCommandQueue(queue);
    }

    var source_bytes: []u8 = undefined;
    var owns_source = false;
    defer if (owns_source) allocator.free(source_bytes);

    var resource: ?*script_resource_mod.ScriptResource = null;
    if (request.script_handle) |handle| {
        resource = layer_context.world.resources.scriptMutable(handle);
    }

    if (request.source) |source| {
        source_bytes = source;
    } else if (request.source_path) |source_path| {
        source_bytes = try std.fs.cwd().readFileAlloc(allocator, source_path, 8 * 1024 * 1024);
        owns_source = true;
    } else if (resource) |existing_resource| {
        source_bytes = try allocator.dupe(u8, existing_resource.source);
        owns_source = true;
    } else {
        return .{
            .kind = .compile_script,
            .script_error = try allocator.dupe(u8, "compile_script requires source, source_path, or an existing script_handle"),
        };
    }

    // Register / update the script resource
    const handle = if (request.script_handle) |existing_handle| blk: {
        const existing_resource = resource orelse return .{
            .kind = .compile_script,
            .entity_id = request.entity_id,
            .script_handle = request.script_handle,
            .script_error = try allocator.dupe(u8, "script_handle does not exist"),
        };
        existing_resource.language = .zig;
        replaceOwnedSlice(allocator, &existing_resource.source, source_bytes) catch return error.OutOfMemory;
        if (request.description) |description| {
            replaceOwnedSlice(allocator, &existing_resource.description, description) catch return error.OutOfMemory;
        }
        if (request.source_path) |source_path| {
            replaceOwnedSlice(allocator, &existing_resource.source_path, source_path) catch return error.OutOfMemory;
            existing_resource.last_modified = readFileMtime(source_path) catch existing_resource.last_modified;
        } else {
            existing_resource.last_modified = std.time.microTimestamp();
        }
        break :blk existing_handle;
    } else blk: {
        const description = request.description orelse "AI Script";
        const source_path = request.source_path orelse "";
        const created_handle = try layer_context.world.resources.createScript(.{
            .source = source_bytes,
            .language = .zig,
            .entry_fn = "main",
            .description = description,
            .source_path = source_path,
        });
        const created_resource = layer_context.world.resources.scriptMutable(created_handle).?;
        created_resource.last_modified = if (source_path.len != 0)
            readFileMtime(source_path) catch std.time.microTimestamp()
        else
            std.time.microTimestamp();
        break :blk created_handle;
    };

    if (request.source_path) |source_path| {
        if (runtime.hot_reload) |*hr| {
            try hr.registerScript(source_path, handle);
        }
    }

    if (request.script_handle != null) {
        runtime.reloadScript(handle) catch {
            return .{
                .kind = .compile_script,
                .entity_id = request.entity_id,
                .script_handle = handle,
                .compiled = true,
                .script_error = try allocator.dupe(u8, "reload failed"),
            };
        };
    }

    var attached = false;
    if (request.entity_id) |entity_id| {
        if (layer_context.world.getEntity(entity_id)) |entity| {
            const previous_parameters = if (entity.script) |existing_script| existing_script.parameters else @as([]const u8, &.{});
            entity.script = .{
                .script_handle = handle,
                .language = .zig,
                .instance_id = null,
                .enabled = request.enabled,
                .parameters = previous_parameters,
            };
            runtime.reconcileWorld(layer_context.world);
            attached = true;
        } else {
            return .{
                .kind = .compile_script,
                .changed = true,
                .entity_id = entity_id,
                .script_handle = handle,
                .compiled = true,
                .script_error = try allocator.dupe(u8, "entity_id does not exist"),
            };
        }
    }

    runtime.recordEvent(.{
        .script_handle = handle,
        .entity_id = request.entity_id,
        .phase = .load,
        .severity = .info,
        .message = "registered zig script",
    });

    return .{
        .kind = .compile_script,
        .changed = true,
        .entity_id = request.entity_id,
        .script_handle = handle,
        .compiled = true,
        .attached = attached,
    };
}

fn processCompileEditorUtilityRequest(
    allocator: std.mem.Allocator,
    layer_context: *core.LayerContext,
    request: CompileEditorUtilityRequest,
) !ToolResult {
    const utility_runtime = layer_context.editor_utility_runtime orelse return .{
        .kind = .compile_editor_utility,
        .script_error = try allocator.dupe(u8, "editor utility runtime is not available in this context"),
    };

    var source_bytes: []u8 = undefined;
    var owns_source = false;
    defer if (owns_source) allocator.free(source_bytes);

    var resource: ?*script_resource_mod.ScriptResource = null;
    if (request.script_handle) |handle| {
        resource = layer_context.world.resources.scriptMutable(handle);
    }

    if (request.source) |source| {
        source_bytes = source;
    } else if (request.source_path) |source_path| {
        source_bytes = try std.fs.cwd().readFileAlloc(allocator, source_path, 8 * 1024 * 1024);
        owns_source = true;
    } else if (resource) |existing_resource| {
        source_bytes = try allocator.dupe(u8, existing_resource.source);
        owns_source = true;
    } else {
        return .{
            .kind = .compile_editor_utility,
            .script_error = try allocator.dupe(u8, "compile_editor_utility requires source, source_path, or an existing script_handle"),
        };
    }

    // Register / update the editor utility script resource
    const utility_name = try resolveEditorUtilityNameAlloc(
        allocator,
        request.utility_name,
        request.description,
        request.source_path,
        resource,
    );
    defer allocator.free(utility_name);

    const handle = if (request.script_handle) |existing_handle| blk: {
        const existing_resource = resource orelse return .{
            .kind = .compile_editor_utility,
            .script_handle = request.script_handle,
            .script_error = try allocator.dupe(u8, "script_handle does not exist"),
        };
        existing_resource.language = .zig;
        existing_resource.entry_fn = "main";
        replaceOwnedSlice(allocator, &existing_resource.source, source_bytes) catch return error.OutOfMemory;
        replaceOwnedSlice(allocator, &existing_resource.description, utility_name) catch return error.OutOfMemory;
        if (request.source_path) |source_path| {
            replaceOwnedSlice(allocator, &existing_resource.source_path, source_path) catch return error.OutOfMemory;
            existing_resource.last_modified = readFileMtime(source_path) catch existing_resource.last_modified;
        } else {
            existing_resource.last_modified = std.time.microTimestamp();
        }
        break :blk existing_handle;
    } else blk: {
        const created_handle = try layer_context.world.resources.createScript(.{
            .source = source_bytes,
            .language = .zig,
            .entry_fn = "main",
            .description = utility_name,
            .source_path = request.source_path orelse "",
        });
        const created_resource = layer_context.world.resources.scriptMutable(created_handle).?;
        created_resource.last_modified = if (request.source_path) |source_path|
            readFileMtime(source_path) catch std.time.microTimestamp()
        else
            std.time.microTimestamp();
        break :blk created_handle;
    };

    try utility_runtime.upsertCompiled(
        layer_context.world,
        layer_context.command_queue,
        handle,
        utility_name,
        request.open,
    );

    const registration_error = try utility_runtime.lastErrorAlloc(allocator, handle);
    errdefer if (registration_error) |message| allocator.free(message);

    if (layer_context.script_runtime) |script_runtime| {
        const event_message = if (registration_error) |message|
            message
        else
            "registered editor utility";
        script_runtime.recordEvent(.{
            .script_handle = handle,
            .phase = .load,
            .severity = if (registration_error != null) .warning else .info,
            .message = event_message,
        });
    }

    if (registration_error) |message| {
        return .{
            .kind = .compile_editor_utility,
            .changed = true,
            .script_handle = handle,
            .compiled = true,
            .utility_registered = false,
            .script_error = message,
        };
    }

    return .{
        .kind = .compile_editor_utility,
        .changed = true,
        .script_handle = handle,
        .compiled = true,
        .utility_registered = true,
    };
}

fn replaceOwnedSlice(allocator: std.mem.Allocator, target: *[]const u8, next: []const u8) !void {
    allocator.free(target.*);
    target.* = try allocator.dupe(u8, next);
}

fn readFileMtime(path: []const u8) !i128 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return stat.mtime;
}

fn resolveEditorUtilityNameAlloc(
    allocator: std.mem.Allocator,
    requested_name: ?[]const u8,
    description: ?[]const u8,
    source_path: ?[]const u8,
    existing_resource: ?*const script_resource_mod.ScriptResource,
) ![]u8 {
    if (requested_name) |value| {
        return try allocator.dupe(u8, value);
    }
    if (description) |value| {
        return try allocator.dupe(u8, value);
    }
    if (source_path) |value| {
        return try allocator.dupe(u8, std.fs.path.stem(value));
    }
    if (existing_resource) |resource| {
        if (resource.description.len != 0) {
            return try allocator.dupe(u8, resource.description);
        }
        if (resource.source_path.len != 0) {
            return try allocator.dupe(u8, std.fs.path.stem(resource.source_path));
        }
    }
    return try allocator.dupe(u8, "AI Utility");
}

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

fn parseQueryRequestAlloc(
    allocator: std.mem.Allocator,
    owned_tool_name: []u8,
    arguments: ?std.json.Value,
) !QueryRequest {
    const args = try requireObject(arguments);

    const id = try parseOptionalEntityIdFromObject(args, "id");
    const name_contains = try parseOptionalStringAllocFromObject(allocator, args, "name_contains");
    errdefer if (name_contains) |text| allocator.free(text);
    const has_component = try parseOptionalStringAllocFromObject(allocator, args, "has_component");
    errdefer if (has_component) |text| allocator.free(text);
    if (has_component) |component_name| {
        if (!query_engine.isComponentNameSupported(component_name)) {
            return error.InvalidArguments;
        }
    }

    var has_components: ?[][]u8 = null;
    if (args.get("has_components")) |components_val| {
        const arr = switch (components_val) {
            .array => |a| a,
            else => return error.InvalidArguments,
        };
        const components_list = try allocator.alloc([]u8, arr.items.len);
        errdefer allocator.free(components_list);
        for (arr.items, 0..) |item, i| {
            const str = switch (item) {
                .string => |s| s,
                else => return error.InvalidArguments,
            };
            if (!query_engine.isComponentNameSupported(str)) {
                return error.InvalidArguments;
            }
            components_list[i] = try allocator.dupe(u8, str);
        }
        has_components = components_list;
    }
    errdefer if (has_components) |list| {
        for (list) |comp| allocator.free(comp);
        allocator.free(list);
    };

    const has_origin = args.get("origin") != null;
    const has_radius = args.get("radius") != null;
    if (has_origin != has_radius) {
        return error.InvalidArguments;
    }

    const origin = if (has_origin)
        try parseVec3Value(args.get("origin").?)
    else
        null;
    const radius = if (has_radius) blk: {
        const value = try parseF32Value(args.get("radius").?);
        if (value < 0.0) return error.InvalidArguments;
        break :blk value;
    } else null;

    const has_aabb_min = args.get("aabb_min") != null;
    const has_aabb_max = args.get("aabb_max") != null;
    if (has_aabb_min != has_aabb_max) {
        return error.InvalidArguments;
    }

    const aabb_min = if (has_aabb_min)
        try parseVec3Value(args.get("aabb_min").?)
    else
        null;
    const aabb_max = if (has_aabb_max)
        try parseVec3Value(args.get("aabb_max").?)
    else
        null;

    var sort_by: ?query_engine.Filter.SortBy = null;
    if (args.get("sort_by")) |sort_val| {
        const sort_str = switch (sort_val) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };
        if (std.mem.eql(u8, sort_str, "distance")) {
            sort_by = .distance;
        } else if (std.mem.eql(u8, sort_str, "name_asc")) {
            sort_by = .name_asc;
        } else if (std.mem.eql(u8, sort_str, "name_desc")) {
            sort_by = .name_desc;
        } else if (std.mem.eql(u8, sort_str, "id_asc")) {
            sort_by = .id_asc;
        } else {
            return error.InvalidArguments;
        }
    }

    return .{
        .tool_name = owned_tool_name,
        .id = id,
        .name_contains = name_contains,
        .has_component = has_component,
        .has_components = has_components,
        .parent_id = try parseOptionalEntityIdFromObject(args, "parent_id"),
        .visible = try parseOptionalBoolFromObject(args, "visible"),
        .origin = origin,
        .radius = radius,
        .aabb_min = aabb_min,
        .aabb_max = aabb_max,
        .is_dynamic = try parseOptionalBoolFromObject(args, "is_dynamic"),
        .is_root = try parseOptionalBoolFromObject(args, "is_root"),
        .has_collider = try parseOptionalBoolFromObject(args, "has_collider"),
        .has_rigidbody = try parseOptionalBoolFromObject(args, "has_rigidbody"),
        .sort_by = sort_by,
        .limit = try parseUsizeFromObject(args, "limit", 50),
        .offset = try parseUsizeFromObject(args, "offset", 0),
        .count_only = try parseBoolFromObject(args, "count_only", false),
    };
}

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

fn parseOptionalStringAlloc(
    allocator: std.mem.Allocator,
    arguments: ?std.json.Value,
    field_name: []const u8,
) !?[]u8 {
    return parseOptionalStringAllocFromObject(allocator, try requireObject(arguments), field_name);
}

fn optionalStringField(object: std.json.ObjectMap, field_name: []const u8) ?[]const u8 {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => null,
    };
}

fn parseApprovalState(value: []const u8) ?command_mod.ApprovalState {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "previewed")) return .previewed;
    if (std.mem.eql(u8, value, "user_approved")) return .user_approved;
    if (std.mem.eql(u8, value, "rejected")) return .rejected;
    return null;
}

fn replaceMetaFieldAlloc(allocator: std.mem.Allocator, field: *?[]u8, value: []const u8) !void {
    if (field.*) |existing| {
        allocator.free(existing);
    }
    field.* = try allocator.dupe(u8, value);
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

fn parseOptionalStringAllocFromObject(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) !?[]u8 {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| try allocator.dupe(u8, text),
        else => error.InvalidArguments,
    };
}

fn parseRequiredEntityId(arguments: ?std.json.Value, field_name: []const u8) !scene_mod.EntityId {
    return parseRequiredEntityIdFromObject(try requireObject(arguments), field_name);
}

fn parseOptionalScriptHandle(arguments: ?std.json.Value, field_name: []const u8) !?handles.ScriptHandle {
    const object = try requireObject(arguments);
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
        else => try parseScriptHandleValue(value),
    };
}

fn parseRequiredEntityIdFromObject(object: std.json.ObjectMap, field_name: []const u8) !scene_mod.EntityId {
    const value = object.get(field_name) orelse return error.InvalidArguments;
    return try parseEntityIdValue(value);
}

fn parseOptionalEntityId(arguments: ?std.json.Value, field_name: []const u8) !?scene_mod.EntityId {
    return parseOptionalEntityIdFromObject(try requireObject(arguments), field_name);
}

fn parseOptionalEntityIdFromObject(object: std.json.ObjectMap, field_name: []const u8) !?scene_mod.EntityId {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
        else => try parseEntityIdValue(value),
    };
}

fn parseRequiredBool(arguments: ?std.json.Value, field_name: []const u8) !bool {
    return parseRequiredBoolFromObject(try requireObject(arguments), field_name);
}

fn parseScriptHandleValue(value: std.json.Value) !handles.ScriptHandle {
    const raw = switch (value) {
        .integer => |integer| integer,
        else => return error.InvalidArguments,
    };
    if (raw <= 0) {
        return error.InvalidArguments;
    }
    return @enumFromInt(@as(u32, @intCast(raw)));
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

fn parseOptionalBoolFromObject(object: std.json.ObjectMap, field_name: []const u8) !?bool {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .null => null,
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

fn optionalObjectField(object: std.json.ObjectMap, field_name: []const u8) ?std.json.ObjectMap {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .object => |child| child,
        .null => null,
        else => null,
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

fn parseF32FromObject(object: std.json.ObjectMap, field_name: []const u8, default_value: f32) !f32 {
    const value = object.get(field_name) orelse return default_value;
    return try parseF32Value(value);
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

fn parseUsizeFromObject(object: std.json.ObjectMap, field_name: []const u8, default_value: usize) !usize {
    const value = object.get(field_name) orelse return default_value;
    return switch (value) {
        .integer => |number| std.math.cast(usize, number) orelse error.InvalidArguments,
        .float => |number| blk: {
            if (@round(number) != number) return error.InvalidArguments;
            break :blk std.math.cast(usize, @as(i128, @intFromFloat(number))) orelse error.InvalidArguments;
        },
        else => error.InvalidArguments,
    };
}

fn parseF32Value(value: std.json.Value) !f32 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| @floatCast(number),
        else => error.InvalidArguments,
    };
}

fn parseVec3FromObject(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: [3]f32,
) ![3]f32 {
    const value = object.get(field_name) orelse return default_value;
    return try parseVec3Value(value);
}

fn parseVec4FromObject(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: [4]f32,
) ![4]f32 {
    const value = object.get(field_name) orelse return default_value;
    return try parseVec4Value(value);
}

fn parseQuatFromObject(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: [4]f32,
) ![4]f32 {
    return try parseVec4FromObject(object, field_name, default_value);
}

fn parseVec3Value(value: std.json.Value) ![3]f32 {
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidArguments,
    };
    if (array.items.len != 3) {
        return error.InvalidArguments;
    }

    return .{
        try parseF32Value(array.items[0]),
        try parseF32Value(array.items[1]),
        try parseF32Value(array.items[2]),
    };
}

fn parseVec4Value(value: std.json.Value) ![4]f32 {
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidArguments,
    };
    if (array.items.len != 4) {
        return error.InvalidArguments;
    }

    return .{
        try parseF32Value(array.items[0]),
        try parseF32Value(array.items[1]),
        try parseF32Value(array.items[2]),
        try parseF32Value(array.items[3]),
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

test "parseToolCallAlloc parses create_entity with nested components" {
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

    var request = try parseToolCallAlloc(
        std.testing.allocator,
        parsed.value.object.get("name").?.string,
        parsed.value.object.get("arguments").?,
    );
    defer request.deinit(std.testing.allocator);

    switch (request) {
        .command => |command_request| {
            try std.testing.expectEqualStrings("create_entity", command_request.tool_name);
            switch (command_request.command) {
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
        },
        else => return error.UnexpectedCommandTag,
    }
}

test "parseToolCallAlloc rejects invalid transform payloads" {
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
        parseToolCallAlloc(std.testing.allocator, "set_local_transform", parsed.value),
    );
}

test "parseToolCallAlloc parses query_entities with paging and radius filters" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "name": "query_entities",
        \\  "arguments": {
        \\    "name_contains": "light",
        \\    "has_component": "light",
        \\    "visible": true,
        \\    "origin": [0, 0, 0],
        \\    "radius": 12,
        \\    "aabb_min": [-2, -2, -2],
        \\    "aabb_max": [2, 2, 2],
        \\    "limit": 10,
        \\    "offset": 5,
        \\    "count_only": false
        \\  }
        \\}
    , .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var request = try parseToolCallAlloc(
        std.testing.allocator,
        parsed.value.object.get("name").?.string,
        parsed.value.object.get("arguments").?,
    );
    defer request.deinit(std.testing.allocator);

    switch (request) {
        .query_entities => |query| {
            try std.testing.expectEqualStrings("query_entities", query.tool_name);
            try std.testing.expectEqualStrings("light", query.name_contains.?);
            try std.testing.expectEqualStrings("light", query.has_component.?);
            try std.testing.expectEqual(@as(?bool, true), query.visible);
            try std.testing.expectApproxEqAbs(@as(f32, 12.0), query.radius.?, 0.0001);
            try std.testing.expectEqualSlices(f32, &.{ -2.0, -2.0, -2.0 }, &query.aabb_min.?);
            try std.testing.expectEqualSlices(f32, &.{ 2.0, 2.0, 2.0 }, &query.aabb_max.?);
            try std.testing.expectEqual(@as(usize, 10), query.limit);
            try std.testing.expectEqual(@as(usize, 5), query.offset);
            try std.testing.expectEqualSlices(f32, &.{ 0.0, 0.0, 0.0 }, &query.origin.?);
        },
        else => return error.UnexpectedCommandTag,
    }
}

test "parseToolCallAlloc rejects query_entities with incomplete AABB" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "name": "query_entities",
        \\  "arguments": {
        \\    "aabb_min": [0, 0, 0]
        \\  }
        \\}
    , .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectError(
        error.InvalidArguments,
        parseToolCallAlloc(
            std.testing.allocator,
            parsed.value.object.get("name").?.string,
            parsed.value.object.get("arguments").?,
        ),
    );
}

test "parseToolCallWithMetaAlloc applies override metadata to command tools" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "name": "set_visible",
        \\  "arguments": {
        \\    "entity_id": 99,
        \\    "visible": true
        \\  }
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

    var request = try parseToolCallWithMetaAlloc(
        std.testing.allocator,
        parsed.value.object.get("name").?.string,
        parsed.value.object.get("arguments").?,
        &override_meta,
    );
    defer request.deinit(std.testing.allocator);

    switch (request) {
        .command => |command_request| {
            try std.testing.expectEqualStrings("ai_chat", command_request.meta.actor.?);
            try std.testing.expectEqualStrings("editor", command_request.meta.client.?);
            try std.testing.expectEqualStrings("session-1", command_request.meta.session.?);
            try std.testing.expectEqualStrings("req-1", command_request.meta.request.?);
            try std.testing.expectEqualStrings("trace-1", command_request.meta.trace.?);
            try std.testing.expectEqual(command_mod.ApprovalState.user_approved, command_request.meta.approval);
            try std.testing.expectEqual(@as(?u64, 42), command_request.meta.base_revision);
        },
        else => return error.UnexpectedCommandTag,
    }
}
