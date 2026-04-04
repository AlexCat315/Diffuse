const std = @import("std");
const command_mod = @import("../core/command.zig");
const command_queue_mod = @import("../core/command_queue.zig");
const core = @import("../core/layer.zig");
const protocol = @import("protocol.zig");
const scene_mod = @import("../scene/scene.zig");
const components = @import("../scene/components.zig");
const tools_mod = @import("tools.zig");

pub const Error = error{
    ToolNotFound,
    InvalidArguments,
    ShuttingDown,
};

pub const IntentSource = enum {
    human,
    ai,
};

pub const ManipulationMode = enum {
    none,
    translate,
    rotate,
    scale,
};

pub const TransformSpace = enum {
    local,
    world,
};

pub const CameraProjectionKind = enum {
    perspective,
    orthographic,
};

pub const DragPayloadKind = enum {
    entity,
    asset_model,
    asset_material,
    asset_texture,
    place_actor,
};

pub const PendingViewportDropKind = enum {
    asset,
    place_actor,
};

pub const PreviewAction = enum {
    created,
    updated,
    deleted,
};

fn timelineColorHexForSource(source: IntentSource) []const u8 {
    return switch (source) {
        .human => "#3A8FF0",
        .ai => "#9E54E6",
    };
}

fn timelineColorRgbaForSource(source: IntentSource) [4]f32 {
    return switch (source) {
        .human => .{ 0.23, 0.56, 0.94, 1.0 },
        .ai => .{ 0.62, 0.33, 0.90, 1.0 },
    };
}

fn commandSourceFromIntent(source: IntentSource) command_mod.CommandSource {
    return switch (source) {
        .human => .human,
        .ai => .ai,
    };
}

fn InlineText(comptime max_len: usize) type {
    return struct {
        buffer: [max_len]u8 = [_]u8{0} ** max_len,
        len: usize = 0,

        const Self = @This();

        fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn set(self: *Self, value: []const u8) void {
            self.len = @min(max_len, value.len);
            if (self.len == 0) {
                return;
            }
            @memcpy(self.buffer[0..self.len], value[0..self.len]);
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buffer[0..self.len];
        }
    };
}

const ShortText = InlineText(48);
const MediumText = InlineText(96);
const LongText = InlineText(224);
const MetaText = InlineText(96);

const StoredCommandMeta = struct {
    present: bool = false,
    actor: MetaText = .{},
    client: MetaText = .{},
    session: MetaText = .{},
    request: MetaText = .{},
    trace: MetaText = .{},
    approval: command_mod.ApprovalState = .auto,
    base_revision: ?u64 = null,

    fn assign(self: *StoredCommandMeta, meta: ?*const command_mod.CommandMeta) void {
        self.* = .{};
        const resolved = meta orelse return;
        if (resolved.actor) |value| self.actor.set(value);
        if (resolved.client) |value| self.client.set(value);
        if (resolved.session) |value| self.session.set(value);
        if (resolved.request) |value| self.request.set(value);
        if (resolved.trace) |value| self.trace.set(value);
        self.approval = resolved.approval;
        self.base_revision = resolved.base_revision;
        self.present = resolved.actor != null or
            resolved.client != null or
            resolved.session != null or
            resolved.request != null or
            resolved.trace != null or
            resolved.approval != .auto or
            resolved.base_revision != null;
    }
};

pub const CameraProjection = struct {
    kind: CameraProjectionKind = .perspective,
    fov_y_radians: f32 = 1.0471976,
    orthographic_size: f32 = 10.0,
    near_clip: f32 = 0.1,
    far_clip: f32 = 1000.0,
};

pub const DragPayload = struct {
    kind: DragPayloadKind,
    entity_id: ?scene_mod.EntityId = null,
    asset_name: MediumText = .{},
    asset_path: LongText = .{},
    actor_kind: ShortText = .{},
};

pub const SelectedAsset = struct {
    kind: ShortText = .{},
    id: MediumText = .{},
    name: MediumText = .{},
    path: LongText = .{},
};

pub const PendingViewportDrop = struct {
    kind: PendingViewportDropKind,
    asset_name: MediumText = .{},
    actor_kind: ShortText = .{},
    target_entity: ?scene_mod.EntityId = null,
    pixel: [2]u32 = .{ 0, 0 },
    has_pixel: bool = false,
    world_position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    has_world_position: bool = false,
};

pub const UpdateContextArgs = struct {
    primary_selection: ?scene_mod.EntityId = null,
    selected_entities: []const scene_mod.EntityId,
    staged_preview_selection: ?scene_mod.EntityId = null,
    manipulation_mode: ManipulationMode = .none,
    manipulation_entity: ?scene_mod.EntityId = null,
    transform_space: TransformSpace = .local,
    viewport_size: [2]u32 = .{ 0, 0 },
    viewport_hovered: bool = false,
    viewport_focused: bool = false,
    camera_transform: components.Transform = .{},
    camera_projection: CameraProjection = .{},
    viewport_center_ray: ?scene_mod.Ray = null,
    drag_payload: ?DragPayload = null,
    selected_asset: ?SelectedAsset = null,
    pending_viewport_drop: ?PendingViewportDrop = null,
};

const IntentEntry = struct {
    sequence: u64 = 0,
    source: IntentSource = .human,
    action: ShortText = .{},
    detail: LongText = .{},
    meta: StoredCommandMeta = .{},
};

const CommandTimelineEntry = struct {
    sequence: u64 = 0,
    source: IntentSource = .human,
    label: MediumText = .{},
    detail: LongText = .{},
    command_kind: ShortText = .{},
    meta: StoredCommandMeta = .{},
};

pub const CommandEntry = struct {
    tool_name: []u8,
    command: command_mod.Command,
    meta: command_mod.CommandMeta = .{},

    pub fn deinit(self: *CommandEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        self.command.deinit(allocator);
        self.meta.deinit(allocator);
        self.* = undefined;
    }
};

const StageCommandResult = struct {
    tool_name: ShortText = .{},
    changed: bool = false,
    entity_id: ?scene_mod.EntityId = null,
    err: ?command_mod.CommandError = null,
};

const PreviewEntity = struct {
    entity_id: ?scene_mod.EntityId = null,
    action: PreviewAction = .updated,
    name: MediumText = .{},
    world_transform: components.Transform = .{},
    has_world_transform: bool = false,
    visible: bool = true,
    parent_id: ?scene_mod.EntityId = null,
    has_mesh: bool = false,
    has_light: bool = false,
    has_camera: bool = false,
    has_vfx: bool = false,
    is_folder: bool = false,
};

const ContextSnapshot = struct {
    revision: u64 = 0,
    primary_selection: ?scene_mod.EntityId = null,
    selected_entities: std.ArrayList(scene_mod.EntityId) = .empty,
    staged_preview_selection: ?scene_mod.EntityId = null,
    manipulation_mode: ManipulationMode = .none,
    manipulation_entity: ?scene_mod.EntityId = null,
    transform_space: TransformSpace = .local,
    viewport_size: [2]u32 = .{ 0, 0 },
    viewport_hovered: bool = false,
    viewport_focused: bool = false,
    camera_transform: components.Transform = .{},
    camera_projection: CameraProjection = .{},
    viewport_center_ray: ?scene_mod.Ray = null,
    drag_payload: ?DragPayload = null,
    selected_asset: ?SelectedAsset = null,
    pending_viewport_drop: ?PendingViewportDrop = null,

    fn deinit(self: *ContextSnapshot, allocator: std.mem.Allocator) void {
        self.selected_entities.deinit(allocator);
        self.* = .{};
        self.selected_entities = .empty;
    }
};

const StagedTransaction = struct {
    active: bool = false,
    id: u64 = 0,
    source: IntentSource = .ai,
    label: MediumText = .{},
    note: LongText = .{},
    meta: command_mod.CommandMeta = .{},
    commands: std.ArrayList(CommandEntry) = .empty,
    results: std.ArrayList(StageCommandResult) = .empty,
    preview_entries: std.ArrayList(PreviewEntity) = .empty,
    preview_world_snapshot: ?[]u8 = null,
    error_count: usize = 0,

    fn clear(self: *StagedTransaction, allocator: std.mem.Allocator) void {
        for (self.commands.items) |*entry| {
            entry.deinit(allocator);
        }
        self.commands.clearRetainingCapacity();
        self.results.clearRetainingCapacity();
        self.preview_entries.clearRetainingCapacity();
        if (self.preview_world_snapshot) |snapshot| {
            allocator.free(snapshot);
            self.preview_world_snapshot = null;
        }
        self.active = false;
        self.id = 0;
        self.source = .ai;
        self.label.clear();
        self.note.clear();
        self.meta.deinit(allocator);
        self.error_count = 0;
    }

    fn deinit(self: *StagedTransaction, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.commands.deinit(allocator);
        self.results.deinit(allocator);
        self.preview_entries.deinit(allocator);
        self.* = undefined;
    }
};

pub const StageRequest = struct {
    source: IntentSource = .ai,
    label: ?[]u8 = null,
    note: ?[]u8 = null,
    meta: command_mod.CommandMeta = .{},
    commands: std.ArrayList(CommandEntry) = .empty,

    pub fn deinit(self: *StageRequest, allocator: std.mem.Allocator) void {
        if (self.label) |label| {
            allocator.free(label);
        }
        if (self.note) |note| {
            allocator.free(note);
        }
        self.meta.deinit(allocator);
        for (self.commands.items) |*entry| {
            entry.deinit(allocator);
        }
        self.commands.deinit(allocator);
        self.* = undefined;
    }
};

pub const StageResult = struct {
    transaction_id: u64 = 0,
    command_count: usize = 0,
    preview_count: usize = 0,
    error_count: usize = 0,
    base_revision_conflict_count: usize = 0,
};

pub const ApplyResult = struct {
    had_transaction: bool = false,
    transaction_id: ?u64 = null,
    command_count: usize = 0,
    changed_count: usize = 0,
    error_count: usize = 0,
    base_revision_conflict_count: usize = 0,
    kept_staged: bool = false,
};

pub const DiscardResult = struct {
    had_transaction: bool = false,
    transaction_id: ?u64 = null,
    command_count: usize = 0,
};

pub const CallResponse = struct {
    tool_name: []u8,
    outcome: union(enum) {
        staged: StageResult,
        applied: ApplyResult,
        discarded: DiscardResult,
    },

    pub fn deinit(self: *CallResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_name);
        self.* = undefined;
    }
};

pub const OverlayPreviewEntry = struct {
    entity_id: ?scene_mod.EntityId = null,
    action: PreviewAction = .updated,
    name: MediumText = .{},
    world_position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    has_world_position: bool = false,
    visible: bool = true,
};

pub const OverlaySnapshot = struct {
    pub const max_entries = 48;

    active: bool = false,
    transaction_id: u64 = 0,
    source: IntentSource = .ai,
    label: MediumText = .{},
    note: LongText = .{},
    command_count: usize = 0,
    error_count: usize = 0,
    preview_count: usize = 0,
    visible_entry_count: usize = 0,
    entries: [max_entries]OverlayPreviewEntry = [_]OverlayPreviewEntry{.{}} ** max_entries,
};

pub const AiStage = enum {
    ready,
    analyzing_screenshot,
    compiling_shader,
    waiting_approval,
};

pub const AiStatusSnapshot = struct {
    stage: AiStage = .ready,
    detail: LongText = .{},
};

pub const PreviewWorldSnapshot = struct {
    active: bool = false,
    transaction_id: ?u64 = null,
    encoded_world: ?[]u8 = null,

    pub fn deinit(self: *PreviewWorldSnapshot, allocator: std.mem.Allocator) void {
        if (self.encoded_world) |bytes| {
            allocator.free(bytes);
        }
        self.* = undefined;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    context: ContextSnapshot = .{},
    intent_log: std.ArrayList(IntentEntry) = .empty,
    command_timeline: std.ArrayList(CommandTimelineEntry) = .empty,
    staged: StagedTransaction = .{},
    next_intent_sequence: u64 = 1,
    next_command_timeline_sequence: u64 = 1,
    next_transaction_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.context.deinit(self.allocator);
        self.intent_log.deinit(self.allocator);
        self.command_timeline.deinit(self.allocator);
        self.staged.deinit(self.allocator);
    }

    pub fn recordCommandTimeline(self: *Store, source: IntentSource, label: []const u8, detail: []const u8, command_kind: []const u8) !void {
        return self.recordCommandTimelineWithMeta(source, label, detail, command_kind, null);
    }

    pub fn recordCommandTimelineWithMeta(
        self: *Store,
        source: IntentSource,
        label: []const u8,
        detail: []const u8,
        command_kind: []const u8,
        meta: ?*const command_mod.CommandMeta,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.appendCommandTimelineLocked(source, label, detail, command_kind, meta);
    }

    fn appendCommandTimelineLocked(
        self: *Store,
        source: IntentSource,
        label: []const u8,
        detail: []const u8,
        command_kind: []const u8,
        meta: ?*const command_mod.CommandMeta,
    ) !void {
        if (self.command_timeline.items.len >= 256) {
            _ = self.command_timeline.orderedRemove(0);
        }

        var stored_meta: StoredCommandMeta = .{};
        stored_meta.assign(meta);

        try self.command_timeline.append(self.allocator, .{
            .sequence = self.next_command_timeline_sequence,
            .source = source,
            .label = textFromSlice(MediumText, label),
            .detail = textFromSlice(LongText, detail),
            .command_kind = textFromSlice(ShortText, command_kind),
            .meta = stored_meta,
        });
        self.next_command_timeline_sequence += 1;
    }

    pub fn updateContext(self: *Store, args: UpdateContextArgs) !void {
        var selection_detail_buffer: [96]u8 = undefined;
        const selection_changed = selectionChanged(self, args.primary_selection, args.selected_entities);
        const drag_changed = dragPayloadChanged(self, args.drag_payload);
        const old_drag = self.peekDragPayload();

        self.mutex.lock();
        defer self.mutex.unlock();

        try replaceEntitySlice(&self.context.selected_entities, self.allocator, args.selected_entities);
        self.context.revision += 1;
        self.context.primary_selection = args.primary_selection;
        self.context.staged_preview_selection = args.staged_preview_selection;
        self.context.manipulation_mode = args.manipulation_mode;
        self.context.manipulation_entity = args.manipulation_entity;
        self.context.transform_space = args.transform_space;
        self.context.viewport_size = args.viewport_size;
        self.context.viewport_hovered = args.viewport_hovered;
        self.context.viewport_focused = args.viewport_focused;
        self.context.camera_transform = args.camera_transform;
        self.context.camera_projection = args.camera_projection;
        self.context.viewport_center_ray = args.viewport_center_ray;
        self.context.drag_payload = args.drag_payload;
        self.context.selected_asset = args.selected_asset;
        self.context.pending_viewport_drop = args.pending_viewport_drop;

        if (selection_changed) {
            const detail = std.fmt.bufPrint(
                &selection_detail_buffer,
                "primary={any} count={d}",
                .{ args.primary_selection, args.selected_entities.len },
            ) catch "selection changed";
            try self.pushIntentLocked(.human, "selection_changed", detail, null);
        }

        if (drag_changed) {
            var drag_detail_buffer: [160]u8 = undefined;
            const detail = if (args.drag_payload) |drag_payload|
                formatDragDetail(&drag_detail_buffer, drag_payload)
            else if (old_drag) |previous_drag|
                formatDragEndedDetail(&drag_detail_buffer, previous_drag)
            else
                "drag clear";
            try self.pushIntentLocked(.human, "drag_context", detail, null);
        }
    }

    pub fn recordIntent(self: *Store, source: IntentSource, action: []const u8, detail: []const u8) !void {
        return self.recordIntentWithMeta(source, action, detail, null);
    }

    pub fn recordIntentWithMeta(
        self: *Store,
        source: IntentSource,
        action: []const u8,
        detail: []const u8,
        meta: ?*const command_mod.CommandMeta,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.pushIntentLocked(source, action, detail, meta);
    }

    pub fn stageOwnedTransaction(self: *Store, world: *const scene_mod.World, request: *StageRequest) !StageResult {
        const mutable_world: *scene_mod.World = @constCast(world);
        mutable_world.updateHierarchy();

        const encoded_world = try scene_mod.serializeWorldAlloc(self.allocator, world);
        defer self.allocator.free(encoded_world);

        var preview_world = scene_mod.World.init(self.allocator, mutable_world.job_system);
        defer preview_world.deinit();
        try scene_mod.deserializeWorldFromSlice(self.allocator, &preview_world, encoded_world);
        preview_world.updateHierarchy();

        var preview_results = std.ArrayList(StageCommandResult).empty;
        errdefer preview_results.deinit(self.allocator);

        var preview_entries = std.ArrayList(PreviewEntity).empty;
        errdefer preview_entries.deinit(self.allocator);

        var error_count: usize = 0;
        var base_revision_conflict_count: usize = 0;
        const should_execute_preview = if (request.meta.base_revision) |base_revision|
            base_revision == world.sceneRevision()
        else
            true;

        if (!should_execute_preview) {
            error_count = request.commands.items.len;
            base_revision_conflict_count = request.commands.items.len;
        } else {
            for (request.commands.items) |entry| {
                const result = try command_queue_mod.executeOneWithMeta(
                    &preview_world,
                    entry.command,
                    commandSourceFromIntent(request.source),
                    &entry.meta,
                );
                try preview_results.append(self.allocator, .{
                    .tool_name = textFromSlice(ShortText, entry.tool_name),
                    .changed = result.changed,
                    .entity_id = result.entity_id,
                    .err = result.err,
                });
                if (result.err != null) {
                    error_count += 1;
                    if (result.err.? == .base_revision_conflict) {
                        base_revision_conflict_count += 1;
                    }
                }
                try updatePreviewEntries(&preview_entries, world, &preview_world, entry.command, result);
            }
        }

        const preview_world_snapshot = try scene_mod.serializeWorldAlloc(self.allocator, &preview_world);

        var stage_result = StageResult{};

        self.mutex.lock();
        defer self.mutex.unlock();

        self.staged.clear(self.allocator);
        self.staged.active = true;
        self.staged.id = self.next_transaction_id;
        self.next_transaction_id += 1;
        self.staged.source = request.source;
        self.staged.meta = request.meta;
        request.meta = .{};
        if (request.label) |label| {
            self.staged.label.set(label);
            self.allocator.free(label);
            request.label = null;
        }
        if (request.note) |note| {
            self.staged.note.set(note);
            self.allocator.free(note);
            request.note = null;
        }
        self.staged.commands = request.commands;
        request.commands = .empty;
        self.staged.results = preview_results;
        preview_results = .empty;
        self.staged.preview_entries = preview_entries;
        preview_entries = .empty;
        self.staged.preview_world_snapshot = preview_world_snapshot;
        self.staged.error_count = error_count;

        stage_result = .{
            .transaction_id = self.staged.id,
            .command_count = self.staged.commands.items.len,
            .preview_count = self.staged.preview_entries.items.len,
            .error_count = self.staged.error_count,
            .base_revision_conflict_count = base_revision_conflict_count,
        };

        var detail_buffer: [160]u8 = undefined;
        const detail = std.fmt.bufPrint(
            &detail_buffer,
            "id={d} commands={d} preview={d} errors={d} conflicts={d}",
            .{ stage_result.transaction_id, stage_result.command_count, stage_result.preview_count, stage_result.error_count, stage_result.base_revision_conflict_count },
        ) catch "staged transaction";
        self.pushIntentLocked(request.source, "staged_transaction", detail, &self.staged.meta) catch |err| {
            std.log.err("failed to push staged_transaction intent: {s}", .{@errorName(err)});
        };

        self.appendCommandTimelineLocked(
            request.source,
            "Stage Transaction",
            detail,
            "stage_transaction",
            &self.staged.meta,
        ) catch |err| {
            std.log.err("failed to append stage_transaction timeline: {s}", .{@errorName(err)});
        };

        return stage_result;
    }

    pub fn applyStagedTransaction(self: *Store, world: *scene_mod.World, source: IntentSource) !ApplyResult {
        return self.applyStagedTransactionWithMeta(world, source, null);
    }

    pub fn applyStagedTransactionWithMeta(
        self: *Store,
        world: *scene_mod.World,
        source: IntentSource,
        meta_override: ?*const command_mod.CommandMeta,
    ) !ApplyResult {
        var staged_id: ?u64 = null;
        var local_commands = std.ArrayList(CommandEntry).empty;
        var staged_meta: command_mod.CommandMeta = .{};
        defer staged_meta.deinit(self.allocator);
        defer {
            for (local_commands.items) |*entry| {
                entry.deinit(self.allocator);
            }
            local_commands.deinit(self.allocator);
        }

        self.mutex.lock();
        if (!self.staged.active) {
            self.mutex.unlock();
            return .{};
        }

        staged_id = self.staged.id;
        try cloneCommandEntriesInto(&local_commands, self.allocator, self.staged.commands.items);
        const command_count = self.staged.commands.items.len;
        staged_meta = try self.staged.meta.cloneAlloc(self.allocator);
        if (meta_override) |meta| {
            if (meta.actor) |value| try replaceMetaFieldAlloc(self.allocator, &staged_meta.actor, value);
            if (meta.client) |value| try replaceMetaFieldAlloc(self.allocator, &staged_meta.client, value);
            if (meta.session) |value| try replaceMetaFieldAlloc(self.allocator, &staged_meta.session, value);
            if (meta.request) |value| try replaceMetaFieldAlloc(self.allocator, &staged_meta.request, value);
            if (meta.trace) |value| try replaceMetaFieldAlloc(self.allocator, &staged_meta.trace, value);
            if (meta.approval != .auto) {
                staged_meta.approval = meta.approval;
            }
            if (staged_meta.base_revision == null and meta.base_revision != null) {
                staged_meta.base_revision = meta.base_revision;
            }
        }
        self.mutex.unlock();

        var changed_count: usize = 0;
        var error_count: usize = 0;
        var base_revision_conflict_count: usize = 0;
        const should_execute_apply = if (staged_meta.base_revision) |base_revision|
            base_revision == world.sceneRevision()
        else
            true;

        if (!should_execute_apply) {
            error_count = local_commands.items.len;
            base_revision_conflict_count = local_commands.items.len;
        } else {
            for (local_commands.items) |entry| {
                var execution_meta = entry.meta;
                if (execution_meta.actor == null) execution_meta.actor = staged_meta.actor;
                if (execution_meta.client == null) execution_meta.client = staged_meta.client;
                if (execution_meta.session == null) execution_meta.session = staged_meta.session;
                if (execution_meta.request == null) execution_meta.request = staged_meta.request;
                if (execution_meta.trace == null) execution_meta.trace = staged_meta.trace;
                if (execution_meta.approval == .auto) execution_meta.approval = staged_meta.approval;
                const result = try command_queue_mod.executeOneWithMeta(
                    world,
                    entry.command,
                    commandSourceFromIntent(source),
                    &execution_meta,
                );
                if (result.changed) {
                    changed_count += 1;
                }
                if (result.err != null) {
                    error_count += 1;
                    if (result.err.? == .base_revision_conflict) {
                        base_revision_conflict_count += 1;
                    }
                }
            }
            world.updateHierarchy();
        }

        const kept_staged = base_revision_conflict_count > 0;

        self.mutex.lock();
        defer self.mutex.unlock();
        if (!kept_staged and self.staged.active and self.staged.id == staged_id.?) {
            self.staged.clear(self.allocator);
        }

        var detail_buffer: [192]u8 = undefined;
        const detail = std.fmt.bufPrint(
            &detail_buffer,
            "id={d} commands={d} changed={d} errors={d} conflicts={d} kept={s}",
            .{
                staged_id.?,
                command_count,
                changed_count,
                error_count,
                base_revision_conflict_count,
                if (kept_staged) "yes" else "no",
            },
        ) catch "applied staged transaction";
        self.pushIntentLocked(
            source,
            if (kept_staged) "apply_transaction_conflict" else "applied_transaction",
            detail,
            &staged_meta,
        ) catch |err| {
            std.log.err("failed to push applied_transaction intent: {s}", .{@errorName(err)});
        };

        self.appendCommandTimelineLocked(
            source,
            if (kept_staged) "Apply Transaction Conflict" else "Apply Transaction",
            detail,
            if (kept_staged) "apply_conflict" else "apply_staged_transaction",
            &staged_meta,
        ) catch |err| {
            std.log.err("failed to append apply_transaction timeline: {s}", .{@errorName(err)});
        };

        return .{
            .had_transaction = true,
            .transaction_id = staged_id,
            .command_count = command_count,
            .changed_count = changed_count,
            .error_count = error_count,
            .base_revision_conflict_count = base_revision_conflict_count,
            .kept_staged = kept_staged,
        };
    }

    pub fn discardStagedTransaction(self: *Store, source: IntentSource) DiscardResult {
        return self.discardStagedTransactionWithMeta(source, null);
    }

    pub fn discardStagedTransactionWithMeta(
        self: *Store,
        source: IntentSource,
        meta_override: ?*const command_mod.CommandMeta,
    ) DiscardResult {
        var staged_meta: command_mod.CommandMeta = .{};
        defer staged_meta.deinit(self.allocator);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.staged.active) {
            return .{};
        }

        staged_meta = if (meta_override) |meta|
            meta.cloneAlloc(self.allocator) catch .{}
        else
            self.staged.meta.cloneAlloc(self.allocator) catch .{};

        const result = DiscardResult{
            .had_transaction = true,
            .transaction_id = self.staged.id,
            .command_count = self.staged.commands.items.len,
        };
        self.staged.clear(self.allocator);

        var detail_buffer: [128]u8 = undefined;
        const detail = std.fmt.bufPrint(
            &detail_buffer,
            "id={any} commands={d}",
            .{ result.transaction_id, result.command_count },
        ) catch "discarded staged transaction";
        self.pushIntentLocked(source, "discarded_transaction", detail, &staged_meta) catch |err| {
            std.log.err("failed to push discarded_transaction intent: {s}", .{@errorName(err)});
        };

        self.appendCommandTimelineLocked(
            source,
            "Discard Transaction",
            detail,
            "discard_staged_transaction",
            &staged_meta,
        ) catch |err| {
            std.log.err("failed to append discard_transaction timeline: {s}", .{@errorName(err)});
        };

        return result;
    }

    pub fn overlaySnapshot(self: *const Store) OverlaySnapshot {
        const mutable: *Store = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();

        var snapshot = OverlaySnapshot{};
        if (!mutable.staged.active) {
            return snapshot;
        }

        snapshot.active = true;
        snapshot.transaction_id = mutable.staged.id;
        snapshot.source = mutable.staged.source;
        snapshot.label = mutable.staged.label;
        snapshot.note = mutable.staged.note;
        snapshot.command_count = mutable.staged.commands.items.len;
        snapshot.error_count = mutable.staged.error_count;
        snapshot.preview_count = mutable.staged.preview_entries.items.len;

        for (mutable.staged.preview_entries.items, 0..) |entry, index| {
            if (index >= OverlaySnapshot.max_entries) {
                break;
            }
            snapshot.entries[index] = .{
                .entity_id = entry.entity_id,
                .action = entry.action,
                .name = entry.name,
                .world_position = entry.world_transform.translation,
                .has_world_position = entry.has_world_transform,
                .visible = entry.visible,
            };
            snapshot.visible_entry_count += 1;
        }

        return snapshot;
    }

    pub fn aiStatusSnapshot(self: *const Store) AiStatusSnapshot {
        const mutable: *Store = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();

        if (mutable.staged.active) {
            return .{
                .stage = .waiting_approval,
                .detail = if (mutable.staged.note.len > 0)
                    mutable.staged.note
                else
                    textFromSlice(LongText, mutable.staged.label.slice()),
            };
        }

        if (mutable.intent_log.items.len == 0) {
            return .{};
        }

        const latest = mutable.intent_log.items[mutable.intent_log.items.len - 1];
        const action = latest.action.slice();
        const detail = latest.detail.slice();

        if (containsAsciiInsensitive(action, "screenshot") or
            containsAsciiInsensitive(action, "vision") or
            containsAsciiInsensitive(detail, "screenshot") or
            containsAsciiInsensitive(detail, "vision"))
        {
            return .{
                .stage = .analyzing_screenshot,
                .detail = latest.detail,
            };
        }

        if (containsAsciiInsensitive(action, "compile") or
            containsAsciiInsensitive(action, "shader") or
            containsAsciiInsensitive(detail, "compile") or
            containsAsciiInsensitive(detail, "shader"))
        {
            return .{
                .stage = .compiling_shader,
                .detail = latest.detail,
            };
        }

        return .{
            .stage = .ready,
            .detail = latest.detail,
        };
    }

    pub fn copyPreviewWorldSnapshotAlloc(self: *const Store, allocator: std.mem.Allocator) !PreviewWorldSnapshot {
        const mutable: *Store = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();

        if (!mutable.staged.active or mutable.staged.preview_world_snapshot == null) {
            return .{};
        }

        return .{
            .active = true,
            .transaction_id = mutable.staged.id,
            .encoded_world = try allocator.dupe(u8, mutable.staged.preview_world_snapshot.?),
        };
    }

    pub fn copyPreviewEntityIdsAlloc(self: *const Store, allocator: std.mem.Allocator) ![]scene_mod.EntityId {
        const mutable: *Store = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();

        var count: usize = 0;
        for (mutable.staged.preview_entries.items) |entry| {
            if (entry.entity_id != null and entry.action != .deleted) {
                count += 1;
            }
        }

        const ids = try allocator.alloc(scene_mod.EntityId, count);
        var index: usize = 0;
        for (mutable.staged.preview_entries.items) |entry| {
            if (entry.entity_id) |entity_id| {
                if (entry.action == .deleted) {
                    continue;
                }
                ids[index] = entity_id;
                index += 1;
            }
        }
        return ids;
    }

    pub fn updateStagedEntityWorldTransform(
        self: *Store,
        allocator: std.mem.Allocator,
        entity_id: scene_mod.EntityId,
        transform: components.Transform,
        source: IntentSource,
    ) !bool {
        var staged_id: u64 = 0;
        var encoded_preview_world: []u8 = undefined;

        self.mutex.lock();
        if (!self.staged.active or self.staged.preview_world_snapshot == null) {
            self.mutex.unlock();
            return false;
        }
        staged_id = self.staged.id;
        encoded_preview_world = try allocator.dupe(u8, self.staged.preview_world_snapshot.?);
        self.mutex.unlock();
        defer allocator.free(encoded_preview_world);

        var preview_world = scene_mod.World.init(allocator, null);
        defer preview_world.deinit();
        try scene_mod.deserializeWorldFromSlice(allocator, &preview_world, encoded_preview_world);
        preview_world.updateHierarchy();

        const changed = preview_world.setEntityWorldTransform(entity_id, transform);
        if (!changed) {
            return preview_world.hasEntity(entity_id);
        }
        preview_world.updateHierarchy();

        const next_snapshot = try scene_mod.serializeWorldAlloc(allocator, &preview_world);
        errdefer allocator.free(next_snapshot);

        const preview_entity = preview_world.getEntityConst(entity_id) orelse return false;
        const world_transform = preview_world.worldTransformConst(entity_id) orelse preview_entity.local_transform;

        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.staged.active or self.staged.id != staged_id) {
            allocator.free(next_snapshot);
            return false;
        }

        if (self.staged.preview_world_snapshot) |existing| {
            self.allocator.free(existing);
        }
        self.staged.preview_world_snapshot = next_snapshot;
        try upsertStagedWorldTransformCommand(&self.staged.commands, self.allocator, entity_id, world_transform);
        updatePreviewEntryTransform(&self.staged.preview_entries, entity_id, world_transform, preview_entity.visible);

        var detail_buffer: [160]u8 = undefined;
        const detail = std.fmt.bufPrint(
            &detail_buffer,
            "id={d} entity={d} world_transform=({d:.2},{d:.2},{d:.2})",
            .{ staged_id, entity_id, world_transform.translation[0], world_transform.translation[1], world_transform.translation[2] },
        ) catch "staged preview transform";
        self.pushIntentLocked(source, "staged_preview_transform", detail, &self.staged.meta) catch |err| {
            std.log.err("failed to push staged_preview_transform intent: {s}", .{@errorName(err)});
        };
        return true;
    }

    pub fn appendResourceDescriptorsAlloc(
        allocator: std.mem.Allocator,
        resources: *std.ArrayList(protocol.ResourceDescriptor),
    ) !void {
        for (collaboration_resource_specs) |spec| {
            try resources.append(allocator, .{
                .uri = try allocator.dupe(u8, spec.uri),
                .name = try allocator.dupe(u8, spec.name),
                .title = null,
                .description = try allocator.dupe(u8, spec.description),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .size = null,
            });
        }
    }

    pub fn readResourceAlloc(self: *const Store, allocator: std.mem.Allocator, uri: []const u8) !?protocol.TextResourceContents {
        if (std.mem.eql(u8, uri, "editor://context")) {
            const text = try self.buildContextJsonAlloc(allocator);
            return .{
                .uri = try allocator.dupe(u8, uri),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = text,
            };
        }
        if (std.mem.eql(u8, uri, "editor://intent-log")) {
            const text = try self.buildIntentLogJsonAlloc(allocator);
            return .{
                .uri = try allocator.dupe(u8, uri),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = text,
            };
        }
        if (std.mem.eql(u8, uri, "editor://command-timeline")) {
            const text = try self.buildCommandTimelineJsonAlloc(allocator);
            return .{
                .uri = try allocator.dupe(u8, uri),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = text,
            };
        }
        if (std.mem.eql(u8, uri, "preview://staged")) {
            const text = try self.buildStagedPreviewJsonAlloc(allocator);
            return .{
                .uri = try allocator.dupe(u8, uri),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = text,
            };
        }
        return null;
    }

    fn buildContextJsonAlloc(self: *const Store, allocator: std.mem.Allocator) ![]u8 {
        const mutable: *Store = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();

        const RayView = struct {
            origin: [3]f32,
            direction: [3]f32,
        };
        const TransformView = struct {
            translation: [3]f32,
            rotation: [4]f32,
            scale: [3]f32,
        };
        const ProjectionView = struct {
            kind: []const u8,
            fov_y_radians: ?f32 = null,
            orthographic_size: ?f32 = null,
            near_clip: f32,
            far_clip: f32,
        };
        const DragView = struct {
            kind: []const u8,
            entity_id: ?scene_mod.EntityId = null,
            asset_name: ?[]const u8 = null,
            asset_path: ?[]const u8 = null,
            actor_kind: ?[]const u8 = null,
        };
        const SelectedAssetView = struct {
            kind: []const u8,
            id: []const u8,
            name: []const u8,
            path: []const u8,
        };
        const PendingDropView = struct {
            kind: []const u8,
            asset_name: ?[]const u8 = null,
            actor_kind: ?[]const u8 = null,
            target_entity: ?scene_mod.EntityId = null,
            pixel: ?[2]u32 = null,
            world_position: ?[3]f32 = null,
        };
        const ContextView = struct {
            revision: u64,
            selection: struct {
                primary: ?scene_mod.EntityId,
                entities: []const scene_mod.EntityId,
                staged_preview_primary: ?scene_mod.EntityId,
            },
            manipulation: struct {
                mode: []const u8,
                entity_id: ?scene_mod.EntityId,
                transform_space: []const u8,
            },
            viewport: struct {
                size: [2]u32,
                hovered: bool,
                focused: bool,
                center_ray: ?RayView,
            },
            camera: struct {
                transform: TransformView,
                projection: ProjectionView,
            },
            drag_payload: ?DragView = null,
            selected_asset: ?SelectedAssetView = null,
            pending_viewport_drop: ?PendingDropView = null,
        };

        const projection_view = switch (mutable.context.camera_projection.kind) {
            .perspective => ProjectionView{
                .kind = "perspective",
                .fov_y_radians = mutable.context.camera_projection.fov_y_radians,
                .near_clip = mutable.context.camera_projection.near_clip,
                .far_clip = mutable.context.camera_projection.far_clip,
            },
            .orthographic => ProjectionView{
                .kind = "orthographic",
                .orthographic_size = mutable.context.camera_projection.orthographic_size,
                .near_clip = mutable.context.camera_projection.near_clip,
                .far_clip = mutable.context.camera_projection.far_clip,
            },
        };

        const drag_payload = if (mutable.context.drag_payload) |drag| DragView{
            .kind = @tagName(drag.kind),
            .entity_id = drag.entity_id,
            .asset_name = if (drag.asset_name.len > 0) drag.asset_name.slice() else null,
            .asset_path = if (drag.asset_path.len > 0) drag.asset_path.slice() else null,
            .actor_kind = if (drag.actor_kind.len > 0) drag.actor_kind.slice() else null,
        } else null;

        const selected_asset = if (mutable.context.selected_asset) |asset| SelectedAssetView{
            .kind = asset.kind.slice(),
            .id = asset.id.slice(),
            .name = asset.name.slice(),
            .path = asset.path.slice(),
        } else null;

        const pending_drop = if (mutable.context.pending_viewport_drop) |drop| PendingDropView{
            .kind = @tagName(drop.kind),
            .asset_name = if (drop.asset_name.len > 0) drop.asset_name.slice() else null,
            .actor_kind = if (drop.actor_kind.len > 0) drop.actor_kind.slice() else null,
            .target_entity = drop.target_entity,
            .pixel = if (drop.has_pixel) drop.pixel else null,
            .world_position = if (drop.has_world_position) drop.world_position else null,
        } else null;

        return stringifyAlloc(allocator, ContextView{
            .revision = mutable.context.revision,
            .selection = .{
                .primary = mutable.context.primary_selection,
                .entities = mutable.context.selected_entities.items,
                .staged_preview_primary = mutable.context.staged_preview_selection,
            },
            .manipulation = .{
                .mode = @tagName(mutable.context.manipulation_mode),
                .entity_id = mutable.context.manipulation_entity,
                .transform_space = @tagName(mutable.context.transform_space),
            },
            .viewport = .{
                .size = mutable.context.viewport_size,
                .hovered = mutable.context.viewport_hovered,
                .focused = mutable.context.viewport_focused,
                .center_ray = if (mutable.context.viewport_center_ray) |ray| RayView{
                    .origin = ray.origin,
                    .direction = ray.direction,
                } else null,
            },
            .camera = .{
                .transform = .{
                    .translation = mutable.context.camera_transform.translation,
                    .rotation = mutable.context.camera_transform.rotation,
                    .scale = mutable.context.camera_transform.scale,
                },
                .projection = projection_view,
            },
            .drag_payload = drag_payload,
            .selected_asset = selected_asset,
            .pending_viewport_drop = pending_drop,
        });
    }

    fn buildIntentLogJsonAlloc(self: *const Store, allocator: std.mem.Allocator) ![]u8 {
        const mutable: *Store = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();

        const MetaView = struct {
            actor: ?[]const u8 = null,
            client: ?[]const u8 = null,
            session: ?[]const u8 = null,
            request: ?[]const u8 = null,
            trace: ?[]const u8 = null,
            approval: ?[]const u8 = null,
            base_revision: ?u64 = null,
        };
        const IntentView = struct {
            sequence: u64,
            source: []const u8,
            action: []const u8,
            detail: []const u8,
            meta: MetaView,
        };
        const Payload = struct {
            count: usize,
            items: []const IntentView,
        };

        const items = try allocator.alloc(IntentView, mutable.intent_log.items.len);
        defer allocator.free(items);

        for (mutable.intent_log.items, 0..) |entry, index| {
            const meta_view = if (entry.meta.present) MetaView{
                .actor = if (entry.meta.actor.len > 0) entry.meta.actor.slice() else null,
                .client = if (entry.meta.client.len > 0) entry.meta.client.slice() else null,
                .session = if (entry.meta.session.len > 0) entry.meta.session.slice() else null,
                .request = if (entry.meta.request.len > 0) entry.meta.request.slice() else null,
                .trace = if (entry.meta.trace.len > 0) entry.meta.trace.slice() else null,
                .approval = @tagName(entry.meta.approval),
                .base_revision = entry.meta.base_revision,
            } else MetaView{};
            items[index] = .{
                .sequence = entry.sequence,
                .source = @tagName(entry.source),
                .action = entry.action.slice(),
                .detail = entry.detail.slice(),
                .meta = meta_view,
            };
        }

        return stringifyAlloc(allocator, Payload{
            .count = items.len,
            .items = items,
        });
    }

    fn buildCommandTimelineJsonAlloc(self: *const Store, allocator: std.mem.Allocator) ![]u8 {
        const mutable: *Store = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();

        const MetaView = struct {
            actor: ?[]const u8 = null,
            client: ?[]const u8 = null,
            session: ?[]const u8 = null,
            request: ?[]const u8 = null,
            trace: ?[]const u8 = null,
            approval: ?[]const u8 = null,
            base_revision: ?u64 = null,
        };
        const TimelineItemView = struct {
            sequence: u64,
            source: []const u8,
            color_hex: []const u8,
            color_rgba: [4]f32,
            label: []const u8,
            detail: []const u8,
            command_kind: []const u8,
            meta: MetaView,
        };
        const Payload = struct {
            count: usize,
            items: []const TimelineItemView,
        };

        const items = try allocator.alloc(TimelineItemView, mutable.command_timeline.items.len);
        defer allocator.free(items);

        for (mutable.command_timeline.items, 0..) |entry, index| {
            const meta_view = if (entry.meta.present) MetaView{
                .actor = if (entry.meta.actor.len > 0) entry.meta.actor.slice() else null,
                .client = if (entry.meta.client.len > 0) entry.meta.client.slice() else null,
                .session = if (entry.meta.session.len > 0) entry.meta.session.slice() else null,
                .request = if (entry.meta.request.len > 0) entry.meta.request.slice() else null,
                .trace = if (entry.meta.trace.len > 0) entry.meta.trace.slice() else null,
                .approval = @tagName(entry.meta.approval),
                .base_revision = entry.meta.base_revision,
            } else MetaView{};
            items[index] = .{
                .sequence = entry.sequence,
                .source = @tagName(entry.source),
                .color_hex = timelineColorHexForSource(entry.source),
                .color_rgba = timelineColorRgbaForSource(entry.source),
                .label = entry.label.slice(),
                .detail = entry.detail.slice(),
                .command_kind = entry.command_kind.slice(),
                .meta = meta_view,
            };
        }

        return stringifyAlloc(allocator, Payload{
            .count = items.len,
            .items = items,
        });
    }

    fn buildStagedPreviewJsonAlloc(self: *const Store, allocator: std.mem.Allocator) ![]u8 {
        const mutable: *Store = @constCast(self);
        mutable.mutex.lock();
        defer mutable.mutex.unlock();

        const TransformView = struct {
            translation: [3]f32,
            rotation: [4]f32,
            scale: [3]f32,
        };
        const CommandResultView = struct {
            tool: []const u8,
            changed: bool,
            entity_id: ?scene_mod.EntityId,
            command_error: ?[]const u8,
        };
        const PreviewEntryView = struct {
            entity_id: ?scene_mod.EntityId,
            action: []const u8,
            name: []const u8,
            world_transform: ?TransformView = null,
            visible: bool,
            parent_id: ?scene_mod.EntityId,
            has_mesh: bool,
            has_light: bool,
            has_camera: bool,
            has_vfx: bool,
            is_folder: bool,
        };
        const Payload = struct {
            active: bool,
            transaction_id: ?u64 = null,
            source: ?[]const u8 = null,
            actor: ?[]const u8 = null,
            client: ?[]const u8 = null,
            session: ?[]const u8 = null,
            request: ?[]const u8 = null,
            trace: ?[]const u8 = null,
            approval: ?[]const u8 = null,
            base_revision: ?u64 = null,
            label: ?[]const u8 = null,
            note: ?[]const u8 = null,
            command_count: usize = 0,
            error_count: usize = 0,
            results: []const CommandResultView = &.{},
            preview_entities: []const PreviewEntryView = &.{},
        };

        if (!mutable.staged.active) {
            return stringifyAlloc(allocator, Payload{ .active = false });
        }

        const results = try allocator.alloc(CommandResultView, mutable.staged.results.items.len);
        defer allocator.free(results);
        for (mutable.staged.results.items, 0..) |entry, index| {
            results[index] = .{
                .tool = entry.tool_name.slice(),
                .changed = entry.changed,
                .entity_id = entry.entity_id,
                .command_error = if (entry.err) |err| @tagName(err) else null,
            };
        }

        const preview_entities = try allocator.alloc(PreviewEntryView, mutable.staged.preview_entries.items.len);
        defer allocator.free(preview_entities);
        for (mutable.staged.preview_entries.items, 0..) |entry, index| {
            preview_entities[index] = .{
                .entity_id = entry.entity_id,
                .action = @tagName(entry.action),
                .name = entry.name.slice(),
                .world_transform = if (entry.has_world_transform) TransformView{
                    .translation = entry.world_transform.translation,
                    .rotation = entry.world_transform.rotation,
                    .scale = entry.world_transform.scale,
                } else null,
                .visible = entry.visible,
                .parent_id = entry.parent_id,
                .has_mesh = entry.has_mesh,
                .has_light = entry.has_light,
                .has_camera = entry.has_camera,
                .has_vfx = entry.has_vfx,
                .is_folder = entry.is_folder,
            };
        }

        return stringifyAlloc(allocator, Payload{
            .active = true,
            .transaction_id = mutable.staged.id,
            .source = @tagName(mutable.staged.source),
            .actor = mutable.staged.meta.actor,
            .client = mutable.staged.meta.client,
            .session = mutable.staged.meta.session,
            .request = mutable.staged.meta.request,
            .trace = mutable.staged.meta.trace,
            .approval = @tagName(mutable.staged.meta.approval),
            .base_revision = mutable.staged.meta.base_revision,
            .label = if (mutable.staged.label.len > 0) mutable.staged.label.slice() else null,
            .note = if (mutable.staged.note.len > 0) mutable.staged.note.slice() else null,
            .command_count = mutable.staged.commands.items.len,
            .error_count = mutable.staged.error_count,
            .results = results,
            .preview_entities = preview_entities,
        });
    }

    fn pushIntentLocked(
        self: *Store,
        source: IntentSource,
        action: []const u8,
        detail: []const u8,
        meta: ?*const command_mod.CommandMeta,
    ) !void {
        if (self.intent_log.items.len >= 64) {
            _ = self.intent_log.orderedRemove(0);
        }
        var stored_meta: StoredCommandMeta = .{};
        stored_meta.assign(meta);
        try self.intent_log.append(self.allocator, .{
            .sequence = self.next_intent_sequence,
            .source = source,
            .action = textFromSlice(ShortText, action),
            .detail = textFromSlice(LongText, detail),
            .meta = stored_meta,
        });
        self.next_intent_sequence += 1;
    }

    fn peekDragPayload(self: *Store) ?DragPayload {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.context.drag_payload;
    }
};

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    pending: ?PendingRequest = null,
    response: ?CallResponse = null,
    shutting_down: bool = false,

    pub const ExecuteOutcome = struct {
        response: CallResponse,
        world_changed: bool = false,
    };

    const PendingRequest = union(enum) {
        stage: StagePending,
        apply: SimplePending,
        discard: SimplePending,

        fn deinit(self: *PendingRequest, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .stage => |*stage| stage.deinit(allocator),
                .apply => |*pending| pending.deinit(allocator),
                .discard => |*pending| pending.deinit(allocator),
            }
            self.* = undefined;
        }
    };

    const SimplePending = struct {
        tool_name: []u8,
        meta: command_mod.CommandMeta = .{},

        fn deinit(self: *SimplePending, allocator: std.mem.Allocator) void {
            allocator.free(self.tool_name);
            self.meta.deinit(allocator);
            self.* = undefined;
        }
    };

    const StagePending = struct {
        tool_name: []u8,
        request: StageRequest,

        fn deinit(self: *StagePending, allocator: std.mem.Allocator) void {
            allocator.free(self.tool_name);
            self.request.deinit(allocator);
            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator, store: *Store) Bridge {
        return .{
            .allocator = allocator,
            .store = store,
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
        var request = try parsePendingRequestAlloc(self.allocator, tool_name, arguments, meta);
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
        var request = try parsePendingRequestAlloc(self.allocator, tool_name, arguments, meta);
        return try self.executeOwnedRequest(layer_context, &request);
    }

    pub fn processPending(self: *Bridge, layer_context: *core.LayerContext) !bool {
        self.mutex.lock();
        if (self.pending == null or self.response != null) {
            self.mutex.unlock();
            return false;
        }
        var request = self.pending.?;
        self.pending = null;
        self.mutex.unlock();
        const execution = try self.executeOwnedRequest(layer_context, &request);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.response = execution.response;
        self.condition.broadcast();
        return execution.world_changed;
    }

    fn executeOwnedRequest(
        self: *Bridge,
        layer_context: *core.LayerContext,
        request: *PendingRequest,
    ) !ExecuteOutcome {
        var world_changed = false;
        var response: CallResponse = undefined;
        switch (request.*) {
            .stage => |*stage_pending| {
                const result = try self.store.stageOwnedTransaction(layer_context.world, &stage_pending.request);
                response = .{
                    .tool_name = stage_pending.tool_name,
                    .outcome = .{ .staged = result },
                };
                stage_pending.request = .{};
            },
            .apply => |apply_pending| {
                const result = try self.store.applyStagedTransactionWithMeta(layer_context.world, .ai, &apply_pending.meta);
                response = .{
                    .tool_name = apply_pending.tool_name,
                    .outcome = .{ .applied = result },
                };
                world_changed = result.had_transaction and !result.kept_staged;
            },
            .discard => |discard_pending| {
                const result = self.store.discardStagedTransactionWithMeta(.ai, &discard_pending.meta);
                response = .{
                    .tool_name = discard_pending.tool_name,
                    .outcome = .{ .discarded = result },
                };
            },
        }

        switch (request.*) {
            .stage => |*stage_pending| {
                stage_pending.request.commands = .empty;
                request.deinit(self.allocator);
            },
            else => request.deinit(self.allocator),
        }

        return .{
            .response = response,
            .world_changed = world_changed,
        };
    }
};

pub fn isToolName(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, "stage_transaction") or
        std.mem.eql(u8, tool_name, "apply_staged_transaction") or
        std.mem.eql(u8, tool_name, "discard_staged_transaction");
}

pub fn buildSummaryAlloc(allocator: std.mem.Allocator, response: CallResponse) ![]u8 {
    return switch (response.outcome) {
        .staged => |result| std.fmt.allocPrint(
            allocator,
            "stage_transaction ok: id={d}, commands={d}, preview={d}, errors={d}, conflicts={d}",
            .{ result.transaction_id, result.command_count, result.preview_count, result.error_count, result.base_revision_conflict_count },
        ),
        .applied => |result| if (!result.had_transaction)
            allocator.dupe(u8, "apply_staged_transaction ok: no staged transaction")
        else
            std.fmt.allocPrint(
                allocator,
                "apply_staged_transaction ok: id={d}, commands={d}, changed={d}, errors={d}, conflicts={d}, kept={s}",
                .{
                    result.transaction_id.?,
                    result.command_count,
                    result.changed_count,
                    result.error_count,
                    result.base_revision_conflict_count,
                    if (result.kept_staged) "yes" else "no",
                },
            ),
        .discarded => |result| if (!result.had_transaction)
            allocator.dupe(u8, "discard_staged_transaction ok: no staged transaction")
        else
            std.fmt.allocPrint(
                allocator,
                "discard_staged_transaction ok: id={d}, commands={d}",
                .{ result.transaction_id.?, result.command_count },
            ),
    };
}

const collaboration_resource_specs = [_]struct {
    uri: []const u8,
    name: []const u8,
    description: []const u8,
}{
    .{
        .uri = "editor://context",
        .name = "Editor Context",
        .description = "Selection, camera, drag payload, and viewport focus context injected into AI calls.",
    },
    .{
        .uri = "editor://intent-log",
        .name = "Editor Intent Log",
        .description = "Recent human and AI intents captured from editor interaction and staged transactions.",
    },
    .{
        .uri = "editor://command-timeline",
        .name = "Editor Command Timeline",
        .description = "Command timeline snapshot with source metadata and color hints (human=blue, ai=purple).",
    },
    .{
        .uri = "preview://staged",
        .name = "Staged Preview",
        .description = "Current ghost preview transaction with command results and projected staged entities.",
    },
};

fn selectionChanged(self: *Store, primary_selection: ?scene_mod.EntityId, selected_entities: []const scene_mod.EntityId) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.context.primary_selection != primary_selection) {
        return true;
    }
    return !std.mem.eql(scene_mod.EntityId, self.context.selected_entities.items, selected_entities);
}

fn dragPayloadChanged(self: *Store, next: ?DragPayload) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    return !dragPayloadEqual(self.context.drag_payload, next);
}

fn dragPayloadEqual(a: ?DragPayload, b: ?DragPayload) bool {
    if (a == null and b == null) {
        return true;
    }
    if (a == null or b == null) {
        return false;
    }

    const left = a.?;
    const right = b.?;
    return left.kind == right.kind and
        left.entity_id == right.entity_id and
        std.mem.eql(u8, left.asset_name.slice(), right.asset_name.slice()) and
        std.mem.eql(u8, left.asset_path.slice(), right.asset_path.slice()) and
        std.mem.eql(u8, left.actor_kind.slice(), right.actor_kind.slice());
}

fn formatDragDetail(buffer: []u8, drag_payload: DragPayload) []const u8 {
    return switch (drag_payload.kind) {
        .entity => std.fmt.bufPrint(buffer, "entity:{any}", .{drag_payload.entity_id}) catch "entity drag",
        .asset_model, .asset_material, .asset_texture => std.fmt.bufPrint(
            buffer,
            "{s}:{s}",
            .{ @tagName(drag_payload.kind), drag_payload.asset_name.slice() },
        ) catch "asset drag",
        .place_actor => std.fmt.bufPrint(buffer, "place_actor:{s}", .{drag_payload.actor_kind.slice()}) catch "place actor drag",
    };
}

fn formatDragEndedDetail(buffer: []u8, drag_payload: DragPayload) []const u8 {
    // Use separate buffer to avoid @memcpy alias
    var temp: [128]u8 = undefined;
    const inner = formatDragDetail(&temp, drag_payload);
    return std.fmt.bufPrint(buffer, "end {s}", .{inner}) catch "drag clear";
}

fn containsAsciiInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) {
        return true;
    }
    if (needle.len > haystack.len) {
        return false;
    }

    const last_start = haystack.len - needle.len;
    var start: usize = 0;
    while (start <= last_start) : (start += 1) {
        var matched = true;
        var offset: usize = 0;
        while (offset < needle.len) : (offset += 1) {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(needle[offset])) {
                matched = false;
                break;
            }
        }
        if (matched) {
            return true;
        }
    }
    return false;
}

fn replaceEntitySlice(list: *std.ArrayList(scene_mod.EntityId), allocator: std.mem.Allocator, values: []const scene_mod.EntityId) !void {
    list.clearRetainingCapacity();
    try list.appendSlice(allocator, values);
}

fn textFromSlice(comptime T: type, value: []const u8) T {
    var text: T = .{};
    text.set(value);
    return text;
}

pub fn makeDragPayload(
    kind: DragPayloadKind,
    entity_id: ?scene_mod.EntityId,
    asset_name: []const u8,
    asset_path: []const u8,
    actor_kind: []const u8,
) DragPayload {
    return .{
        .kind = kind,
        .entity_id = entity_id,
        .asset_name = textFromSlice(MediumText, asset_name),
        .asset_path = textFromSlice(LongText, asset_path),
        .actor_kind = textFromSlice(ShortText, actor_kind),
    };
}

pub fn makeSelectedAsset(kind: []const u8, id: []const u8, name: []const u8, path: []const u8) SelectedAsset {
    return .{
        .kind = textFromSlice(ShortText, kind),
        .id = textFromSlice(MediumText, id),
        .name = textFromSlice(MediumText, name),
        .path = textFromSlice(LongText, path),
    };
}

pub fn makePendingViewportDrop(
    kind: PendingViewportDropKind,
    asset_name: []const u8,
    actor_kind: []const u8,
    target_entity: ?scene_mod.EntityId,
    pixel: ?[2]u32,
    world_position: ?[3]f32,
) PendingViewportDrop {
    var drop = PendingViewportDrop{
        .kind = kind,
        .asset_name = textFromSlice(MediumText, asset_name),
        .actor_kind = textFromSlice(ShortText, actor_kind),
        .target_entity = target_entity,
    };
    if (pixel) |pixel_value| {
        drop.pixel = pixel_value;
        drop.has_pixel = true;
    }
    if (world_position) |world_position_value| {
        drop.world_position = world_position_value;
        drop.has_world_position = true;
    }
    return drop;
}

fn cloneCommandEntryAlloc(allocator: std.mem.Allocator, entry: CommandEntry) !CommandEntry {
    return .{
        .tool_name = try allocator.dupe(u8, entry.tool_name),
        .command = try cloneCommandAlloc(allocator, entry.command),
        .meta = try entry.meta.cloneAlloc(allocator),
    };
}

fn cloneCommandEntriesInto(
    destination: *std.ArrayList(CommandEntry),
    allocator: std.mem.Allocator,
    source: []const CommandEntry,
) !void {
    try destination.ensureTotalCapacity(allocator, source.len);
    for (source) |entry| {
        try destination.append(allocator, try cloneCommandEntryAlloc(allocator, entry));
    }
}

fn cloneCommandAlloc(allocator: std.mem.Allocator, command: command_mod.Command) !command_mod.Command {
    return switch (command) {
        .create_entity => |create| .{
            .create_entity = .{
                .name = try allocator.dupe(u8, create.name),
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
            },
        },
        .delete_entity => |delete| .{ .delete_entity = delete },
        .rename_entity => |rename| .{
            .rename_entity = .{
                .entity_id = rename.entity_id,
                .name = try allocator.dupe(u8, rename.name),
            },
        },
        .set_parent => |set_parent| .{ .set_parent = set_parent },
        .set_local_transform => |set_transform| .{ .set_local_transform = set_transform },
        .set_world_transform => |set_transform| .{ .set_world_transform = set_transform },
        .set_visible => |set_visible| .{ .set_visible = set_visible },
    };
}

fn upsertStagedWorldTransformCommand(
    commands: *std.ArrayList(CommandEntry),
    allocator: std.mem.Allocator,
    entity_id: scene_mod.EntityId,
    transform: components.Transform,
) !void {
    var index = commands.items.len;
    while (index > 0) {
        index -= 1;
        switch (commands.items[index].command) {
            .set_world_transform => |*set_transform| {
                if (set_transform.entity_id != entity_id) {
                    continue;
                }
                set_transform.transform = transform;
                return;
            },
            .set_local_transform => |*set_transform| {
                if (set_transform.entity_id != entity_id) {
                    continue;
                }
                commands.items[index].command = .{
                    .set_world_transform = .{
                        .entity_id = entity_id,
                        .transform = transform,
                    },
                };
                return;
            },
            else => {},
        }
    }

    try commands.append(allocator, .{
        .tool_name = try allocator.dupe(u8, "set_world_transform"),
        .command = .{
            .set_world_transform = .{
                .entity_id = entity_id,
                .transform = transform,
            },
        },
    });
}

fn updatePreviewEntryTransform(
    entries: *std.ArrayList(PreviewEntity),
    entity_id: scene_mod.EntityId,
    transform: components.Transform,
    visible: bool,
) void {
    for (entries.items) |*entry| {
        if (entry.entity_id != entity_id) {
            continue;
        }
        entry.world_transform = transform;
        entry.has_world_transform = true;
        entry.visible = visible;
        return;
    }
}

fn previewActionForCommand(command: command_mod.Command) PreviewAction {
    return switch (command) {
        .create_entity => .created,
        .delete_entity => .deleted,
        else => .updated,
    };
}

fn updatePreviewEntries(
    entries: *std.ArrayList(PreviewEntity),
    base_world: *const scene_mod.World,
    preview_world: *scene_mod.World,
    command: command_mod.Command,
    result: command_mod.ExecutionResult,
) !void {
    if (result.entity_id == null) {
        return;
    }
    if (!result.changed and command != .delete_entity and command != .create_entity) {
        return;
    }
    if (result.err != null and command != .delete_entity) {
        return;
    }

    const entity_id = result.entity_id.?;
    const action = previewActionForCommand(command);

    var preview_entry = PreviewEntity{
        .entity_id = entity_id,
        .action = action,
    };

    switch (action) {
        .created, .updated => {
            const entity = preview_world.getEntityConst(entity_id) orelse return;
            preview_entry.name.set(entity.name);
            if (preview_world.worldTransform(entity_id)) |transform| {
                preview_entry.world_transform = transform;
                preview_entry.has_world_transform = true;
            }
            preview_entry.visible = entity.visible;
            preview_entry.parent_id = entity.parent;
            preview_entry.has_mesh = entity.mesh != null;
            preview_entry.has_light = entity.light != null;
            preview_entry.has_camera = entity.camera != null;
            preview_entry.has_vfx = entity.vfx != null;
            preview_entry.is_folder = entity.is_folder;
        },
        .deleted => {
            const entity = base_world.getEntityConst(entity_id) orelse return;
            preview_entry.name.set(entity.name);
            if (@constCast(base_world).worldTransform(entity_id)) |transform| {
                preview_entry.world_transform = transform;
                preview_entry.has_world_transform = true;
            }
            preview_entry.visible = entity.visible;
            preview_entry.parent_id = entity.parent;
            preview_entry.has_mesh = entity.mesh != null;
            preview_entry.has_light = entity.light != null;
            preview_entry.has_camera = entity.camera != null;
            preview_entry.has_vfx = entity.vfx != null;
            preview_entry.is_folder = entity.is_folder;
        },
    }

    for (entries.items) |*existing| {
        if (existing.entity_id != preview_entry.entity_id) {
            continue;
        }
        if (existing.action == .created and preview_entry.action == .updated) {
            preview_entry.action = .created;
        }
        existing.* = preview_entry;
        return;
    }

    try entries.append(base_world.allocator, preview_entry);
}

fn parsePendingRequestAlloc(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    arguments: ?std.json.Value,
    meta_override: ?*const command_mod.CommandMeta,
) !Bridge.PendingRequest {
    if (std.mem.eql(u8, tool_name, "stage_transaction")) {
        var stage_request = StageRequest{};
        stage_request.commands = .empty;
        errdefer stage_request.deinit(allocator);

        const args = try requireObject(arguments);
        if (optionalStringField(args, "label")) |label| {
            stage_request.label = try allocator.dupe(u8, label);
        }
        if (optionalStringField(args, "note")) |note| {
            stage_request.note = try allocator.dupe(u8, note);
        }
        if (optionalStringField(args, "source")) |source_text| {
            stage_request.source = parseIntentSource(source_text) orelse return error.InvalidArguments;
        }
        stage_request.meta = try parseCommandMetaAlloc(allocator, args);
        if (meta_override) |override_meta| {
            stage_request.meta.deinit(allocator);
            stage_request.meta = try override_meta.cloneAlloc(allocator);
        }

        const commands_value = args.get("commands") orelse args.get("operations") orelse return error.InvalidArguments;
        const commands = switch (commands_value) {
            .array => |array| array.items,
            else => return error.InvalidArguments,
        };
        if (commands.len == 0) {
            return error.InvalidArguments;
        }
        try stage_request.commands.ensureTotalCapacity(allocator, commands.len);

        for (commands) |command_value| {
            const command_object = switch (command_value) {
                .object => |object| object,
                else => return error.InvalidArguments,
            };
            const command_name = optionalStringField(command_object, "name") orelse return error.InvalidArguments;
            const command_arguments = if (command_object.get("arguments")) |value| value else null;
            const parsed = try tools_mod.parseToolCallAlloc(allocator, command_name, command_arguments);
            var command_meta = try stage_request.meta.cloneAlloc(allocator);
            errdefer command_meta.deinit(allocator);
            command_meta.base_revision = null;
            try applyCommandMetaFieldsAlloc(allocator, command_object, &command_meta);
            switch (parsed) {
                .command => |command_request| {
                    try stage_request.commands.append(allocator, .{
                        .tool_name = command_request.tool_name,
                        .command = command_request.command,
                        .meta = command_meta,
                    });
                },
                else => {
                    var owned = parsed;
                    owned.deinit(allocator);
                    return error.InvalidArguments;
                },
            }
        }

        return .{
            .stage = .{
                .tool_name = try allocator.dupe(u8, tool_name),
                .request = stage_request,
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "apply_staged_transaction")) {
        var meta = command_mod.CommandMeta{};
        errdefer meta.deinit(allocator);
        const args = optionalObject(arguments);
        if (args) |object| {
            meta = try parseCommandMetaAlloc(allocator, object);
        }
        if (meta_override) |override_meta| {
            meta.deinit(allocator);
            meta = try override_meta.cloneAlloc(allocator);
        }
        return .{
            .apply = .{
                .tool_name = try allocator.dupe(u8, tool_name),
                .meta = meta,
            },
        };
    }
    if (std.mem.eql(u8, tool_name, "discard_staged_transaction")) {
        var meta = command_mod.CommandMeta{};
        errdefer meta.deinit(allocator);
        const args = optionalObject(arguments);
        if (args) |object| {
            meta = try parseCommandMetaAlloc(allocator, object);
        }
        if (meta_override) |override_meta| {
            meta.deinit(allocator);
            meta = try override_meta.cloneAlloc(allocator);
        }
        return .{
            .discard = .{
                .tool_name = try allocator.dupe(u8, tool_name),
                .meta = meta,
            },
        };
    }
    return error.ToolNotFound;
}

fn requireObject(arguments: ?std.json.Value) Error!std.json.ObjectMap {
    const value = arguments orelse return error.InvalidArguments;
    return switch (value) {
        .object => |object| object,
        else => error.InvalidArguments,
    };
}

fn optionalObject(arguments: ?std.json.Value) ?std.json.ObjectMap {
    const value = arguments orelse return null;
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn optionalStringField(object: std.json.ObjectMap, field_name: []const u8) ?[]const u8 {
    const value = object.get(field_name) orelse return null;
    return switch (value) {
        .string => |text| text,
        .null => null,
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

fn parseCommandMetaAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !command_mod.CommandMeta {
    var meta: command_mod.CommandMeta = .{};
    errdefer meta.deinit(allocator);

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

fn parseIntentSource(source_text: []const u8) ?IntentSource {
    if (std.mem.eql(u8, source_text, "human")) {
        return .human;
    }
    if (std.mem.eql(u8, source_text, "ai")) {
        return .ai;
    }
    return null;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var writer = output.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();
    return try output.toOwnedSlice(allocator);
}

test "Store stages preview and applies it to the main world" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const original = try world.createEntity(.{ .name = "Original" });
    world.updateHierarchy();

    var request = StageRequest{
        .source = .ai,
        .label = try std.testing.allocator.dupe(u8, "Fence pass"),
        .note = try std.testing.allocator.dupe(u8, "Preview before commit"),
        .commands = .empty,
    };
    defer request.deinit(std.testing.allocator);

    try request.commands.append(std.testing.allocator, .{
        .tool_name = try std.testing.allocator.dupe(u8, "rename_entity"),
        .command = .{
            .rename_entity = .{
                .entity_id = original,
                .name = try std.testing.allocator.dupe(u8, "RenamedByAi"),
            },
        },
    });
    try request.commands.append(std.testing.allocator, .{
        .tool_name = try std.testing.allocator.dupe(u8, "create_entity"),
        .command = .{
            .create_entity = .{
                .name = try std.testing.allocator.dupe(u8, "GhostTree"),
                .local_transform = .{
                    .translation = .{ 3.0, 0.0, -2.0 },
                },
            },
        },
    });

    const staged = try store.stageOwnedTransaction(&world, &request);
    try std.testing.expectEqual(@as(usize, 2), staged.command_count);
    try std.testing.expectEqual(@as(usize, 2), staged.preview_count);

    const overlay = store.overlaySnapshot();
    try std.testing.expect(overlay.active);
    try std.testing.expectEqual(@as(usize, 2), overlay.command_count);

    var preview_snapshot = try store.copyPreviewWorldSnapshotAlloc(std.testing.allocator);
    defer preview_snapshot.deinit(std.testing.allocator);
    try std.testing.expect(preview_snapshot.active);
    try std.testing.expectEqual(staged.transaction_id, preview_snapshot.transaction_id.?);
    try std.testing.expect(preview_snapshot.encoded_world != null);
    try std.testing.expect(preview_snapshot.encoded_world.?.len > 0);

    const applied = try store.applyStagedTransaction(&world, .human);
    try std.testing.expect(applied.had_transaction);
    try std.testing.expectEqual(@as(usize, 2), applied.command_count);
    try std.testing.expectEqualStrings("RenamedByAi", world.getEntityConst(original).?.name);
    try std.testing.expectEqual(@as(usize, 2), world.entities.items.len);

    const staged_json = try store.readResourceAlloc(std.testing.allocator, "preview://staged");
    defer if (staged_json) |content| {
        std.testing.allocator.free(content.uri);
        if (content.mimeType) |mime_type| std.testing.allocator.free(mime_type);
        std.testing.allocator.free(content.text);
    };
    try std.testing.expect(std.mem.indexOf(u8, staged_json.?.text, "\"active\": false") != null);
}

test "Store updates staged preview transforms and replays them on apply" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const source_entity = try world.createEntity(.{
        .name = "Mover",
        .local_transform = .{
            .translation = .{ 1.0, 0.0, 0.0 },
        },
    });
    world.updateHierarchy();

    var request = StageRequest{
        .source = .ai,
        .commands = .empty,
    };
    defer request.deinit(std.testing.allocator);

    try request.commands.append(std.testing.allocator, .{
        .tool_name = try std.testing.allocator.dupe(u8, "rename_entity"),
        .command = .{
            .rename_entity = .{
                .entity_id = source_entity,
                .name = try std.testing.allocator.dupe(u8, "MoverPreview"),
            },
        },
    });

    _ = try store.stageOwnedTransaction(&world, &request);
    try std.testing.expect(try store.updateStagedEntityWorldTransform(
        std.testing.allocator,
        source_entity,
        .{ .translation = .{ 6.0, 2.0, -3.0 } },
        .human,
    ));

    const applied = try store.applyStagedTransaction(&world, .human);
    try std.testing.expect(applied.had_transaction);
    const transformed = world.worldTransformConst(source_entity).?;
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), transformed.translation[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), transformed.translation[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -3.0), transformed.translation[2], 0.0001);
}

test "Store keeps staged transaction when apply base revision is stale" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity = try world.createEntity(.{ .name = "Actor" });
    world.updateHierarchy();
    const base_revision = world.sceneRevision();

    var request = StageRequest{
        .source = .ai,
        .commands = .empty,
        .meta = .{
            .base_revision = base_revision,
        },
    };
    defer request.deinit(std.testing.allocator);

    try request.commands.append(std.testing.allocator, .{
        .tool_name = try std.testing.allocator.dupe(u8, "rename_entity"),
        .command = .{
            .rename_entity = .{
                .entity_id = entity,
                .name = try std.testing.allocator.dupe(u8, "FromStage"),
            },
        },
    });

    _ = try store.stageOwnedTransaction(&world, &request);
    _ = world.renameEntity(entity, "ExternalChange") catch return error.UnexpectedValue;
    world.updateHierarchy();

    const applied = try store.applyStagedTransaction(&world, .human);
    try std.testing.expect(applied.had_transaction);
    try std.testing.expect(applied.kept_staged);
    try std.testing.expectEqual(@as(usize, 0), applied.changed_count);
    try std.testing.expectEqual(@as(usize, 1), applied.base_revision_conflict_count);
    try std.testing.expectEqualStrings("ExternalChange", world.getEntityConst(entity).?.name);

    const overlay = store.overlaySnapshot();
    try std.testing.expect(overlay.active);
    try std.testing.expectEqual(applied.transaction_id.?, overlay.transaction_id);
}

test "Bridge parses staged transaction batches" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var bridge = Bridge.init(std.testing.allocator, &store);
    defer bridge.deinit();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{
        \\  "label": "Batch",
        \\  "base_revision": 17,
        \\  "commands": [
        \\    {
        \\      "name": "rename_entity",
        \\      "arguments": { "entity_id": 1, "name": "Actor" }
        \\    }
        \\  ]
        \\}
    , .{ .allocate = .alloc_always });
    defer parsed.deinit();

    var request = try parsePendingRequestAlloc(std.testing.allocator, "stage_transaction", parsed.value, null);
    defer request.deinit(std.testing.allocator);

    switch (request) {
        .stage => |stage| {
            try std.testing.expectEqual(@as(usize, 1), stage.request.commands.items.len);
            try std.testing.expectEqualStrings("stage_transaction", stage.tool_name);
            try std.testing.expectEqualStrings("rename_entity", stage.request.commands.items[0].tool_name);
            try std.testing.expectEqual(@as(?u64, 17), stage.request.meta.base_revision);
            try std.testing.expectEqual(@as(?u64, null), stage.request.commands.items[0].meta.base_revision);
        },
        else => return error.UnexpectedValue,
    }
}
