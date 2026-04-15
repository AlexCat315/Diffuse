const std = @import("std");
const io_globals = @import("io_globals");
const job_system_mod = @import("job_system.zig");
const command_queue_mod = @import("command_queue.zig");
const renderer_mod = @import("../render/renderer.zig");
const scene_io = @import("../scene/scene_io.zig");
const world_mod = @import("../scene/world.zig");
const physics_mod = @import("../physics/system.zig");
const script_system = @import("../script/script.zig");
const audio_mod = @import("../audio/mod.zig");

pub const TransitionKind = enum {
    load,
    unload,
    stream,
};

pub const TransitionPhase = enum {
    idle,
    queued,
    reading,
    applying,
    completed,
    failed,
};

pub const LoadingState = struct {
    active: bool = false,
    kind: ?TransitionKind = null,
    phase: TransitionPhase = .idle,
    progress: f32 = 0.0,
    current_scene_path: ?[]const u8 = null,
    requested_scene_path: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const Callbacks = struct {
    context: ?*anyopaque = null,
    on_started: ?*const fn (context: ?*anyopaque, state: LoadingState) void = null,
    on_progress: ?*const fn (context: ?*anyopaque, state: LoadingState) void = null,
    on_finished: ?*const fn (context: ?*anyopaque, state: LoadingState) void = null,
    on_failed: ?*const fn (context: ?*anyopaque, state: LoadingState) void = null,
};

const AsyncReadShared = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    source: ?[]u8 = null,
    error_message: ?[]u8 = null,

    fn create(allocator: std.mem.Allocator, path: []u8) !*AsyncReadShared {
        const self = try allocator.create(AsyncReadShared);
        self.* = .{
            .allocator = allocator,
            .path = path,
        };
        return self;
    }

    fn publishSource(self: *AsyncReadShared, source: []u8) void {
        self.mutex.lockUncancelable(io_globals.global_io);
        defer self.mutex.unlock(io_globals.global_io);
        self.source = source;
    }

    fn publishError(self: *AsyncReadShared, message: []u8) void {
        self.mutex.lockUncancelable(io_globals.global_io);
        defer self.mutex.unlock(io_globals.global_io);
        self.error_message = message;
    }

    fn takeSource(self: *AsyncReadShared) ?[]u8 {
        self.mutex.lockUncancelable(io_globals.global_io);
        defer self.mutex.unlock(io_globals.global_io);
        const source = self.source;
        self.source = null;
        return source;
    }

    fn takeError(self: *AsyncReadShared) ?[]u8 {
        self.mutex.lockUncancelable(io_globals.global_io);
        defer self.mutex.unlock(io_globals.global_io);
        const message = self.error_message;
        self.error_message = null;
        return message;
    }

    fn deinit(self: *AsyncReadShared) void {
        if (self.source) |source| {
            self.allocator.free(source);
        }
        if (self.error_message) |message| {
            self.allocator.free(message);
        }
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

const AsyncReadContext = struct {
    allocator: std.mem.Allocator,
    shared: *AsyncReadShared,

    fn deinit(self: *AsyncReadContext) void {
        self.allocator.destroy(self);
    }
};

fn asyncReadSceneTask(context: ?*anyopaque) void {
    const ctx: *AsyncReadContext = @ptrCast(@alignCast(context));
    defer ctx.deinit();

    const source = std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, ctx.shared.path, ctx.shared.allocator, .limited(128 * 1024 * 1024)) catch |err| {
        const message = std.fmt.allocPrint(ctx.shared.allocator, "{s}", .{@errorName(err)}) catch return;
        ctx.shared.publishError(message);
        return;
    };
    ctx.shared.publishSource(source);
}

fn asyncReadSceneCleanup(context: ?*anyopaque) void {
    const ctx: *AsyncReadContext = @ptrCast(@alignCast(context));
    ctx.deinit();
}

pub const SceneManager = struct {
    allocator: std.mem.Allocator,
    current_scene_path: ?[]u8 = null,
    requested_scene_path: ?[]u8 = null,
    last_error_message: ?[]u8 = null,
    callbacks: Callbacks = .{},
    transition_kind: ?TransitionKind = null,
    phase: TransitionPhase = .idle,
    progress: f32 = 0.0,
    active_job: ?job_system_mod.JobHandle = null,
    async_read: ?*AsyncReadShared = null,

    pub fn init(allocator: std.mem.Allocator) SceneManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SceneManager) void {
        if (self.active_job) |*job| {
            job.wait();
            job.deinit();
            self.active_job = null;
        }
        if (self.async_read) |shared| {
            shared.deinit();
            self.async_read = null;
        }
        self.clearRequestedScenePath();
        self.clearCurrentScenePath();
        self.clearLastError();
        self.* = .{ .allocator = self.allocator };
    }

    pub fn isBusy(self: *const SceneManager) bool {
        return self.transition_kind != null;
    }

    pub fn currentScenePath(self: *const SceneManager) ?[]const u8 {
        return self.current_scene_path;
    }

    pub fn loadingState(self: *const SceneManager) LoadingState {
        return .{
            .active = self.transition_kind != null,
            .kind = self.transition_kind,
            .phase = self.phase,
            .progress = self.progress,
            .current_scene_path = self.current_scene_path,
            .requested_scene_path = self.requested_scene_path,
            .error_message = self.last_error_message,
        };
    }

    pub fn requestLoadScene(
        self: *SceneManager,
        job_system: *job_system_mod.JobSystem,
        requested_path: []const u8,
        callbacks: Callbacks,
    ) !void {
        if (self.isBusy()) {
            return error.SceneTransitionInProgress;
        }

        const resolved_path = try resolveScenePathAlloc(self.allocator, requested_path);
        errdefer self.allocator.free(resolved_path);

        const shared = try AsyncReadShared.create(self.allocator, resolved_path);
        errdefer shared.deinit();

        const ctx = try self.allocator.create(AsyncReadContext);
        errdefer self.allocator.destroy(ctx);
        ctx.* = .{
            .allocator = self.allocator,
            .shared = shared,
        };

        try self.beginTransition(.load, shared.path, callbacks);
        errdefer self.abortTransitionSetup();

        const handle = try job_system.enqueueWithCleanup(asyncReadSceneTask, ctx, asyncReadSceneCleanup, .normal);
        self.active_job = handle;
        self.async_read = shared;
        self.phase = .reading;
        self.progress = 0.15;
        self.notifyStarted();
        self.notifyProgress();
    }

    pub fn requestStreamScene(
        self: *SceneManager,
        job_system: *job_system_mod.JobSystem,
        requested_path: []const u8,
        callbacks: Callbacks,
    ) !void {
        if (self.isBusy()) {
            return error.SceneTransitionInProgress;
        }

        const resolved_path = try resolveScenePathAlloc(self.allocator, requested_path);
        errdefer self.allocator.free(resolved_path);

        const shared = try AsyncReadShared.create(self.allocator, resolved_path);
        errdefer shared.deinit();

        const ctx = try self.allocator.create(AsyncReadContext);
        errdefer self.allocator.destroy(ctx);
        ctx.* = .{
            .allocator = self.allocator,
            .shared = shared,
        };

        try self.beginTransition(.stream, shared.path, callbacks);
        errdefer self.abortTransitionSetup();

        const handle = try job_system.enqueueWithCleanup(asyncReadSceneTask, ctx, asyncReadSceneCleanup, .normal);
        self.active_job = handle;
        self.async_read = shared;
        self.phase = .reading;
        self.progress = 0.15;
        self.notifyStarted();
        self.notifyProgress();
    }

    pub fn requestUnloadScene(self: *SceneManager, callbacks: Callbacks) !void {
        if (self.isBusy()) {
            return error.SceneTransitionInProgress;
        }

        try self.beginTransition(.unload, null, callbacks);
        self.phase = .applying;
        self.progress = 0.5;
        self.notifyStarted();
        self.notifyProgress();
    }

    pub fn setDontDestroyOnLoad(
        self: *SceneManager,
        world: *world_mod.World,
        entity_id: world_mod.EntityId,
        enabled: bool,
    ) bool {
        _ = self;
        if (world.getEntity(entity_id)) |entity| {
            entity.dont_destroy_on_load = enabled;
            world.markSceneChanged();
            return true;
        }
        return false;
    }

    pub fn pump(
        self: *SceneManager,
        world: *world_mod.World,
        physics_state: *physics_mod.PhysicsState,
        script_runtime: ?*script_system.ScriptRuntime,
        command_queue: *command_queue_mod.CommandQueue,
        renderer: ?*renderer_mod.Renderer,
    ) !void {
        const transition_kind = self.transition_kind orelse return;

        switch (transition_kind) {
            .load => {
                const job_done = if (self.active_job) |handle| handle.isDone() else false;
                if (!job_done) {
                    return;
                }

                self.phase = .applying;
                self.progress = 0.75;
                self.notifyProgress();

                const shared = self.async_read orelse return error.InvalidSceneTransitionState;
                if (shared.takeError()) |message| {
                    defer self.allocator.free(message);
                    self.releaseAsyncJob();
                    try self.failTransition(message);
                    return;
                }

                const source = shared.takeSource() orelse {
                    self.releaseAsyncJob();
                    try self.failTransition("Scene read completed without source data");
                    return;
                };
                defer self.allocator.free(source);

                self.releaseAsyncJob();
                self.phase = .applying;
                self.progress = 0.9;
                self.notifyProgress();

                self.applySceneTransition(world, physics_state, script_runtime, command_queue, renderer, source, true) catch |err| {
                    try self.failTransition(@errorName(err));
                    return;
                };
                try self.finishLoadTransition();
            },
            .unload => {
                self.phase = .applying;
                self.progress = 0.9;
                self.notifyProgress();

                self.applySceneTransition(world, physics_state, script_runtime, command_queue, renderer, null, true) catch |err| {
                    try self.failTransition(@errorName(err));
                    return;
                };
                self.finishUnloadTransition();
            },
            .stream => {
                const job_done = if (self.active_job) |handle| handle.isDone() else false;
                if (!job_done) {
                    return;
                }

                self.phase = .applying;
                self.progress = 0.75;
                self.notifyProgress();

                const shared = self.async_read orelse return error.InvalidSceneTransitionState;
                if (shared.takeError()) |message| {
                    defer self.allocator.free(message);
                    self.releaseAsyncJob();
                    try self.failTransition(message);
                    return;
                }

                const source = shared.takeSource() orelse {
                    self.releaseAsyncJob();
                    try self.failTransition("Scene read completed without source data");
                    return;
                };
                defer self.allocator.free(source);

                self.releaseAsyncJob();
                self.phase = .applying;
                self.progress = 0.9;
                self.notifyProgress();

                self.applySceneTransition(world, physics_state, script_runtime, command_queue, renderer, source, false) catch |err| {
                    try self.failTransition(@errorName(err));
                    return;
                };
                try self.finishLoadTransition();
            },
        }
    }

    fn beginTransition(
        self: *SceneManager,
        kind: TransitionKind,
        requested_path: ?[]const u8,
        callbacks: Callbacks,
    ) !void {
        self.clearLastError();
        self.clearRequestedScenePath();
        if (requested_path) |path| {
            self.requested_scene_path = try self.allocator.dupe(u8, path);
        }
        self.callbacks = callbacks;
        self.transition_kind = kind;
        self.phase = .queued;
        self.progress = 0.0;
    }

    fn abortTransitionSetup(self: *SceneManager) void {
        self.transition_kind = null;
        self.phase = .idle;
        self.progress = 0.0;
        self.callbacks = .{};
        self.clearRequestedScenePath();
    }

    fn finishLoadTransition(self: *SceneManager) !void {
        const requested = self.requested_scene_path orelse return error.InvalidSceneTransitionState;
        try self.setCurrentScenePath(requested);
        self.completeTransition();
    }

    fn finishUnloadTransition(self: *SceneManager) void {
        self.clearCurrentScenePath();
        self.completeTransition();
    }

    fn completeTransition(self: *SceneManager) void {
        self.progress = 1.0;
        self.phase = .completed;
        self.notifyProgress();
        self.transition_kind = null;
        self.notifyFinished();
        self.callbacks = .{};
        self.clearRequestedScenePath();
    }

    fn failTransition(self: *SceneManager, message: []const u8) !void {
        self.clearLastError();
        self.last_error_message = try self.allocator.dupe(u8, message);
        self.phase = .failed;
        self.progress = 0.0;
        self.transition_kind = null;
        self.notifyFailed();
        self.callbacks = .{};
        self.clearRequestedScenePath();
    }

    fn applySceneTransition(
        self: *SceneManager,
        world: *world_mod.World,
        physics_state: *physics_mod.PhysicsState,
        script_runtime: ?*script_system.ScriptRuntime,
        command_queue: *command_queue_mod.CommandQueue,
        renderer: ?*renderer_mod.Renderer,
        source: ?[]const u8,
        clear_existing: bool,
    ) !void {
        const recover_snapshot = if (clear_existing) try scene_io.serializeWorldAlloc(self.allocator, world) else null;
        defer if (recover_snapshot) |snapshot| self.allocator.free(snapshot);
        const persistent_snapshot = if (clear_existing) try capturePersistentEntities(self.allocator, world) else null;
        defer if (persistent_snapshot) |snapshot| self.allocator.free(snapshot);

        errdefer {
            if (recover_snapshot) |snapshot| {
                scene_io.deserializeWorldFromSlice(self.allocator, world, snapshot) catch {};
            }
        }

        command_queue.clear();
        physics_state.deinitWorld(world);
        if (script_runtime) |runtime| {
            runtime.callDestroyAll(world);
        }
        if (audio_mod.get() catch null) |audio_runtime| {
            audio_runtime.stopAll();
        }

        if (source) |scene_source| {
            if (clear_existing) {
                try scene_io.deserializeWorldFromSlice(self.allocator, world, scene_source);
            } else {
                try scene_io.appendWorldFromSlice(self.allocator, world, scene_source);
            }
        } else if (clear_existing) {
            world.clear();
        }

        if (clear_existing) {
            if (persistent_snapshot) |snapshot| {
                try scene_io.appendWorldFromSlice(self.allocator, world, snapshot);
            }
        }

        if (script_runtime) |runtime| {
            runtime.bindWorld(world);
            runtime.reconcileWorld(world);
        }
        world.updateHierarchy();
        if (renderer) |active_renderer| {
            try active_renderer.resetSceneState();
            try active_renderer.replaceSelectionMany(&.{});
        }
    }

    fn releaseAsyncJob(self: *SceneManager) void {
        if (self.active_job) |*job| {
            job.deinit();
            self.active_job = null;
        }
        if (self.async_read) |shared| {
            shared.deinit();
            self.async_read = null;
        }
    }

    fn notifyStarted(self: *SceneManager) void {
        if (self.callbacks.on_started) |cb| {
            cb(self.callbacks.context, self.loadingState());
        }
    }

    fn notifyProgress(self: *SceneManager) void {
        if (self.callbacks.on_progress) |cb| {
            cb(self.callbacks.context, self.loadingState());
        }
    }

    fn notifyFinished(self: *SceneManager) void {
        if (self.callbacks.on_finished) |cb| {
            cb(self.callbacks.context, self.loadingState());
        }
    }

    fn notifyFailed(self: *SceneManager) void {
        if (self.callbacks.on_failed) |cb| {
            cb(self.callbacks.context, self.loadingState());
        }
    }

    pub fn setCurrentScenePath(self: *SceneManager, path: []const u8) !void {
        self.clearCurrentScenePath();
        self.current_scene_path = try self.allocator.dupe(u8, path);
    }

    fn clearCurrentScenePath(self: *SceneManager) void {
        if (self.current_scene_path) |path| {
            self.allocator.free(path);
            self.current_scene_path = null;
        }
    }

    fn clearRequestedScenePath(self: *SceneManager) void {
        if (self.requested_scene_path) |path| {
            self.allocator.free(path);
            self.requested_scene_path = null;
        }
    }

    fn clearLastError(self: *SceneManager) void {
        if (self.last_error_message) |message| {
            self.allocator.free(message);
            self.last_error_message = null;
        }
    }
};

fn capturePersistentEntities(allocator: std.mem.Allocator, world: *world_mod.World) !?[]u8 {
    var roots = std.ArrayList(world_mod.EntityId).empty;
    defer roots.deinit(allocator);

    for (world.entities.items) |entity| {
        if (entity.editor_only or !entity.dont_destroy_on_load) {
            continue;
        }
        if (hasPersistentAncestor(world, entity.parent)) {
            continue;
        }
        try roots.append(allocator, entity.id);
    }

    if (roots.items.len == 0) {
        return null;
    }

    return try scene_io.serializeWorldSubsetAlloc(allocator, world, roots.items);
}

fn hasPersistentAncestor(world: *const world_mod.World, maybe_parent: ?world_mod.EntityId) bool {
    var cursor = maybe_parent;
    while (cursor) |entity_id| {
        const entity = world.getEntityConst(entity_id) orelse return false;
        if (entity.dont_destroy_on_load) {
            return true;
        }
        cursor = entity.parent;
    }
    return false;
}

fn resolveScenePathAlloc(allocator: std.mem.Allocator, requested_path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, requested_path, " \t\r\n");
    if (trimmed.len == 0) {
        return error.InvalidScenePath;
    }

    if (pathExists(trimmed)) {
        return allocator.dupe(u8, trimmed);
    }

    const has_extension = std.mem.endsWith(u8, trimmed, ".guava_scene");
    const with_extension = if (has_extension)
        try allocator.dupe(u8, trimmed)
    else
        try std.fmt.allocPrint(allocator, "{s}.guava_scene", .{trimmed});
    defer allocator.free(with_extension);

    if (pathExists(with_extension)) {
        return allocator.dupe(u8, with_extension);
    }

    const default_roots = [_][]const u8{ "assets/scenes", "Content/Scenes" };
    for (default_roots) |root| {
        const candidate = try std.fs.path.join(allocator, &.{ root, with_extension });
        defer allocator.free(candidate);
        if (pathExists(candidate)) {
            return allocator.dupe(u8, candidate);
        }
    }

    return error.SceneNotFound;
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io_globals.global_io, path, .{}) catch return false;
    return true;
}

const CallbackProbe = struct {
    started: usize = 0,
    progress: usize = 0,
    finished: usize = 0,
    failed: usize = 0,
    last_phase: TransitionPhase = .idle,
    last_progress: f32 = 0.0,
};

fn callbackProbeStarted(context: ?*anyopaque, state: LoadingState) void {
    const probe: *CallbackProbe = @ptrCast(@alignCast(context orelse return));
    probe.started += 1;
    probe.last_phase = state.phase;
    probe.last_progress = state.progress;
}

fn callbackProbeProgress(context: ?*anyopaque, state: LoadingState) void {
    const probe: *CallbackProbe = @ptrCast(@alignCast(context orelse return));
    probe.progress += 1;
    probe.last_phase = state.phase;
    probe.last_progress = state.progress;
}

fn callbackProbeFinished(context: ?*anyopaque, state: LoadingState) void {
    const probe: *CallbackProbe = @ptrCast(@alignCast(context orelse return));
    probe.finished += 1;
    probe.last_phase = state.phase;
    probe.last_progress = state.progress;
}

fn callbackProbeFailed(context: ?*anyopaque, state: LoadingState) void {
    const probe: *CallbackProbe = @ptrCast(@alignCast(context orelse return));
    probe.failed += 1;
    probe.last_phase = state.phase;
    probe.last_progress = state.progress;
}

fn findEntityByName(world: *const world_mod.World, name: []const u8) ?*const world_mod.Entity {
    for (world.entities.items) |*entity| {
        if (std.mem.eql(u8, entity.name, name)) {
            return entity;
        }
    }
    return null;
}

fn pumpUntilIdle(
    scene_manager: *SceneManager,
    world: *world_mod.World,
    physics_state: *physics_mod.PhysicsState,
    command_queue: *command_queue_mod.CommandQueue,
) !void {
    var iterations: usize = 0;
    while (scene_manager.isBusy() and iterations < 2000) : (iterations += 1) {
        try scene_manager.pump(world, physics_state, null, command_queue, null);
        std.Thread.sleep(std.time.ns_per_ms);
    }

    try std.testing.expect(!scene_manager.isBusy());
    try std.testing.expect(scene_manager.loadingState().phase != .failed);
}

test "scene manager load preserves persistent entities and unload keeps them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var previous_cwd = try std.Io.Dir.cwd().openDir(io_globals.global_io, ".", .{});
    defer previous_cwd.close(io_globals.global_io);
    defer previous_cwd.setAsCwd() catch {};
    try tmp.dir.setAsCwd();
    try tmp.dir.makePath("assets/scenes");

    var source_world = world_mod.World.init(std.testing.allocator, null);
    defer source_world.deinit();
    try source_world.bootstrap3D();
    const enemy_id = try source_world.createEntity(.{ .name = "Enemy" });
    source_world.getEntity(enemy_id).?.local_transform.translation = .{ 10.0, 0.0, 0.0 };
    source_world.markDirty(enemy_id);

    const scene_bytes = try scene_io.serializeWorldAlloc(std.testing.allocator, &source_world);
    defer std.testing.allocator.free(scene_bytes);

    var scene_file = try tmp.dir.createFile("assets/scenes/level_2.guava_scene", .{});
    defer scene_file.close();
    try scene_file.writeAll(scene_bytes);

    const job_system = try job_system_mod.JobSystem.init(std.testing.allocator, 1);
    defer job_system.deinit();

    var world = world_mod.World.init(std.testing.allocator, job_system);
    defer world.deinit();
    try world.bootstrap3D();

    const player_id = try world.createEntity(.{ .name = "Player", .dont_destroy_on_load = true });
    const companion_id = try world.createEntity(.{ .name = "Companion", .parent = player_id });
    _ = try world.createEntity(.{ .name = "MenuUi" });
    world.getEntity(companion_id).?.local_transform.translation = .{ 1.0, 2.0, 3.0 };
    world.markDirty(companion_id);
    world.updateHierarchy();

    var physics_state = physics_mod.PhysicsState.init(std.testing.allocator);
    defer physics_state.deinit();

    var command_queue = command_queue_mod.CommandQueue.init(std.testing.allocator);
    defer command_queue.deinit();

    var scene_manager = SceneManager.init(std.testing.allocator);
    defer scene_manager.deinit();

    var probe = CallbackProbe{};
    try scene_manager.requestLoadScene(job_system, "level_2", .{
        .context = &probe,
        .on_started = callbackProbeStarted,
        .on_progress = callbackProbeProgress,
        .on_finished = callbackProbeFinished,
        .on_failed = callbackProbeFailed,
    });
    try pumpUntilIdle(&scene_manager, &world, &physics_state, &command_queue);

    try std.testing.expectEqual(@as(usize, 1), probe.started);
    try std.testing.expect(probe.progress >= 2);
    try std.testing.expectEqual(@as(usize, 1), probe.finished);
    try std.testing.expectEqual(@as(usize, 0), probe.failed);
    try std.testing.expectEqual(TransitionPhase.completed, probe.last_phase);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), probe.last_progress, 0.0001);
    try std.testing.expect(scene_manager.currentScenePath() != null);
    try std.testing.expect(std.mem.endsWith(u8, scene_manager.currentScenePath().?, "assets/scenes/level_2.guava_scene"));

    const loaded_player = findEntityByName(&world, "Player").?;
    const loaded_companion = findEntityByName(&world, "Companion").?;
    const loaded_enemy = findEntityByName(&world, "Enemy").?;
    try std.testing.expect(loaded_player.dont_destroy_on_load);
    try std.testing.expectEqual(loaded_player.id, loaded_companion.parent.?);
    try std.testing.expectEqual(@as(?*const world_mod.Entity, null), findEntityByName(&world, "MenuUi"));
    try std.testing.expectEqualStrings("Enemy", loaded_enemy.name);

    try scene_manager.requestUnloadScene(.{});
    try pumpUntilIdle(&scene_manager, &world, &physics_state, &command_queue);

    try std.testing.expectEqual(@as(?[]const u8, null), scene_manager.currentScenePath());
    try std.testing.expect(findEntityByName(&world, "Enemy") == null);
    try std.testing.expect(findEntityByName(&world, "Player") != null);
    try std.testing.expect(findEntityByName(&world, "Companion") != null);
    try std.testing.expectEqual(@as(usize, 2), world.entities.items.len);
}
