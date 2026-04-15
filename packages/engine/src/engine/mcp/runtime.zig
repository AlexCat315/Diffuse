const std = @import("std");
const io_globals = @import("io_globals");
const application_mod = @import("../core/application.zig");
const collaboration_mod = @import("collaboration.zig");
const resources_mod = @import("resources/mod.zig");
const server_mod = @import("server.zig");
const tools_mod = @import("tools.zig");

pub const Config = struct {
    enable_stdio_server: bool = false,
    close_stdin_on_shutdown: bool = false,
    idle_snapshot_interval_frames: u32 = 60,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    config: Config = .{},

    collaboration_store: collaboration_mod.Store,
    snapshot_store: resources_mod.SnapshotStore,
    tool_bridge: tools_mod.Bridge,
    collaboration_bridge: collaboration_mod.Bridge,

    exit_requested: std.atomic.Value(bool),
    active_clients: std.atomic.Value(u32),
    sync_layer: server_mod.SyncLayer,
    server_thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        app: *application_mod.Application,
        config: Config,
    ) !*Runtime {
        const runtime = try allocator.create(Runtime);
        errdefer allocator.destroy(runtime);

        runtime.allocator = allocator;
        runtime.config = config;

        runtime.collaboration_store = collaboration_mod.Store.init(allocator);
        errdefer runtime.collaboration_store.deinit();
        runtime.snapshot_store = resources_mod.SnapshotStore.init(
            allocator,
            &runtime.collaboration_store,
            &app.script_runtime,
            &app.editor_utility_runtime,
        );
        errdefer runtime.snapshot_store.deinit();
        runtime.tool_bridge = tools_mod.Bridge.init(allocator);
        errdefer runtime.tool_bridge.deinit();
        runtime.collaboration_bridge = collaboration_mod.Bridge.init(allocator, &runtime.collaboration_store);
        errdefer runtime.collaboration_bridge.deinit();
        runtime.exit_requested = std.atomic.Value(bool).init(false);
        runtime.active_clients = std.atomic.Value(u32).init(0);
        runtime.sync_layer = .{
            .store = &runtime.snapshot_store,
            .tool_bridge = &runtime.tool_bridge,
            .collaboration_bridge = &runtime.collaboration_bridge,
            .exit_requested = &runtime.exit_requested,
            .active_clients = &runtime.active_clients,
            .idle_publish_interval_frames = if (config.idle_snapshot_interval_frames == 0)
                60
            else
                config.idle_snapshot_interval_frames,
        };
        runtime.server_thread = null;

        if (config.enable_stdio_server) {
            runtime.server_thread = try server_mod.spawn(
                &runtime.snapshot_store,
                &runtime.tool_bridge,
                &runtime.collaboration_bridge,
                &runtime.exit_requested,
                &runtime.active_clients,
            );
        }

        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        if (self.server_thread) |thread| {
            self.collaboration_bridge.shutdown();
            self.tool_bridge.shutdown();
            self.exit_requested.store(true, .release);
            if (self.config.close_stdin_on_shutdown) {
                std.Io.File.stdin().close(io_globals.global_io);
            }
            thread.join();
            self.server_thread = null;
        }

        self.collaboration_bridge.deinit();
        self.tool_bridge.deinit();
        self.snapshot_store.deinit();
        self.collaboration_store.deinit();

        self.allocator.destroy(self);
    }

    pub fn collaborationStore(self: *Runtime) *collaboration_mod.Store {
        return &self.collaboration_store;
    }

    pub fn snapshotStore(self: *Runtime) *resources_mod.SnapshotStore {
        return &self.snapshot_store;
    }

    pub fn toolBridge(self: *Runtime) *tools_mod.Bridge {
        return &self.tool_bridge;
    }

    pub fn collaborationBridge(self: *Runtime) *collaboration_mod.Bridge {
        return &self.collaboration_bridge;
    }

    pub fn syncLayer(self: *Runtime) *server_mod.SyncLayer {
        return &self.sync_layer;
    }
};
