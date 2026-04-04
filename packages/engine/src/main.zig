const std = @import("std");
const engine = @import("guava");
const editor_layer_mod = @import("engine/editor_backend/core/layer.zig");
const editor_console = @import("engine/editor_backend/core/logging.zig");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const project_mod = @import("project.zig");

pub const std_options = std.Options{
    .logFn = editor_console.logFn,
    .log_level = .info,
};

fn ensureProjectRootAsCwd(allocator: std.mem.Allocator) !void {
    std.fs.cwd().access("assets", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const resolved_root = try resolveProjectRootAlloc(allocator);
            defer if (resolved_root) |root| allocator.free(root);

            if (resolved_root) |root| {
                try std.process.changeCurDir(root);
            }
        },
        else => return err,
    };
}

fn resolveProjectRootAlloc(allocator: std.mem.Allocator) !?[]u8 {
    const cwd_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);
    if (try findProjectRootFromAbsoluteAlloc(allocator, cwd_path)) |root| {
        return root;
    }

    const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_dir);
    return try findProjectRootFromAbsoluteAlloc(allocator, exe_dir);
}

fn findProjectRootFromAbsoluteAlloc(allocator: std.mem.Allocator, start_path: []const u8) !?[]u8 {
    var current = try allocator.dupe(u8, start_path);
    errdefer allocator.free(current);

    while (true) {
        const assets_path = try std.fs.path.join(allocator, &.{ current, "assets" });
        defer allocator.free(assets_path);

        if (std.fs.accessAbsolute(assets_path, .{})) |_| {
            return current;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == 0 or parent.len == current.len) {
            break;
        }

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    allocator.free(current);
    return null;
}

const LoadedProject = struct {
    root_path: []u8,
    file: project_mod.ProjectFile,

    fn deinit(self: *LoadedProject, allocator: std.mem.Allocator) void {
        allocator.free(self.root_path);
        self.file.deinit(allocator);
        self.* = undefined;
    }
};

fn loadConfiguredProjectAlloc(allocator: std.mem.Allocator, options: cli.CliOptions) !?LoadedProject {
    const raw_project_path = options.project_path orelse return null;
    const resolved_root = try std.fs.cwd().realpathAlloc(allocator, raw_project_path);
    errdefer allocator.free(resolved_root);

    var project_file = try project_mod.loadAlloc(allocator, resolved_root);
    errdefer project_file.deinit(allocator);

    return .{
        .root_path = resolved_root,
        .file = project_file,
    };
}

fn applicationNameAlloc(allocator: std.mem.Allocator, base_name: []const u8, loaded_project: ?*const LoadedProject) ![]u8 {
    if (loaded_project) |project| {
        return std.fmt.allocPrint(allocator, "{s} - {s}", .{ base_name, project.file.name });
    }
    return allocator.dupe(u8, base_name);
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // GPA leak check must be the FIRST defer registered so it runs LAST (LIFO),
    // after all other defers have freed their allocations.
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("程序将以错误码 1 退出。\n", .{});
            std.process.exit(1);
        }
    }

    try ensureProjectRootAsCwd(allocator);

    try editor_console.initLogFile();
    defer editor_console.deinitLogFile();

    std.log.info("Guava Engine initialized successfully", .{});
    std.log.debug("Debug logging enabled", .{});

    var command = try cli.parseCommandAlloc(allocator);
    defer command.deinit(allocator);

    switch (command) {
        .run => |options| {
            if (options.editor_server) {
                try runEditorServer(allocator, options);
            } else if (options.mcp_enabled) {
                try runMcp(allocator, options);
            } else {
                try runEngine(allocator, options);
            }
        },
        .validate => |options| try commands.runValidate(allocator, options),
        .benchmark => |options| try commands.runBenchmark(allocator, options.scene_path, options.update_golden),
        .@"generate-benchmark" => |options| try commands.runGenerateBenchmark(allocator, options.output_path),
        .@"compare-render" => |options| try commands.runCompareRender(allocator, options.scene_path, options.output_dir),
        .@"render-test" => |options| {
            if (options.suite) {
                try commands.runRenderTestSuite(allocator, options);
            } else {
                try commands.runRenderTest(allocator, options);
            }
        },
    }

    return 0;
}

fn runEngine(allocator: std.mem.Allocator, options: cli.CliOptions) !void {
    var loaded_project = try loadConfiguredProjectAlloc(allocator, options);
    defer if (loaded_project) |*project| project.deinit(allocator);

    const app_name = try applicationNameAlloc(allocator, "Guava Engine", if (loaded_project) |*project| project else null);
    defer allocator.free(app_name);

    var app = try engine.core.Application.init(allocator, .{
        .name = app_name,
        .window_width = 1440,
        .window_height = 900,
        .window_borderless = true,
        .window_maximized = true,
        .window_native_titlebar_controls = true,
        .frame_delay_ms = 16,
        .preferred_backends = options.backends(),
    });
    defer app.deinit();

    var editor_layer = editor_layer_mod.EditorLayer{};
    if (loaded_project) |*project| {
        editor_layer.state.setProjectContext(project.root_path, project.file.name, project.file.content_dir, project.file.start_scene);
        std.log.info("opening project '{s}' at {s}", .{ project.file.name, project.root_path });
    }

    const mcp_runtime = try engine.mcp.runtime.Runtime.init(allocator, &app, .{
        .enable_stdio_server = false,
    });
    defer mcp_runtime.deinit();
    editor_layer.state.ai_collaboration = mcp_runtime.collaborationStore();
    editor_layer.state.ai_snapshot_store = mcp_runtime.snapshotStore();
    editor_layer.state.ai_tool_bridge = mcp_runtime.toolBridge();
    editor_layer.state.ai_collaboration_bridge = mcp_runtime.collaborationBridge();
    try app.pushOverlay(editor_layer.asLayer());
    try app.pushOverlay(mcp_runtime.syncLayer().asLayer());

    const report = try app.run(options.frame_count);
    const device_name = if (report.runtime.deviceName().len == 0) "Unknown Device" else report.runtime.deviceName();
    const driver_name = if (report.runtime.driverName().len == 0) "Unknown Driver" else report.runtime.driverName();
    const driver_info = if (report.runtime.driverInfo().len == 0) "n/a" else report.runtime.driverInfo();
    const depth_state = if (report.runtime.has_depth) "ready" else "missing";

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        "Engine {s} booted on {s} with {s}. Device: {s}. Drawable: {d}x{d}. Depth: {s}. Frames: {d}, passes: {d}, draws: {d}, triangles: {d}, entities: {d}, meshes: {d}, lights: {d}\n",
        .{
            app.config.name,
            engine.core.platformName(app.platform),
            engine.render.graphicsApiName(report.backend),
            device_name,
            report.runtime.drawable_width,
            report.runtime.drawable_height,
            depth_state,
            report.frames,
            report.passes,
            report.draw_calls,
            report.triangles_drawn,
            report.scene.entity_count,
            report.scene.mesh_count,
            report.scene.light_count,
        },
    );
    try stdout.print("RHI driver: {s}\n", .{driver_name});
    try stdout.print("Driver info: {s}\n", .{driver_info});
    try stdout.flush();
}

fn runEditorServer(allocator: std.mem.Allocator, options: cli.CliOptions) !void {
    var loaded_project = try loadConfiguredProjectAlloc(allocator, options);
    defer if (loaded_project) |*project| project.deinit(allocator);

    const app_name = try applicationNameAlloc(allocator, "Guava Engine (Editor Server)", if (loaded_project) |*project| project else null);
    defer allocator.free(app_name);

    // In editor-server mode, the window is managed by Electron.
    // The engine creates a regular window that Electron can embed as a child.
    var app = try engine.core.Application.init(allocator, .{
        .name = app_name,
        .window_width = 1280,
        .window_height = 720,
        .window_borderless = false,
        .window_maximized = false,
        .window_native_titlebar_controls = false,
        .window_hidden = true,
        .frame_delay_ms = 16,
        .preferred_backends = options.backends(),
    });
    defer app.deinit();

    // In editor-server mode, the engine is a background process managed by
    // Electron.  Hide from Dock / Cmd-Tab so users don't accidentally interact
    // with or close the engine process directly.
    engine.platform.Window.setBackgroundApp();

    // In editor-server mode, use IOSurface-backed viewport textures so
    // Electron can display the rendered frame via CALayer (zero-copy).
    app.renderer.scene_viewport.use_iosurface = true;

    // Push EditorLayer so camera controls, manipulation shortcuts, and
    // gizmo interaction work through the input forwarding from Electron.
    var editor_layer = editor_layer_mod.EditorLayer{};
    editor_layer.state.editor_server_mode = true;
    if (loaded_project) |*project| {
        editor_layer.state.setProjectContext(project.root_path, project.file.name, project.file.content_dir, project.file.start_scene);
        std.log.info("opening project '{s}' at {s}", .{ project.file.name, project.root_path });
    }

    // Start MCP runtime for AI collaboration support (before EditorLayer push
    // so we can wire up the collaboration stores)
    const mcp_runtime = try engine.mcp.runtime.Runtime.init(allocator, &app, .{
        .enable_stdio_server = false,
    });
    defer mcp_runtime.deinit();
    editor_layer.state.ai_collaboration = mcp_runtime.collaborationStore();
    editor_layer.state.ai_snapshot_store = mcp_runtime.snapshotStore();
    editor_layer.state.ai_tool_bridge = mcp_runtime.toolBridge();
    editor_layer.state.ai_collaboration_bridge = mcp_runtime.collaborationBridge();

    // Start the Editor RPC WebSocket server — must be pushed BEFORE EditorLayer
    // so that viewport.sendInput populates InputState before camera controls
    // consume it in the same frame.
    const editor_rpc = @import("guava").editor_rpc;
    var rpc_server = editor_rpc.server.Server.init(allocator, options.editor_port);
    defer rpc_server.deinit();

    try app.pushOverlay(rpc_server.asLayer());
    try app.pushOverlay(editor_layer.asLayer());
    try app.pushOverlay(mcp_runtime.syncLayer().asLayer());

    // Wire logging callback so std.log entries flow into the RPC console buffer.
    // Done here in main (root module) because server.zig (guava module) cannot
    // import logging.zig (root module) without a cross-module conflict.
    editor_console.g_console_callback = &editor_rpc.server.consoleLogTrampoline;
    defer editor_console.g_console_callback = null;

    std.log.info("Editor server mode: RPC on port {d}", .{options.editor_port});

    _ = try app.run(options.frame_count);
}

fn runMcp(allocator: std.mem.Allocator, options: cli.CliOptions) !void {
    if (options.mcp_transport != .stdio) {
        return error.UnsupportedTransport;
    }

    var loaded_project = try loadConfiguredProjectAlloc(allocator, options);
    defer if (loaded_project) |*project| project.deinit(allocator);

    const app_name = try applicationNameAlloc(allocator, "Guava Engine MCP", if (loaded_project) |*project| project else null);
    defer allocator.free(app_name);

    var app = try engine.core.Application.init(allocator, .{
        .name = app_name,
        .window_width = 1440,
        .window_height = 900,
        .window_borderless = true,
        .window_native_titlebar_controls = true,
        .frame_delay_ms = 16,
        .preferred_backends = options.backends(),
    });
    defer app.deinit();

    var editor_layer = editor_layer_mod.EditorLayer{};
    if (loaded_project) |*project| {
        editor_layer.state.setProjectContext(project.root_path, project.file.name, project.file.content_dir, project.file.start_scene);
        std.log.info("opening project '{s}' at {s}", .{ project.file.name, project.root_path });
    }

    const mcp_runtime = try engine.mcp.runtime.Runtime.init(allocator, &app, .{
        .enable_stdio_server = true,
        .close_stdin_on_shutdown = true,
    });
    defer mcp_runtime.deinit();
    editor_layer.state.ai_collaboration = mcp_runtime.collaborationStore();
    editor_layer.state.ai_snapshot_store = mcp_runtime.snapshotStore();
    editor_layer.state.ai_tool_bridge = mcp_runtime.toolBridge();
    editor_layer.state.ai_collaboration_bridge = mcp_runtime.collaborationBridge();
    try app.pushOverlay(editor_layer.asLayer());
    try app.pushOverlay(mcp_runtime.syncLayer().asLayer());

    std.log.info("MCP stdio transport ready", .{});
    _ = try app.run(options.frame_count);
}

test "main boots the engine skeleton" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var app = engine.core.Application.init(allocator, .{
        .name = "Smoke Test",
        .window_width = 128,
        .window_height = 128,
    }) catch |err| {
        std.debug.print("Skipping smoke test due to init failure (possibly headless): {}\n", .{err});
        return;
    };
    defer app.deinit();

    const report = app.run(2) catch |err| {
        std.debug.print("Skipping smoke test due to run failure: {}\n", .{err});
        return;
    };
    try std.testing.expect(report.frames > 0);
}
