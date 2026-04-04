const std = @import("std");
const scene_mod = @import("../scene/scene.zig");
const components_mod = @import("../scene/components.zig");

pub const CommandError = enum {
    entity_not_found,
    parent_not_found,
    parent_cycle_detected,
    entity_id_conflict,
    base_revision_conflict,
};

pub const CommandSource = enum {
    human,
    ai,
};

pub const ApprovalState = enum {
    auto,
    previewed,
    user_approved,
    rejected,
};

pub const CommandMeta = struct {
    actor: ?[]u8 = null,
    client: ?[]u8 = null,
    session: ?[]u8 = null,
    request: ?[]u8 = null,
    trace: ?[]u8 = null,
    approval: ApprovalState = .auto,
    base_revision: ?u64 = null,

    pub fn deinit(self: *CommandMeta, allocator: std.mem.Allocator) void {
        if (self.actor) |value| allocator.free(value);
        if (self.client) |value| allocator.free(value);
        if (self.session) |value| allocator.free(value);
        if (self.request) |value| allocator.free(value);
        if (self.trace) |value| allocator.free(value);
        self.* = .{};
    }

    pub fn cloneAlloc(self: CommandMeta, allocator: std.mem.Allocator) !CommandMeta {
        return .{
            .actor = if (self.actor) |value| try allocator.dupe(u8, value) else null,
            .client = if (self.client) |value| try allocator.dupe(u8, value) else null,
            .session = if (self.session) |value| try allocator.dupe(u8, value) else null,
            .request = if (self.request) |value| try allocator.dupe(u8, value) else null,
            .trace = if (self.trace) |value| try allocator.dupe(u8, value) else null,
            .approval = self.approval,
            .base_revision = self.base_revision,
        };
    }
};

pub const CreateEntitySpec = struct {
    name: []const u8,
    parent: ?scene_mod.EntityId = null,
    local_transform: components_mod.Transform = .{},
    camera: ?components_mod.Camera = null,
    mesh: ?components_mod.Mesh = null,
    material: ?components_mod.Material = null,
    light: ?components_mod.Light = null,
    vfx: ?components_mod.Vfx = null,
    visible: bool = true,
    editor_only: bool = false,
    is_folder: bool = false,
};

pub const ExecutionResult = struct {
    changed: bool = false,
    entity_id: ?scene_mod.EntityId = null,
    err: ?CommandError = null,
    source: CommandSource = .human,

    pub fn ok(self: ExecutionResult) bool {
        return self.err == null;
    }
};

pub const Command = union(enum) {
    create_entity: CreateEntity,
    delete_entity: DeleteEntity,
    rename_entity: RenameEntity,
    set_parent: SetParent,
    set_local_transform: SetTransform,
    set_world_transform: SetTransform,
    set_visible: SetVisible,

    pub const CreateEntity = struct {
        name: []u8,
        parent: ?scene_mod.EntityId = null,
        local_transform: components_mod.Transform = .{},
        camera: ?components_mod.Camera = null,
        mesh: ?components_mod.Mesh = null,
        material: ?components_mod.Material = null,
        light: ?components_mod.Light = null,
        vfx: ?components_mod.Vfx = null,
        visible: bool = true,
        editor_only: bool = false,
        is_folder: bool = false,
    };

    pub const DeleteEntity = struct {
        entity_id: scene_mod.EntityId,
    };

    pub const RenameEntity = struct {
        entity_id: scene_mod.EntityId,
        name: []u8,
    };

    pub const SetParent = struct {
        entity_id: scene_mod.EntityId,
        parent_id: ?scene_mod.EntityId,
    };

    pub const SetTransform = struct {
        entity_id: scene_mod.EntityId,
        transform: components_mod.Transform,
    };

    pub const SetVisible = struct {
        entity_id: scene_mod.EntityId,
        visible: bool,
    };

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .create_entity => |command| allocator.free(command.name),
            .rename_entity => |command| allocator.free(command.name),
            else => {},
        }
        self.* = undefined;
    }
};
