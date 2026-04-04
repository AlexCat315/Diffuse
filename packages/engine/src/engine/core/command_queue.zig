const std = @import("std");
const command_mod = @import("command.zig");
const scene_mod = @import("../scene/scene.zig");
const components_mod = @import("../scene/components.zig");

const QueuedCommand = struct {
    source: command_mod.CommandSource = .human,
    meta: command_mod.CommandMeta = .{},
    command: command_mod.Command,

    fn deinit(self: *QueuedCommand, allocator: std.mem.Allocator) void {
        self.command.deinit(allocator);
        self.meta.deinit(allocator);
        self.* = undefined;
    }
};

pub const CommandQueue = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(QueuedCommand) = .empty,
    max_pending: usize = 1000,

    pub fn init(allocator: std.mem.Allocator) CommandQueue {
        return .{
            .allocator = allocator,
            .commands = .empty,
        };
    }

    pub fn deinit(self: *CommandQueue) void {
        for (self.commands.items) |*queued| {
            queued.deinit(self.allocator);
        }
        self.commands.deinit(self.allocator);
    }

    pub fn clear(self: *CommandQueue) void {
        for (self.commands.items) |*queued| {
            queued.deinit(self.allocator);
        }
        self.commands.clearRetainingCapacity();
    }

    pub fn setMaxPending(self: *CommandQueue, max: usize) void {
        self.max_pending = max;
    }

    pub fn len(self: *const CommandQueue) usize {
        return self.commands.items.len;
    }

    pub fn isFull(self: *const CommandQueue) bool {
        return self.commands.items.len >= self.max_pending;
    }

    fn cloneMetaOrDefault(
        self: *CommandQueue,
        meta: ?*const command_mod.CommandMeta,
    ) !command_mod.CommandMeta {
        if (meta) |resolved| {
            return resolved.cloneAlloc(self.allocator);
        }
        return .{};
    }

    pub fn appendOwnedCommandWithSourceAndMeta(
        self: *CommandQueue,
        command: command_mod.Command,
        source: command_mod.CommandSource,
        meta: ?*const command_mod.CommandMeta,
    ) !void {
        if (self.isFull()) {
            return error.QueueFull;
        }
        var owned_meta = try self.cloneMetaOrDefault(meta);
        errdefer owned_meta.deinit(self.allocator);
        try self.commands.append(self.allocator, .{
            .source = source,
            .meta = owned_meta,
            .command = command,
        });
    }

    fn updateQueuedCommandMeta(
        self: *CommandQueue,
        queued: *QueuedCommand,
        source: command_mod.CommandSource,
        meta: ?*const command_mod.CommandMeta,
    ) !void {
        var owned_meta = try self.cloneMetaOrDefault(meta);
        errdefer owned_meta.deinit(self.allocator);
        queued.meta.deinit(self.allocator);
        queued.source = source;
        queued.meta = owned_meta;
    }

    pub fn enqueueCreateEntity(self: *CommandQueue, spec: command_mod.CreateEntitySpec) !void {
        return self.enqueueCreateEntityWithSource(spec, .human);
    }

    pub fn enqueueCreateEntityWithSource(
        self: *CommandQueue,
        spec: command_mod.CreateEntitySpec,
        source: command_mod.CommandSource,
    ) !void {
        var command: command_mod.Command = .{
            .create_entity = .{
                .name = try self.allocator.dupe(u8, spec.name),
                .parent = spec.parent,
                .local_transform = spec.local_transform,
                .camera = spec.camera,
                .mesh = spec.mesh,
                .material = spec.material,
                .light = spec.light,
                .vfx = spec.vfx,
                .visible = spec.visible,
                .editor_only = spec.editor_only,
                .is_folder = spec.is_folder,
            },
        };
        errdefer command.deinit(self.allocator);
        try self.appendOwnedCommandWithSourceAndMeta(command, source, null);
    }

    pub fn enqueueDeleteEntity(self: *CommandQueue, entity_id: scene_mod.EntityId) !void {
        return self.enqueueDeleteEntityWithSource(entity_id, .human);
    }

    pub fn enqueueDeleteEntityWithSource(
        self: *CommandQueue,
        entity_id: scene_mod.EntityId,
        source: command_mod.CommandSource,
    ) !void {
        var command: command_mod.Command = .{
            .delete_entity = .{ .entity_id = entity_id },
        };
        errdefer command.deinit(self.allocator);
        try self.appendOwnedCommandWithSourceAndMeta(command, source, null);
    }

    pub fn enqueueRenameEntity(self: *CommandQueue, entity_id: scene_mod.EntityId, name: []const u8) !void {
        return self.enqueueRenameEntityWithSource(entity_id, name, .human);
    }

    pub fn enqueueRenameEntityWithSource(
        self: *CommandQueue,
        entity_id: scene_mod.EntityId,
        name: []const u8,
        source: command_mod.CommandSource,
    ) !void {
        var command: command_mod.Command = .{
            .rename_entity = .{
                .entity_id = entity_id,
                .name = try self.allocator.dupe(u8, name),
            },
        };
        errdefer command.deinit(self.allocator);
        try self.appendOwnedCommandWithSourceAndMeta(command, source, null);
    }

    pub fn enqueueSetParent(self: *CommandQueue, entity_id: scene_mod.EntityId, parent_id: ?scene_mod.EntityId) !void {
        return self.enqueueSetParentWithSource(entity_id, parent_id, .human);
    }

    pub fn enqueueSetParentWithSource(
        self: *CommandQueue,
        entity_id: scene_mod.EntityId,
        parent_id: ?scene_mod.EntityId,
        source: command_mod.CommandSource,
    ) !void {
        var command: command_mod.Command = .{
            .set_parent = .{
                .entity_id = entity_id,
                .parent_id = parent_id,
            },
        };
        errdefer command.deinit(self.allocator);
        try self.appendOwnedCommandWithSourceAndMeta(command, source, null);
    }

    pub fn enqueueSetLocalTransform(self: *CommandQueue, entity_id: scene_mod.EntityId, transform: components_mod.Transform) !void {
        return self.enqueueSetLocalTransformWithSource(entity_id, transform, .human);
    }

    pub fn enqueueSetLocalTransformWithSource(
        self: *CommandQueue,
        entity_id: scene_mod.EntityId,
        transform: components_mod.Transform,
        source: command_mod.CommandSource,
    ) !void {
        if (try self.tryCoalesceTransform(.set_local_transform, entity_id, transform, source, null)) {
            return;
        }
        var command: command_mod.Command = .{
            .set_local_transform = .{
                .entity_id = entity_id,
                .transform = transform,
            },
        };
        errdefer command.deinit(self.allocator);
        try self.appendOwnedCommandWithSourceAndMeta(command, source, null);
    }

    pub fn enqueueSetWorldTransform(self: *CommandQueue, entity_id: scene_mod.EntityId, transform: components_mod.Transform) !void {
        return self.enqueueSetWorldTransformWithSource(entity_id, transform, .human);
    }

    pub fn enqueueSetWorldTransformWithSource(
        self: *CommandQueue,
        entity_id: scene_mod.EntityId,
        transform: components_mod.Transform,
        source: command_mod.CommandSource,
    ) !void {
        if (try self.tryCoalesceTransform(.set_world_transform, entity_id, transform, source, null)) {
            return;
        }
        var command: command_mod.Command = .{
            .set_world_transform = .{
                .entity_id = entity_id,
                .transform = transform,
            },
        };
        errdefer command.deinit(self.allocator);
        try self.appendOwnedCommandWithSourceAndMeta(command, source, null);
    }

    pub fn enqueueSetVisible(self: *CommandQueue, entity_id: scene_mod.EntityId, visible: bool) !void {
        return self.enqueueSetVisibleWithSource(entity_id, visible, .human);
    }

    pub fn enqueueSetVisibleWithSource(
        self: *CommandQueue,
        entity_id: scene_mod.EntityId,
        visible: bool,
        source: command_mod.CommandSource,
    ) !void {
        var command: command_mod.Command = .{
            .set_visible = .{
                .entity_id = entity_id,
                .visible = visible,
            },
        };
        errdefer command.deinit(self.allocator);
        try self.appendOwnedCommandWithSourceAndMeta(command, source, null);
    }

    pub fn latestPendingLocalTransform(self: *const CommandQueue, entity_id: scene_mod.EntityId) ?components_mod.Transform {
        var index = self.commands.items.len;
        while (index > 0) {
            index -= 1;
            switch (self.commands.items[index].command) {
                .set_local_transform => |set_transform| {
                    if (set_transform.entity_id == entity_id) {
                        return set_transform.transform;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    pub fn executeAll(self: *CommandQueue, world: *scene_mod.World) ![]command_mod.ExecutionResult {
        const command_count = self.commands.items.len;
        if (command_count == 0) {
            return try self.allocator.alloc(command_mod.ExecutionResult, 0);
        }

        var results = try self.allocator.alloc(command_mod.ExecutionResult, command_count);
        errdefer self.allocator.free(results);

        for (self.commands.items, 0..) |*queued, index| {
            results[index] = try executeCommandWithMeta(world, queued.command, queued.source, &queued.meta);
            queued.deinit(self.allocator);
        }
        self.commands.clearRetainingCapacity();

        return results;
    }

    fn tryCoalesceTransform(
        self: *CommandQueue,
        comptime tag: std.meta.Tag(command_mod.Command),
        entity_id: scene_mod.EntityId,
        transform: components_mod.Transform,
        source: command_mod.CommandSource,
        meta: ?*const command_mod.CommandMeta,
    ) !bool {
        if (self.commands.items.len == 0) {
            return false;
        }

        const last = &self.commands.items[self.commands.items.len - 1];
        switch (last.command) {
            .set_local_transform => |*pending| {
                if (pending.entity_id != entity_id) {
                    return false;
                }
                if (tag == .set_local_transform) {
                    pending.transform = transform;
                } else {
                    last.command = .{
                        .set_world_transform = .{
                            .entity_id = entity_id,
                            .transform = transform,
                        },
                    };
                }
                try self.updateQueuedCommandMeta(last, source, meta);
                return true;
            },
            .set_world_transform => |*pending| {
                if (pending.entity_id != entity_id) {
                    return false;
                }
                if (tag == .set_world_transform) {
                    pending.transform = transform;
                } else {
                    last.command = .{
                        .set_local_transform = .{
                            .entity_id = entity_id,
                            .transform = transform,
                        },
                    };
                }
                try self.updateQueuedCommandMeta(last, source, meta);
                return true;
            },
            else => return false,
        }
    }
};

fn executeCommand(world: *scene_mod.World, command: command_mod.Command) !command_mod.ExecutionResult {
    return switch (command) {
        .create_entity => |create| blk: {
            const entity_id = world.createEntity(.{
                .name = create.name,
                .parent = create.parent,
                .local_transform = create.local_transform,
                .camera = create.camera,
                .mesh = create.mesh,
                .material = create.material,
                .light = create.light,
                .vfx = create.vfx,
                .visible = create.visible,
                .editor_only = create.editor_only,
                .is_folder = create.is_folder,
            }) catch |err| {
                break :blk .{
                    .err = mapWorldError(err),
                };
            };
            break :blk .{
                .changed = true,
                .entity_id = entity_id,
            };
        },
        .delete_entity => |delete| blk: {
            const existed = world.hasEntity(delete.entity_id);
            break :blk .{
                .changed = if (existed) world.destroyEntity(delete.entity_id) else false,
                .entity_id = delete.entity_id,
                .err = if (existed) null else .entity_not_found,
            };
        },
        .rename_entity => |rename| blk: {
            const changed = world.renameEntity(rename.entity_id, rename.name) catch |err| {
                break :blk .{
                    .entity_id = rename.entity_id,
                    .err = mapWorldError(err),
                };
            };
            break :blk .{
                .changed = changed,
                .entity_id = rename.entity_id,
                .err = if (changed or world.hasEntity(rename.entity_id)) null else .entity_not_found,
            };
        },
        .set_parent => |set_parent| blk: {
            const changed = world.setParent(set_parent.entity_id, set_parent.parent_id) catch |err| {
                break :blk .{
                    .entity_id = set_parent.entity_id,
                    .err = mapWorldError(err),
                };
            };
            break :blk .{
                .changed = changed,
                .entity_id = set_parent.entity_id,
                .err = if (changed or world.hasEntity(set_parent.entity_id)) null else .entity_not_found,
            };
        },
        .set_local_transform => |set_transform| .{
            .changed = world.setEntityLocalTransform(set_transform.entity_id, set_transform.transform),
            .entity_id = set_transform.entity_id,
            .err = if (world.hasEntity(set_transform.entity_id)) null else .entity_not_found,
        },
        .set_world_transform => |set_transform| .{
            .changed = world.setEntityWorldTransform(set_transform.entity_id, set_transform.transform),
            .entity_id = set_transform.entity_id,
            .err = if (world.hasEntity(set_transform.entity_id)) null else .entity_not_found,
        },
        .set_visible => |set_visible| blk: {
            const existed = world.hasEntity(set_visible.entity_id);
            if (!existed) {
                break :blk .{
                    .entity_id = set_visible.entity_id,
                    .err = .entity_not_found,
                };
            }
            const changed = world.setEntityVisible(set_visible.entity_id, set_visible.visible);
            break :blk .{
                .entity_id = set_visible.entity_id,
                .changed = changed,
            };
        },
    };
}

fn commandPrimaryEntityId(command: command_mod.Command) ?scene_mod.EntityId {
    return switch (command) {
        .create_entity => null,
        .delete_entity => |value| value.entity_id,
        .rename_entity => |value| value.entity_id,
        .set_parent => |value| value.entity_id,
        .set_local_transform => |value| value.entity_id,
        .set_world_transform => |value| value.entity_id,
        .set_visible => |value| value.entity_id,
    };
}

fn executeCommandWithMeta(
    world: *scene_mod.World,
    command: command_mod.Command,
    source: command_mod.CommandSource,
    meta: ?*const command_mod.CommandMeta,
) !command_mod.ExecutionResult {
    if (meta) |resolved_meta| {
        if (resolved_meta.base_revision) |base_revision| {
            const current_revision = world.sceneRevision();
            if (base_revision != current_revision) {
                return .{
                    .changed = false,
                    .entity_id = commandPrimaryEntityId(command),
                    .err = .base_revision_conflict,
                    .source = source,
                };
            }
        }
    }

    var result = try executeCommand(world, command);
    result.source = source;
    return result;
}

pub fn executeOne(world: *scene_mod.World, command: command_mod.Command) !command_mod.ExecutionResult {
    return try executeOneWithMeta(world, command, .human, null);
}

pub fn executeOneWithSource(
    world: *scene_mod.World,
    command: command_mod.Command,
    source: command_mod.CommandSource,
) !command_mod.ExecutionResult {
    return try executeOneWithMeta(world, command, source, null);
}

pub fn executeOneWithMeta(
    world: *scene_mod.World,
    command: command_mod.Command,
    source: command_mod.CommandSource,
    meta: ?*const command_mod.CommandMeta,
) !command_mod.ExecutionResult {
    return try executeCommandWithMeta(world, command, source, meta);
}

fn mapWorldError(err: anyerror) command_mod.CommandError {
    return switch (err) {
        error.ParentNotFound => .parent_not_found,
        error.ParentCycleDetected => .parent_cycle_detected,
        error.EntityIdConflict => .entity_id_conflict,
        else => .entity_not_found,
    };
}

test "CommandQueue executes the minimal entity editing loop" {
    var queue = CommandQueue.init(std.testing.allocator);
    defer queue.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try queue.enqueueCreateEntity(.{
        .name = "QueuedRoot",
    });
    const created = try queue.executeAll(&world);
    defer std.testing.allocator.free(created);

    try std.testing.expectEqual(@as(usize, 1), created.len);
    try std.testing.expect(created[0].ok());
    const entity_id = created[0].entity_id.?;
    try std.testing.expect(world.hasEntity(entity_id));

    try queue.enqueueRenameEntity(entity_id, "QueuedRootRenamed");
    try queue.enqueueSetVisible(entity_id, false);
    try queue.enqueueSetLocalTransform(entity_id, .{
        .translation = .{ 1.0, 2.0, 3.0 },
    });
    const updated = try queue.executeAll(&world);
    defer std.testing.allocator.free(updated);

    try std.testing.expectEqual(@as(usize, 3), updated.len);
    try std.testing.expect(updated[0].ok());
    try std.testing.expect(updated[1].ok());
    try std.testing.expect(updated[2].ok());

    const entity = world.getEntityConst(entity_id).?;
    try std.testing.expectEqualStrings("QueuedRootRenamed", entity.name);
    try std.testing.expect(!entity.visible);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), entity.local_transform.translation[0], 0.0001);

    try queue.enqueueDeleteEntity(entity_id);
    const deleted = try queue.executeAll(&world);
    defer std.testing.allocator.free(deleted);

    try std.testing.expectEqual(@as(usize, 1), deleted.len);
    try std.testing.expect(deleted[0].ok());
    try std.testing.expect(deleted[0].changed);
    try std.testing.expect(!world.hasEntity(entity_id));
}

test "CommandQueue coalesces consecutive transform writes for the same entity" {
    var queue = CommandQueue.init(std.testing.allocator);
    defer queue.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{ .name = "Mover" });

    try queue.enqueueSetLocalTransform(entity_id, .{
        .translation = .{ 1.0, 0.0, 0.0 },
    });
    try queue.enqueueSetLocalTransform(entity_id, .{
        .translation = .{ 2.0, 0.0, 0.0 },
    });
    try std.testing.expectEqual(@as(usize, 1), queue.len());

    const results = try queue.executeAll(&world);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].ok());
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), world.getEntityConst(entity_id).?.local_transform.translation[0], 0.0001);
}

test "CommandQueue reports parent errors without aborting the batch" {
    var queue = CommandQueue.init(std.testing.allocator);
    defer queue.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{ .name = "Child" });
    try queue.enqueueSetParent(entity_id, 9999);
    try queue.enqueueRenameEntity(entity_id, "StillRuns");

    const results = try queue.executeAll(&world);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(command_mod.CommandError.parent_not_found, results[0].err.?);
    try std.testing.expect(results[1].ok());
    try std.testing.expectEqualStrings("StillRuns", world.getEntityConst(entity_id).?.name);
}

test "CommandQueue rejects stale base revision metadata" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    var meta = command_mod.CommandMeta{
        .approval = .auto,
        .base_revision = 1,
    };
    defer meta.deinit(std.testing.allocator);

    _ = try world.createEntity(.{ .name = "RevisionA" });
    world.updateHierarchy();
    try std.testing.expect(world.sceneRevision() != meta.base_revision.?);

    var command: command_mod.Command = .{
        .create_entity = .{
            .name = try std.testing.allocator.dupe(u8, "BlockedCreate"),
        },
    };
    defer command.deinit(std.testing.allocator);

    const result = try executeOneWithMeta(&world, command, .ai, &meta);

    try std.testing.expectEqual(command_mod.CommandError.base_revision_conflict, result.err.?);
    try std.testing.expect(!result.changed);
}

test "CommandQueue create_entity preserves attached components" {
    var queue = CommandQueue.init(std.testing.allocator);
    defer queue.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const mesh_handle = try world.resources.ensurePrimitiveMesh(.sphere);
    const material_handle = try world.resources.ensureDefaultMaterial();
    const vfx = components_mod.defaultVfx(.orbit);

    try queue.enqueueCreateEntity(.{
        .name = "QueuedActor",
        .local_transform = .{
            .translation = .{ 4.0, 2.0, -1.0 },
            .scale = .{ 0.5, 0.5, 0.5 },
        },
        .camera = .{
            .is_primary = true,
        },
        .mesh = .{
            .handle = mesh_handle,
            .primitive = .sphere,
        },
        .material = .{
            .handle = material_handle,
            .shading = .unlit,
            .base_color_factor = .{ 0.2, 0.4, 0.8, 1.0 },
        },
        .light = .{
            .kind = .spot,
            .intensity = 24.0,
            .range = 16.0,
        },
        .vfx = vfx,
        .editor_only = true,
    });

    const results = try queue.executeAll(&world);
    defer std.testing.allocator.free(results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(results[0].ok());

    const entity = world.getEntityConst(results[0].entity_id.?).?;
    try std.testing.expectEqualStrings("QueuedActor", entity.name);
    try std.testing.expect(entity.camera != null);
    try std.testing.expect(entity.camera.?.is_primary);
    try std.testing.expect(entity.mesh != null);
    try std.testing.expectEqual(mesh_handle, entity.mesh.?.handle.?);
    try std.testing.expectEqual(components_mod.Primitive.sphere, entity.mesh.?.primitive);
    try std.testing.expect(entity.material != null);
    try std.testing.expectEqual(material_handle, entity.material.?.handle.?);
    try std.testing.expectEqual(components_mod.ShadingModel.unlit, entity.material.?.shading);
    try std.testing.expectEqualDeep([4]f32{ 0.2, 0.4, 0.8, 1.0 }, entity.material.?.base_color_factor);
    try std.testing.expect(entity.light != null);
    try std.testing.expectEqual(components_mod.LightKind.spot, entity.light.?.kind);
    try std.testing.expectApproxEqAbs(@as(f32, 24.0), entity.light.?.intensity, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), entity.light.?.range, 0.0001);
    try std.testing.expect(entity.vfx != null);
    try std.testing.expectEqual(components_mod.VfxKind.orbit, entity.vfx.?.kind);
    try std.testing.expect(entity.editor_only);
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), entity.local_transform.translation[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), entity.local_transform.scale[0], 0.0001);
}
