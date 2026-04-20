const std = @import("std");
const io_globals = @import("io_globals");
const command_queue_mod = @import("../core/command_queue.zig");
const types = @import("./types.zig");
const context = @import("./context.zig");
const vm_mod = @import("./zig_backend.zig");
const hot_reload_mod = @import("./hot_reload.zig");
const csharp_toolchain = @import("./csharp_toolchain.zig");
const handles = @import("../assets/handles.zig");
const components = @import("../scene/components.zig");
const world_mod = @import("../scene/world.zig");
const script_resource_mod = @import("../assets/script_resource.zig");

const log = std.log.scoped(.script_runtime);

/// 脚本运行时 - 管理所有脚本实例
pub const ScriptRuntime = struct {
    pub const StatusSeverity = enum {
        info,
        warning,
        @"error",
    };

    pub const StatusPhase = enum {
        compile,
        load,
        init,
        update,
        destroy,
    };

    pub const StatusEvent = struct {
        sequence: u64,
        script_handle: ?handles.ScriptHandle = null,
        entity_id: ?types.EntityId = null,
        phase: StatusPhase,
        severity: StatusSeverity,
        message: []u8,
    };

    pub const EventDesc = struct {
        script_handle: ?handles.ScriptHandle = null,
        entity_id: ?types.EntityId = null,
        phase: StatusPhase,
        severity: StatusSeverity = .info,
        message: []const u8,
    };

    /// 配置
    config: types.ScriptSystemConfig,
    /// 实例表
    instances: std.AutoHashMap(types.ScriptInstanceId, *types.ScriptInstance),
    /// 下一个实例 ID
    next_instance_id: types.ScriptInstanceId = 1,
    /// 每实体的脚本列表（entity_id -> script handles）
    entity_scripts: std.AutoHashMap(types.EntityId, std.ArrayList(types.ScriptInstanceId)),
    /// 按语言分组的 VM
    vms: std.AutoHashMap(types.ScriptLanguage, *vm_mod.ScriptVM),
    /// 当前绑定的世界
    world: ?*world_mod.World = null,
    /// 当前绑定的命令队列
    command_queue: ?*command_queue_mod.CommandQueue = null,
    /// 热重载管理器
    hot_reload: ?hot_reload_mod.HotReloadManager,
    /// 分配器
    allocator: std.mem.Allocator,
    /// 临时上下文（每帧复用）
    temp_context: ?*context.ScriptContext = null,
    /// 全局黑板（跨脚本共享键值存储）
    blackboard: context.Blackboard,
    /// 持久化存储根路径（saves/）
    save_root_path: []const u8 = "saves",
    /// 可读脚本状态日志
    status_events: std.ArrayList(StatusEvent),
    status_mutex: std.Io.Mutex = std.Io.Mutex.init,
    next_status_sequence: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, config: types.ScriptSystemConfig) ScriptRuntime {
        return .{
            .config = config,
            .instances = std.AutoHashMap(types.ScriptInstanceId, *types.ScriptInstance).init(allocator),
            .entity_scripts = std.AutoHashMap(types.EntityId, std.ArrayList(types.ScriptInstanceId)).init(allocator),
            .vms = std.AutoHashMap(types.ScriptLanguage, *vm_mod.ScriptVM).init(allocator),
            .allocator = allocator,
            .hot_reload = if (config.enable_hot_reload)
                hot_reload_mod.HotReloadManager.init(allocator, undefined)
            else
                null,
            .blackboard = context.Blackboard.init(allocator),
            .status_events = .empty,
        };
    }

    pub fn deinit(self: *ScriptRuntime) void {
        var instances_to_destroy = std.ArrayList(*types.ScriptInstance).empty;
        defer instances_to_destroy.deinit(self.allocator);

        // 销毁所有实例
        var instances_iter = self.instances.valueIterator();
        while (instances_iter.next()) |instance| {
            instances_to_destroy.append(self.allocator, instance.*) catch |err| {
                log.err("Failed to queue instance for destruction: {}", .{err});
                break;
            };
        }
        for (instances_to_destroy.items) |instance| {
            if (self.instances.contains(instance.id)) {
                self.destroyInstance(instance);
            }
        }
        self.instances.deinit();

        self.status_mutex.lockUncancelable(io_globals.global_io);
        defer self.status_mutex.unlock(io_globals.global_io);
        for (self.status_events.items) |event| {
            self.allocator.free(event.message);
        }
        self.status_events.deinit(self.allocator);

        // 销毁实体脚本列表
        var iter = self.entity_scripts.valueIterator();
        while (iter.next()) |list| {
            list.deinit(self.allocator);
        }
        self.entity_scripts.deinit();

        // 销毁 VM
        var vms_iter = self.vms.valueIterator();
        while (vms_iter.next()) |vm| {
            const script_vm = vm.*;
            script_vm.deinit(self.allocator);
            self.allocator.destroy(script_vm);
        }
        self.vms.deinit();

        // 销毁全局黑板
        self.blackboard.deinit();

        // 销毁热重载管理器
        if (self.hot_reload) |*hr| {
            hr.deinit();
        }
    }

    pub fn bindWorld(self: *ScriptRuntime, world: *world_mod.World) void {
        self.world = world;
    }

    pub fn bindCommandQueue(self: *ScriptRuntime, command_queue: *command_queue_mod.CommandQueue) void {
        self.command_queue = command_queue;
    }

    pub fn recordEvent(self: *ScriptRuntime, desc: EventDesc) void {
        const owned_message = self.allocator.dupe(u8, desc.message) catch return;
        errdefer self.allocator.free(owned_message);

        self.status_mutex.lockUncancelable(io_globals.global_io);
        defer self.status_mutex.unlock(io_globals.global_io);

        if (self.status_events.items.len >= 64) {
            const dropped = self.status_events.orderedRemove(0);
            self.allocator.free(dropped.message);
        }

        self.status_events.append(self.allocator, .{
            .sequence = self.next_status_sequence,
            .script_handle = desc.script_handle,
            .entity_id = desc.entity_id,
            .phase = desc.phase,
            .severity = desc.severity,
            .message = owned_message,
        }) catch {
            self.allocator.free(owned_message);
            return;
        };
        self.next_status_sequence += 1;
    }

    pub fn buildStatusJsonAlloc(self: *const ScriptRuntime, allocator: std.mem.Allocator) ![]u8 {
        const mutable: *ScriptRuntime = @constCast(self);
        mutable.status_mutex.lockUncancelable(io_globals.global_io);
        defer mutable.status_mutex.unlock(io_globals.global_io);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        try std.json.Stringify.value(.{
            .event_count = mutable.status_events.items.len,
            .events = mutable.status_events.items,
        }, .{ .whitespace = .indent_2 }, &out.writer);
        try out.writer.writeByte('\n');
        return out.toOwnedSlice();
    }

    /// 初始化 VM
    pub fn initVMs(self: *ScriptRuntime) !void {
        for (self.config.allowed_languages) |lang| {
            const vm = try vm_mod.createGameplayVM(lang, self.allocator);
            try self.vms.put(lang, vm);
        }

        // 初始化热重载管理器
        if (self.hot_reload) |*hr| {
            hr.runtime = self;
        }
    }

    /// 为实体创建脚本实例
    pub fn createScriptInstance(
        self: *ScriptRuntime,
        entity_id: types.EntityId,
        script_handle: handles.ScriptHandle,
    ) !*types.ScriptInstance {
        const instance_id = self.next_instance_id;
        self.next_instance_id += 1;

        // 创建实例
        const instance = try self.allocator.create(types.ScriptInstance);
        instance.* = .{
            .id = instance_id,
            .entity_id = entity_id,
            .script_handle = script_handle,
            .language = .zig,
            .vtable = .{},
            .state = .ready,
        };

        try self.instances.put(instance_id, instance);

        // 添加到实体脚本列表
        var list = try self.entity_scripts.getOrPut(entity_id);
        if (!list.found_existing) {
            list.value_ptr.* = .empty;
        }
        try list.value_ptr.append(self.allocator, instance_id);

        return instance;
    }

    fn registerInstance(
        self: *ScriptRuntime,
        entity_id: types.EntityId,
        instance: *types.ScriptInstance,
    ) !void {
        try self.instances.put(instance.id, instance);

        var list = try self.entity_scripts.getOrPut(entity_id);
        if (!list.found_existing) {
            list.value_ptr.* = .empty;
        }
        try list.value_ptr.append(self.allocator, instance.id);
    }

    /// 销毁脚本实例
    pub fn destroyInstance(self: *ScriptRuntime, instance: *types.ScriptInstance) void {
        instance.state = .destroyed;
        self.unregisterInstance(instance);

        // 释放错误信息
        if (instance.last_error.len > 0) {
            self.allocator.free(instance.last_error);
            instance.last_error = &.{};
        }

        if (self.getVM(instance.language)) |vm| {
            vm.destroyInstance(instance);
        } else {
            self.allocator.destroy(instance);
        }
    }

    /// 获取 VM
    pub fn getVM(self: *ScriptRuntime, language: types.ScriptLanguage) ?*vm_mod.ScriptVM {
        return self.vms.get(language);
    }

    /// 获取实体的所有脚本实例
    pub fn getEntityScripts(self: *ScriptRuntime, entity_id: types.EntityId) ?[]const types.ScriptInstanceId {
        const list = self.entity_scripts.getPtr(entity_id) orelse return null;
        return list.items;
    }

    pub fn applyEntityScriptParameters(self: *ScriptRuntime, world: *world_mod.World, entity_id: types.EntityId) !bool {
        // With the pull-based parameter model, scripts read parameters on
        // demand via guava.getParameterFloat/Int/Bool.  This function serves
        // as a validation hook: it confirms the entity has a script with
        // non-empty parameters and that a running instance exists.
        _ = self;
        const entity = world.getEntity(entity_id) orelse return false;
        if (entity.script) |script| {
            if (script.parameters.len > 0 and script.instance_id != null) return true;
        }
        for (entity.scripts) |script| {
            if (script.parameters.len > 0 and script.instance_id != null) return true;
        }
        return false;
    }

    /// 重新加载脚本
    pub fn reloadScript(self: *ScriptRuntime, handle: handles.ScriptHandle) !void {
        const world = self.world orelse return types.ScriptError.NotFound;
        const resource = world.resources.scriptMutable(handle) orelse return types.ScriptError.NotFound;
        const vm = self.getVM(resource.language) orelse return types.ScriptError.InvalidLanguage;

        try prepareResourceForLoad(self, handle, resource, true);

        const csharp_artifact_path = csharpArtifactPath(resource);
        const reloads_from_artifact = resource.language == .csharp and csharp_artifact_path != null;

        var refreshed_source: ?[]u8 = null;
        var refreshed_mtime = resource.last_modified;
        if (!reloads_from_artifact and resource.source_path.len != 0) {
            refreshed_source = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, resource.source_path, self.allocator, .limited(8 * 1024 * 1024));
            errdefer if (refreshed_source) |bytes| self.allocator.free(bytes);
            refreshed_mtime = readFileMtime(resource.source_path) catch resource.last_modified;
        } else if (csharp_artifact_path) |artifact_path| {
            refreshed_mtime = readFileMtime(artifact_path) catch resource.last_modified;
        }

        if (refreshed_source) |bytes| {
            self.allocator.free(resource.source);
            resource.source = bytes;
            resource.last_modified = refreshed_mtime;
            refreshed_source = null;
        } else if (resource.language == .csharp and csharp_artifact_path != null) {
            resource.last_modified = refreshed_mtime;
        }

        vm.load(resource) catch |err| {
            self.recordEvent(.{
                .script_handle = handle,
                .phase = .load,
                .severity = .@"error",
                .message = vm.getError(),
            });
            return err;
        };
        self.recordEvent(.{
            .script_handle = handle,
            .phase = .load,
            .severity = .info,
            .message = switch (resource.language) {
                .csharp => if (csharp_artifact_path != null) "reloaded csharp nativeaot library" else "reloaded csharp gameplay source",
                .zig => "reloaded zig gameplay source",
            },
        });

        for (world.entities.items) |*entity| {
            if (entity.script) |*script| {
                if (script.script_handle != handle) {
                    continue;
                }

                if (script.instance_id) |instance_id| {
                    if (self.instances.get(instance_id)) |instance| {
                        self.destroyTrackedInstance(world, instance, true);
                    }
                    script.instance_id = null;
                }
            }
        }
    }

    pub fn reconcileWorld(self: *ScriptRuntime, world: *anyopaque) void {
        const world_ptr = @as(*world_mod.World, @ptrCast(@alignCast(world)));

        var stale_instances = std.ArrayList(*types.ScriptInstance).empty;
        defer stale_instances.deinit(self.allocator);

        var instance_iter = self.instances.valueIterator();
        while (instance_iter.next()) |instance_ptr| {
            const instance = instance_ptr.*;
            if (!self.instanceMatchesWorld(world_ptr, instance)) {
                stale_instances.append(self.allocator, instance) catch |err| {
                    log.err("Failed to queue stale script instance {}: {}", .{ instance.id, err });
                    return;
                };
            }
        }

        for (stale_instances.items) |instance| {
            if (self.instances.contains(instance.id)) {
                self.destroyTrackedInstance(world_ptr, instance, true);
            }
        }

        for (world_ptr.entities.items) |*entity| {
            // Support legacy single-script field
            if (entity.script) |*script| {
                self.ensureEntityScriptInstance(world_ptr, entity, script);
            }
            // Support multi-script array
            for (entity.scripts) |*script| {
                self.ensureEntityScriptInstance(world_ptr, entity, @constCast(script));
            }
        }
    }

    /// 调用所有脚本的 OnInit
    pub fn callInitAll(self: *ScriptRuntime, world: *anyopaque) void {
        self.reconcileWorld(world);
    }

    /// 调用所有脚本的 OnDestroy
    pub fn callDestroyAll(self: *ScriptRuntime, world: *anyopaque) void {
        const world_ptr = @as(*world_mod.World, @ptrCast(@alignCast(world)));
        var to_destroy = std.ArrayList(*types.ScriptInstance).empty;
        defer to_destroy.deinit(self.allocator);

        var iter = self.instances.valueIterator();
        while (iter.next()) |instance| {
            to_destroy.append(self.allocator, instance.*) catch |err| {
                log.err("Failed to queue script instance for shutdown: {}", .{err});
                return;
            };
        }

        for (to_destroy.items) |instance| {
            self.destroyTrackedInstance(world_ptr, instance, true);
        }
    }

    /// 检查热重载
    pub fn checkHotReload(self: *ScriptRuntime) void {
        if (self.hot_reload) |*hr| {
            hr.checkForChanges();
            hr.processPendingReload();
        }
    }

    fn unregisterInstance(self: *ScriptRuntime, instance: *types.ScriptInstance) void {
        _ = self.instances.remove(instance.id);

        if (self.entity_scripts.getPtr(instance.entity_id)) |list| {
            for (list.items, 0..) |id, i| {
                if (id == instance.id) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
            if (list.items.len == 0) {
                list.deinit(self.allocator);
                _ = self.entity_scripts.remove(instance.entity_id);
            }
        }
    }

    fn instanceMatchesWorld(self: *ScriptRuntime, world: *world_mod.World, instance: *const types.ScriptInstance) bool {
        _ = self;
        const entity = world.getEntityConst(instance.entity_id) orelse return false;
        // Check legacy single-script field
        if (entity.script) |script| {
            if (script.enabled and script.script_handle != null) {
                const script_language: types.ScriptLanguage = @enumFromInt(@intFromEnum(script.language));
                if (script.instance_id == instance.id and
                    script.script_handle.? == instance.script_handle and
                    script_language == instance.language) return true;
            }
        }
        // Check multi-script array
        for (entity.scripts) |script| {
            if (!script.enabled or script.script_handle == null) continue;
            const script_language: types.ScriptLanguage = @enumFromInt(@intFromEnum(script.language));
            if (script.instance_id == instance.id and
                script.script_handle.? == instance.script_handle and
                script_language == instance.language) return true;
        }
        return false;
    }

    fn destroyTrackedInstance(
        self: *ScriptRuntime,
        world: *world_mod.World,
        instance: *types.ScriptInstance,
        invoke_destroy: bool,
    ) void {
        if (world.getEntity(instance.entity_id)) |entity| {
            if (entity.script) |*script| {
                if (script.instance_id == instance.id) {
                    script.instance_id = null;
                }
            }
            for (entity.scripts) |*script| {
                if (script.instance_id == instance.id) {
                    script.instance_id = null;
                }
            }
        }

        if (invoke_destroy) {
            if (self.getVM(instance.language)) |vm| {
                var ctx = context.ScriptContext{
                    .entity = instance.entity_id,
                    .world = world,
                    .instance = instance,
                    .allocator = self.allocator,
                    .command_queue = self.command_queue,
                    .blackboard = &self.blackboard,
                    .save_root_path = self.save_root_path,
                };
                vm.callDestroy(instance, &ctx) catch |err| {
                    log.err("Script destroy error for entity {}: {}", .{ instance.entity_id, err });
                    self.recordEvent(.{
                        .script_handle = instance.script_handle,
                        .entity_id = instance.entity_id,
                        .phase = .destroy,
                        .severity = .@"error",
                        .message = vm.getError(),
                    });
                };
            }
        }

        self.destroyInstance(instance);
    }

    fn ensureEntityScriptInstance(
        self: *ScriptRuntime,
        world: *world_mod.World,
        entity: *world_mod.Entity,
        script: *components.Script,
    ) void {
        const script_handle = script.script_handle orelse {
            script.instance_id = null;
            return;
        };
        if (!script.enabled) {
            script.instance_id = null;
            return;
        }

        if (script.instance_id) |instance_id| {
            if (self.instances.get(instance_id)) |instance| {
                const script_language: types.ScriptLanguage = @enumFromInt(@intFromEnum(script.language));
                if (instance.entity_id == entity.id and
                    instance.script_handle == script_handle and
                    instance.language == script_language)
                {
                    return;
                }
            }
            script.instance_id = null;
        }

        const script_language: types.ScriptLanguage = @enumFromInt(@intFromEnum(script.language));
        const script_resource = world.resources.scriptMutable(script_handle) orelse {
            log.err("Script handle {} not found for entity {}", .{ script_handle, entity.id });
            return;
        };
        const vm = self.getVM(script_language) orelse {
            log.err("No VM available for script language {} on entity {}", .{ script_language, entity.id });
            return;
        };

        prepareResourceForLoad(self, script_handle, script_resource, false) catch |err| {
            log.err("Failed to prepare script resource for entity {}: {}", .{ entity.id, err });
            return;
        };

        vm.load(script_resource) catch |err| {
            log.err("Failed to load script for entity {}: {}", .{ entity.id, err });
            self.recordEvent(.{
                .script_handle = script_handle,
                .entity_id = entity.id,
                .phase = .load,
                .severity = .@"error",
                .message = vm.getError(),
            });
            return;
        };

        var ctx = context.ScriptContext{
            .entity = entity.id,
            .world = world,
            .instance = undefined,
            .allocator = self.allocator,
            .command_queue = self.command_queue,
            .blackboard = &self.blackboard,
            .save_root_path = self.save_root_path,
        };

        const instance = vm.createInstance(&ctx) catch |err| {
            log.err("Failed to create script instance for entity {}: {}", .{ entity.id, err });
            self.recordEvent(.{
                .script_handle = script_handle,
                .entity_id = entity.id,
                .phase = .load,
                .severity = .@"error",
                .message = vm.getError(),
            });
            return;
        };

        instance.id = self.next_instance_id;
        self.next_instance_id += 1;
        instance.entity_id = entity.id;
        instance.script_handle = script_handle;
        instance.language = script_language;
        ctx.instance = instance;

        self.registerInstance(entity.id, instance) catch |err| {
            log.err("Failed to register script instance for entity {}: {}", .{ entity.id, err });
            vm.destroyInstance(instance);
            return;
        };

        script.instance_id = instance.id;
        vm.callInit(instance, &ctx) catch |err| {
            log.err("Script init error for entity {}: {}", .{ entity.id, err });
            self.recordEvent(.{
                .script_handle = script_handle,
                .entity_id = entity.id,
                .phase = .init,
                .severity = .@"error",
                .message = vm.getError(),
            });
            instance.state = .failed;
            return;
        };
        self.recordEvent(.{
            .script_handle = script_handle,
            .entity_id = entity.id,
            .phase = .init,
            .severity = .info,
            .message = "script instance initialized",
        });
    }
};

fn prepareResourceForLoad(
    self: *ScriptRuntime,
    handle: handles.ScriptHandle,
    resource: *script_resource_mod.ScriptResource,
    force_refresh: bool,
) !void {
    switch (resource.language) {
        .csharp => try prepareCSharpResourceForLoad(self, handle, resource, force_refresh),
        else => {},
    }
}

fn prepareCSharpResourceForLoad(
    self: *ScriptRuntime,
    handle: handles.ScriptHandle,
    resource: *script_resource_mod.ScriptResource,
    force_refresh: bool,
) !void {
    if (resource.source_path.len == 0) {
        if (csharpArtifactPath(resource)) |artifact_path| {
            resource.last_modified = readFileMtime(artifact_path) catch resource.last_modified;
        }
        return;
    }

    if (csharp_toolchain.isDotnetProjectPath(resource.source_path)) {
        try registerCSharpProjectHotReload(self, handle, resource.source_path);

        const existing_artifact = csharpArtifactPath(resource);
        const should_publish = force_refresh or existing_artifact == null or try csharp_toolchain.projectNeedsPublish(
            resource.source_path,
            existing_artifact.?,
        );

        if (should_publish) {
            self.recordEvent(.{
                .script_handle = handle,
                .phase = .compile,
                .severity = .info,
                .message = "publishing csharp nativeaot project",
            });

            const published_artifact = csharp_toolchain.ensurePublishedNativeAotLibraryAlloc(
                self.allocator,
                resource.source_path,
                existing_artifact,
            ) catch |err| {
                self.recordEvent(.{
                    .script_handle = handle,
                    .phase = .compile,
                    .severity = .@"error",
                    .message = csharpToolchainErrorMessage(err),
                });
                return mapCSharpToolchainError(err);
            };
            defer self.allocator.free(published_artifact);

            try replaceOwnedSlice(self.allocator, &resource.artifact_path, published_artifact);
            self.recordEvent(.{
                .script_handle = handle,
                .phase = .compile,
                .severity = .info,
                .message = "published csharp nativeaot library",
            });
        }

        if (resource.artifact_path.len != 0) {
            resource.last_modified = readFileMtime(resource.artifact_path) catch resource.last_modified;
        } else {
            resource.last_modified = readFileMtime(resource.source_path) catch resource.last_modified;
        }
        return;
    }

    if (csharpArtifactPath(resource)) |artifact_path| {
        resource.last_modified = readFileMtime(artifact_path) catch resource.last_modified;
    } else {
        resource.last_modified = readFileMtime(resource.source_path) catch resource.last_modified;
    }
}

fn registerCSharpProjectHotReload(
    self: *ScriptRuntime,
    handle: handles.ScriptHandle,
    project_path: []const u8,
) !void {
    if (self.hot_reload) |*hr| {
        const watch_paths = try csharp_toolchain.collectProjectWatchPathsAlloc(self.allocator, project_path);
        defer {
            for (watch_paths) |path| {
                self.allocator.free(path);
            }
            self.allocator.free(watch_paths);
        }

        for (watch_paths) |path| {
            try hr.registerScript(path, handle);
        }
    }
}

fn mapCSharpToolchainError(err: anyerror) types.ScriptError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => types.ScriptError.CompileError,
    };
}

fn csharpToolchainErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.DotnetNotFound => "dotnet sdk not found for csharp nativeaot publish",
        error.UnsupportedPlatform => "current platform does not support csharp nativeaot publish",
        error.PublishFailed => "dotnet publish failed for csharp nativeaot project",
        error.ArtifactNotFound => "nativeaot publish completed but no shared library was found",
        else => @errorName(err),
    };
}

fn csharpArtifactPath(resource: *const script_resource_mod.ScriptResource) ?[]const u8 {
    if (resource.language != .csharp) {
        return null;
    }
    if (resource.artifact_path.len != 0) {
        return resource.artifact_path;
    }
    if (csharp_toolchain.isSharedLibraryPath(resource.source_path)) {
        return resource.source_path;
    }
    return null;
}

fn readFileMtime(path: []const u8) !i96 {
    const file = try std.Io.Dir.cwd().openFile(io_globals.global_io, path, .{});
    defer file.close(io_globals.global_io);

    const stat = try file.stat(io_globals.global_io);
    return stat.mtime.nanoseconds;
}

fn replaceOwnedSlice(allocator: std.mem.Allocator, target: *[]const u8, next: []const u8) !void {
    const owned = try allocator.dupe(u8, next);
    allocator.free(target.*);
    target.* = owned;
}

test "script runtime reconciles instance lifecycle against world state" {
    var runtime = ScriptRuntime.init(std.testing.allocator, .{
        .enable_hot_reload = false,
    });
    defer runtime.deinit();
    try runtime.initVMs();

    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();
    runtime.bindWorld(&world);

    const first_handle = try world.resources.createScript(.{
        .source = "//!guava builtin=rotate axis=y speed_deg=90 local=true\n",
        .language = .zig,
    });
    const second_handle = try world.resources.createScript(.{
        .source = "//!guava builtin=patrol speed=1.0 waypoints=0,0,0;1,0,0\n",
        .language = .zig,
    });

    const entity_id = try world.createEntity(.{
        .name = "ScriptedEntity",
        .script = .{
            .script_handle = first_handle,
            .language = .zig,
        },
    });

    runtime.reconcileWorld(&world);
    try std.testing.expectEqual(@as(usize, 1), runtime.instances.count());
    const first_instance_id = world.getEntityConst(entity_id).?.script.?.instance_id.?;
    try std.testing.expect(runtime.instances.contains(first_instance_id));

    world.getEntity(entity_id).?.script.?.enabled = false;
    runtime.reconcileWorld(&world);
    try std.testing.expectEqual(@as(usize, 0), runtime.instances.count());
    try std.testing.expectEqual(@as(?u64, null), world.getEntityConst(entity_id).?.script.?.instance_id);

    world.getEntity(entity_id).?.script.?.enabled = true;
    runtime.reconcileWorld(&world);
    try std.testing.expectEqual(@as(usize, 1), runtime.instances.count());
    const second_instance_id = world.getEntityConst(entity_id).?.script.?.instance_id.?;
    try std.testing.expect(second_instance_id != first_instance_id);

    world.getEntity(entity_id).?.script.?.script_handle = second_handle;
    runtime.reconcileWorld(&world);
    try std.testing.expectEqual(@as(usize, 1), runtime.instances.count());
    const third_instance_id = world.getEntityConst(entity_id).?.script.?.instance_id.?;
    try std.testing.expect(third_instance_id != second_instance_id);

    try std.testing.expect(world.destroyEntity(entity_id));
    runtime.reconcileWorld(&world);
    try std.testing.expectEqual(@as(usize, 0), runtime.instances.count());
}

test "script runtime publishes csharp project and loads nativeaot gameplay vm" {
    if (!shouldRunNativeAotIntegrationTests()) return error.SkipZigTest;

    var runtime = ScriptRuntime.init(std.testing.allocator, .{
        .enable_hot_reload = true,
    });
    defer runtime.deinit();
    try runtime.initVMs();

    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();
    runtime.bindWorld(&world);

    const script_handle = try world.resources.createScript(.{
        .source = "",
        .language = .csharp,
        .description = "NativeAOT Runtime Test",
        .source_path = "examples/csharp/nativeaot_mover/GuavaNativeAotMover.csproj",
    });

    const entity_id = try world.createEntity(.{
        .name = "RuntimeNativeAotMover",
        .script = .{
            .script_handle = script_handle,
            .language = .csharp,
        },
    });

    runtime.reconcileWorld(&world);

    const entity = world.getEntityConst(entity_id).?;
    const instance_id = entity.script.?.instance_id orelse return error.ScriptInstanceNotCreated;
    const instance = runtime.instances.get(instance_id) orelse return error.ScriptInstanceNotFound;
    const vm = runtime.getVM(.csharp) orelse return error.ScriptVmMissing;
    const resource = world.resources.script(script_handle).?;

    try std.testing.expect(resource.artifact_path.len != 0);
    try std.testing.expect(csharp_toolchain.isSharedLibraryPath(resource.artifact_path));

    var ctx = context.ScriptContext{
        .entity = entity_id,
        .world = &world,
        .instance = instance,
        .allocator = std.testing.allocator,
        .delta_time = 1.0,
    };

    try vm.callUpdate(instance, &ctx, 1.0);

    const moved = world.getEntity(entity_id).?.local_transform.translation;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), moved[0], 0.0001);

    const hr = runtime.hot_reload orelse return error.HotReloadMissing;
    try std.testing.expect(hr.watched_scripts.contains("examples/csharp/nativeaot_mover/GuavaNativeAotMover.csproj"));
    try std.testing.expect(hr.watched_scripts.contains("examples/csharp/nativeaot_mover/ScriptExports.cs"));
}

fn shouldRunNativeAotIntegrationTests() bool {
    const flag = std.process.getEnvVarOwned(std.testing.allocator, "GUAVA_RUN_NATIVEAOT_TESTS") catch return false;
    defer std.testing.allocator.free(flag);
    return std.mem.eql(u8, flag, "1");
}
