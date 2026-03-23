const std = @import("std");
const engine = @import("guava");
const editor_layer_mod = @import("editor/core/layer.zig");
const editor_console = @import("editor/ui/panels/debug/console.zig");
const cli = @import("cli.zig");
const commands = @import("commands.zig");

pub const std_options = std.Options{
    .logFn = editor_console.logFn,
    .log_level = .info,
};

const SandboxLayer = struct {
    spinning_entity: ?engine.scene.EntityId = null,

    pub fn asLayer(self: *SandboxLayer) engine.core.Layer {
        return .{
            .name = "Sandbox3D",
            .context = self,
            .hooks = .{
                .on_attach = onAttach,
                .on_update = onUpdate,
            },
        };
    }

    fn onAttach(context: *anyopaque, layer_context: *engine.core.LayerContext) anyerror!void {
        const self: *SandboxLayer = @ptrCast(@alignCast(context));
        self.spinning_entity = null;
        const world = layer_context.world;
        const library = world.assets();
        const registry = &library.asset_registry;
        const allocator = library.allocator;

        // Remove the default Hero cube from bootstrap3D.
        if (world.findEntityByName("Hero")) |hero| {
            _ = world.destroyEntity(hero.id);
        }

        // ── 1. Register HDR environment for IBL ─────────────────────────
        // The renderer auto-discovers .hdr files in the registry for IBL.
        _ = try registry.ensureProjectAsset("assets/textures/ticknock_04_4k.hdr");

        // ── 2. Import glTF brick model (full PBR: diffuse + ARM + normal) ─
        const brick_report = try world.importGltfStaticModel(
            "assets/textures/brick_4_4k_gltf/brick_4_4k.gltf",
            .{
                .translation = .{ -1.5, 0.0, 0.0 },
                .scale = .{ 1.0, 1.0, 1.0 },
            },
        );
        // Slow-spin the imported brick root entity.
        if (brick_report.root_entity) |root_id| {
            self.spinning_entity = root_id;
        }

        // ── 3. Textured cube: load diffuse JPG via asset pipeline ────────
        const diff_record = try registry.ensureProjectAsset(
            "assets/textures/brick_4_4k_gltf/textures/brick_4_diff_4k.jpg",
        );
        const diff_tex = try engine.assets.loadTextureAsset(
            allocator,
            library,
            registry,
            diff_record.id,
        );
        const cube_mat = try library.createMaterial(.{
            .name = "CheckeredDiffuseMaterial",
            .base_color_texture = diff_tex,
            .metallic_factor = 0.0,
            .roughness_factor = 0.6,
        });
        const cube_mesh = try library.ensurePrimitiveMesh(.cube);
        _ = try world.createEntity(.{
            .name = "TexturedCube",
            .mesh = .{ .handle = cube_mesh, .primitive = .cube },
            .material = .{ .handle = cube_mat },
            .local_transform = .{
                .translation = .{ 1.5, 0.5, 0.0 },
            },
        });

        // ── 4. Reflective sphere: pure PBR metal to show IBL reflections ─
        const sphere_mat = try library.createMaterial(.{
            .name = "ChromeSphereMaterial",
            .base_color_factor = .{ 0.95, 0.93, 0.88, 1.0 },
            .metallic_factor = 1.0,
            .roughness_factor = 0.08,
        });
        const sphere_mesh = try library.ensurePrimitiveMesh(.sphere);
        _ = try world.createEntity(.{
            .name = "ChromeSphere",
            .mesh = .{ .handle = sphere_mesh, .primitive = .sphere },
            .material = .{ .handle = sphere_mat },
            .local_transform = .{
                .translation = .{ 0.0, 0.7, 1.8 },
                .scale = .{ 0.7, 0.7, 0.7 },
            },
        });

        // ── 5. Adjust camera ─────────────────────────────────────────────
        if (world.findEntityByName("MainCamera")) |cam_ref| {
            if (world.getEntity(cam_ref.id)) |cam| {
                cam.local_transform.translation = .{ 0.0, 2.0, 5.5 };
                cam.local_transform.rotation = engine.math.quat.fromEuler(.{ -0.18, 0.0, 0.0 });
                world.markDirty(cam_ref.id);
            }
        }

        // ── 6. Adjust Sun light ──────────────────────────────────────────
        if (world.findEntityByName("Sun")) |sun_ref| {
            if (world.getEntity(sun_ref.id)) |sun| {
                sun.light = .{
                    .kind = .directional,
                    .color = .{ 1.0, 0.98, 0.95 },
                    .intensity = 3.5,
                };
                sun.local_transform.rotation = engine.math.quat.fromEuler(.{ -0.78, 0.78, 0.0 });
                world.markDirty(sun_ref.id);
            }
        }
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) anyerror!void {
        const self: *SandboxLayer = @ptrCast(@alignCast(context));
        if (self.spinning_entity) |entity_id| {
            if (layer_context.world.getEntity(entity_id)) |entity| {
                // 计算这一帧的旋转增量（弧度）
                const delta_angle = 0.75 * layer_context.delta_seconds;

                // 构造绕Y轴的增量旋转四元数（避免万向节死锁，效率更高）
                const delta_rotation = engine.math.quat.fromAxisAngle(.{ 0.0, 1.0, 0.0 }, delta_angle);

                // 使用四元数乘法叠加旋转（这是3D图形学标准做法）
                entity.local_transform.rotation = engine.math.quat.mul(entity.local_transform.rotation, delta_rotation);

                // 归一化防止浮点误差累积
                entity.local_transform.rotation = engine.math.quat.normalize(entity.local_transform.rotation);
            }
        }
    }
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
            if (options.mcp_enabled) {
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
    var app = try engine.core.Application.init(allocator, .{
        .name = "Guava Engine",
        .window_width = 1440,
        .window_height = 900,
        .window_borderless = true,
        .window_maximized = true,
        .window_native_titlebar_controls = true,
        .frame_delay_ms = 16,
        .preferred_backends = options.backends(),
    });
    defer app.deinit();

    var sandbox_layer = SandboxLayer{};
    try app.pushLayer(sandbox_layer.asLayer());
    var editor_layer = editor_layer_mod.EditorLayer{};
    try app.pushOverlay(editor_layer.asLayer());

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

fn runMcp(allocator: std.mem.Allocator, options: cli.CliOptions) !void {
    if (options.mcp_transport != .stdio) {
        return error.UnsupportedTransport;
    }

    var app = try engine.core.Application.init(allocator, .{
        .name = "Guava Engine MCP",
        .window_width = 1440,
        .window_height = 900,
        .window_borderless = true,
        .window_native_titlebar_controls = true,
        .frame_delay_ms = 16,
        .preferred_backends = options.backends(),
    });
    defer app.deinit();

    var sandbox_layer = SandboxLayer{};
    try app.pushLayer(sandbox_layer.asLayer());
    var editor_layer = editor_layer_mod.EditorLayer{};
    var collaboration_store = engine.mcp.collaboration.Store.init(allocator);
    defer collaboration_store.deinit();
    editor_layer.state.ai_collaboration = &collaboration_store;
    try app.pushOverlay(editor_layer.asLayer());

    var snapshot_store = engine.mcp.resources.SnapshotStore.init(
        allocator,
        &collaboration_store,
        &app.script_runtime,
        &app.editor_utility_runtime,
    );
    defer snapshot_store.deinit();
    var tool_bridge = engine.mcp.tools.Bridge.init(allocator);
    defer tool_bridge.deinit();
    var collaboration_bridge = engine.mcp.collaboration.Bridge.init(allocator, &collaboration_store);
    defer collaboration_bridge.deinit();

    var exit_requested = std.atomic.Value(bool).init(false);
    var sync_layer = engine.mcp.server.SyncLayer{
        .store = &snapshot_store,
        .tool_bridge = &tool_bridge,
        .collaboration_bridge = &collaboration_bridge,
        .exit_requested = &exit_requested,
    };
    try app.pushOverlay(sync_layer.asLayer());

    var server_thread = try engine.mcp.server.spawn(&snapshot_store, &tool_bridge, &collaboration_bridge, &exit_requested);
    defer {
        collaboration_bridge.shutdown();
        tool_bridge.shutdown();
        exit_requested.store(true, .release);
        std.posix.close(std.posix.STDIN_FILENO);
        server_thread.join();
    }

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
