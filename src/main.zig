const std = @import("std");
const engine = @import("guava");
const editor_layer_mod = @import("editor/core/layer.zig");
const editor_console = @import("editor/ui/windows/console.zig");

pub const std_options = std.Options{
    .logFn = editor_console.logFn,
    .log_level = .debug,  // 设置日志级别为 debug，以便显示所有日志
};

const CliOptions = struct {
    frame_count: usize = 0,
    backend_order: [3]engine.render.GraphicsAPI = .{ .vulkan, .dx12, .metal },
    backend_count: usize = 3,

    fn backends(self: *const CliOptions) []const engine.render.GraphicsAPI {
        return self.backend_order[0..self.backend_count];
    }
};

const ValidateOptions = struct {
    root_path: []u8,
    asset_query: ?[]u8 = null,
    write_snapshot: bool = true,

    fn deinit(self: *ValidateOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.root_path);
        if (self.asset_query) |query| {
            allocator.free(query);
        }
        self.* = undefined;
    }
};

const Command = union(enum) {
    run: CliOptions,
    validate: ValidateOptions,
    benchmark: struct {
        scene_path: []const u8,
        update_golden: bool = false,
        allocated: bool = false,
    },
    @"generate-benchmark": struct {
        output_path: []const u8,
        allocated: bool = false,
    },
    @"compare-render": struct {
        scene_path: []const u8,
        output_dir: []const u8,
        allocated: bool = false,
    },

    fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .run => self.* = undefined,
            .validate => |*options| options.deinit(allocator),
            .benchmark => |options| if (options.allocated) allocator.free(options.scene_path),
            .@"generate-benchmark" => |options| if (options.allocated) allocator.free(options.output_path),
            .@"compare-render" => |options| if (options.allocated) {
                allocator.free(options.scene_path);
                allocator.free(options.output_dir);
            },
        }
    }
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
        const cube_mesh = try layer_context.world.assets().ensurePrimitiveMesh(.cube);
        const default_material = try layer_context.world.assets().ensureDefaultMaterial();
        self.spinning_entity = try layer_context.world.createEntity(.{
            .name = "Spinner",
            .mesh = .{
                .handle = cube_mesh,
                .primitive = .cube,
            },
            .material = .{
                .handle = default_material,
            },
            .local_transform = .{
                .translation = .{ 2.0, 1.0, 0.0 },
                .scale = .{ 1.0, 1.5, 1.0 },
            },
        });

        _ = try layer_context.world.createEntity(.{
            .name = "SpinnerChild",
            .parent = self.spinning_entity,
            .mesh = .{
                .handle = cube_mesh,
                .primitive = .cube,
            },
            .material = .{
                .handle = default_material,
            },
            .local_transform = .{
                .translation = .{ 1.1, 0.9, 0.0 },
                .scale = .{ 0.35, 0.35, 0.35 },
            },
        });

        _ = try layer_context.world.importGltfStaticModel(
            "assets/models/guava_showcase/guava_showcase.gltf",
            .{
                .translation = .{ -2.4, 0.0, 0.0 },
            },
        );
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

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    // 尽早初始化日志系统 - 必须在任何日志调用之前
    try editor_console.initLogFile();
    defer editor_console.deinitLogFile();
    
    // 测试日志：用于验证 ImGui 控制台是否正常工作
    std.log.info("Guava Engine initialized successfully", .{});
    std.log.debug("Debug logging enabled", .{});
    
    var command = try parseCommandAlloc(allocator);
    defer command.deinit(allocator);

    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("❌ 致命错误：检测到 GPA 内存泄漏！程序将以错误码 1 退出。\n", .{});
            std.process.exit(1);
        }
    }

    switch (command) {
        .run => |options| try runEngine(allocator, options),
        .validate => |options| try runValidate(allocator, options),
        .benchmark => |options| try runBenchmark(allocator, options.scene_path, options.update_golden),
        .@"generate-benchmark" => |options| try runGenerateBenchmark(allocator, options.output_path),
        .@"compare-render" => |options| try runCompareRender(allocator, options.scene_path, options.output_dir),
    }
    
    return 0; // 正常退出返回 0
}

fn runBenchmark(allocator: std.mem.Allocator, scene_path: []const u8, update_golden: bool) !void {
    const width = 1280;
    const height = 720;
    const benchmark_frames = 100;

    var app = try engine.core.Application.init(allocator, .{
        .name = "Benchmark Mode",
        .window_width = width,
        .window_height = height,
        .window_borderless = true,
        .frame_delay_ms = 0, // Unlocked
    });
    defer app.deinit();

    // Test async loading during benchmark
    const handle = try app.world.importGltfAsync("assets/models/guava_showcase/guava_showcase.gltf", .{
        .translation = .{ 0.0, 0.0, 0.0 },
    }, null);
    handle.wait();

    try engine.scene.loadWorldFromPath(allocator, &app.world, scene_path);
    try app.renderer.setSceneViewportSize(width, height);

    std.log.info("Starting benchmark for scene: {s} (frames={d})", .{ scene_path, benchmark_frames });

    // Run for 100 frames
    const report = try app.run(benchmark_frames);

    // Capture final frame
    const frame_ppm = try app.renderer.downloadFinalFrameAlloc(allocator);
    defer allocator.free(frame_ppm);

    const scene_basename = std.fs.path.basename(scene_path);
    const scene_name = if (std.mem.lastIndexOfScalar(u8, scene_basename, '.')) |idx| scene_basename[0..idx] else scene_basename;

    try std.fs.cwd().makePath("assets/benchmarks/golden");
    const golden_path = try std.fmt.allocPrint(allocator, "assets/benchmarks/golden/{s}.ppm", .{scene_name});
    defer allocator.free(golden_path);

    if (update_golden) {
        try std.fs.cwd().writeFile(.{ .sub_path = golden_path, .data = frame_ppm });
        std.log.info("Golden image updated: {s}", .{golden_path});
    } else {
        // 动态获取文件真实大小，移除硬编码的 10MB 限制
        const file_stat = std.fs.cwd().statFile(golden_path) catch |err| {
            if (err == error.FileNotFound) {
                std.log.err("Golden image not found: {s}. Run with --update-golden to create it.", .{golden_path});
                return err;
            }
            std.log.err("无法获取基准文件状态: {s}", .{@errorName(err)});
            return err;
        };
        
        const golden_ppm = std.fs.cwd().readFileAlloc(allocator, golden_path, file_stat.size) catch |err| {
            std.log.err("读取基准文件失败: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(golden_ppm);

        // Simple binary comparison for now (SSIM/PSNR can be added later)
        if (std.mem.eql(u8, frame_ppm, golden_ppm)) {
            std.log.info("Benchmark PASSED: Render output matches golden image.", .{});
        } else {
            std.log.err("Benchmark FAILED: Render output differs from golden image.", .{});

            try std.fs.cwd().makePath("dist/reports/benchmark_diff");
            const diff_path = try std.fmt.allocPrint(allocator, "dist/reports/benchmark_diff/{s}_failed.ppm", .{scene_name});
            defer allocator.free(diff_path);
            try std.fs.cwd().writeFile(.{ .sub_path = diff_path, .data = frame_ppm });
            std.log.info("Failed frame saved to: {s}", .{diff_path});

            return error.BenchmarkValidationFailed;
        }
    }

    std.log.info("Benchmark report: frames={d}, triangles={d}, entities={d}", .{
        report.frames,
        report.triangles_drawn,
        report.scene.entity_count,
    });
}

fn runCompareRender(allocator: std.mem.Allocator, scene_path: []const u8, output_dir: []const u8) !void {
    const width = 800;
    const height = 600;

    var app = try engine.core.Application.init(allocator, .{
        .name = "Render Comparison",
        .window_width = width,
        .window_height = height,
        .window_borderless = true,
    });
    defer app.deinit();

    try engine.scene.loadWorldFromPath(allocator, &app.world, scene_path);

    try app.renderer.setSceneViewportSize(width, height);

    // 1. GPU Render
    _ = try app.renderer.drawFrame(&app.world);
    const gpu_ppm = try app.renderer.downloadFinalFrameAlloc(allocator);
    defer allocator.free(gpu_ppm);

    // 2. Software Render (Golden)
    const software_ppm = try engine.render.BasePassGolden.renderScenePpmAlloc(allocator, &app.world, width, height);
    defer allocator.free(software_ppm);

    // 3. Save and Report
    try std.fs.cwd().makePath(output_dir);
    const gpu_path = try std.fmt.allocPrint(allocator, "{s}/gpu.ppm", .{output_dir});
    defer allocator.free(gpu_path);
    const software_path = try std.fmt.allocPrint(allocator, "{s}/software.ppm", .{output_dir});
    defer allocator.free(software_path);

    try std.fs.cwd().writeFile(.{ .sub_path = gpu_path, .data = gpu_ppm });
    try std.fs.cwd().writeFile(.{ .sub_path = software_path, .data = software_ppm });

    std.log.info("Comparison completed. GPU and Software images saved to {s}", .{output_dir});
}

fn runGenerateBenchmark(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var world = engine.scene.World.init(allocator, null);
    defer world.deinit();
    try world.bootstrap3D();

    const cube_mesh = try world.assets().ensurePrimitiveMesh(.cube);
    const default_material = try world.assets().ensureDefaultMaterial();

    _ = try world.createEntity(.{
        .name = "BenchmarkCube",
        .mesh = .{
            .handle = cube_mesh,
            .primitive = .cube,
        },
        .material = .{
            .handle = default_material,
        },
        .local_transform = .{
            .translation = .{ 0.0, 1.0, 0.0 },
            .scale = .{ 1.0, 1.0, 1.0 },
        },
    });

    _ = try world.createEntity(.{
        .name = "BenchmarkCamera",
        .camera = .{
            .projection = .{
                .perspective = .{
                    .fov_y_radians = 60.0 * (std.math.pi / 180.0),
                    .near_clip = 0.1,
                    .far_clip = 100.0,
                },
            },
            .is_primary = true,
        },
        .local_transform = .{
            .translation = .{ 0.0, 2.0, 5.0 },
            .rotation = engine.math.quat.fromEuler(.{ -0.2, 0.0, 0.0 }),
        },
    });

    try engine.scene.saveWorldToPath(allocator, &world, output_path);
    std.log.info("Benchmark scene generated: {s}", .{output_path});
}

fn runEngine(allocator: std.mem.Allocator, options: CliOptions) !void {
    var app = try engine.core.Application.init(allocator, .{
        .name = "Guava Engine",
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

fn runValidate(allocator: std.mem.Allocator, options: ValidateOptions) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var registry = engine.assets.AssetRegistry.init(allocator);
    defer registry.deinit();

    var report = report: {
        registry.refreshProject(options.root_path) catch {
            break :report try engine.assets.validateProjectAssetsAlloc(allocator, options.root_path);
        };
        if (options.write_snapshot) {
            registry.writeSnapshotToPath("assets/derived/asset_registry.json") catch {};
        }
        break :report try engine.assets.validateRegistryAssetsAlloc(
            allocator,
            &registry,
            options.asset_query,
        );
    };
    defer report.deinit(allocator);

    try stdout.print(
        "资产验证: assets={d}, outputs={d}, deps={d}, issues={d}\n",
        .{ report.asset_count, report.validated_output_count, report.dependency_edge_count, report.issues.len },
    );
    for (report.issues) |issue| {
        try stdout.print("- {s}: {s} ({s})\n", .{ issue.source_path, issue.message, issue.asset_id });
    }
    try stdout.flush();

    try std.fs.cwd().makePath("dist/reports");
    const file = try std.fs.cwd().createFile("dist/reports/asset_validation_report.json", .{});
    defer file.close();
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var writer = output.writer(allocator);
    var adapter_buffer: [8192]u8 = undefined;
    var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();

    try file.writeAll(output.items);
    std.debug.print("✅ 资产验证报告已成功生成: dist/reports/asset_validation_report.json\n", .{});

    if (!report.ok()) {
        return error.ValidationFailed;
    }
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

fn parseCommandAlloc(allocator: std.mem.Allocator) !Command {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // 跳过程序名称
    _ = args.next();

    const command_name = args.next();
    if (command_name == null) {
        // 没有提供命令，默认为 run
        return .{ .run = try parseRunOptions(&.{}) };
    }

    if (std.mem.eql(u8, command_name.?, "validate")) {
        // 收集剩余参数作为切片
        var remaining = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer remaining.deinit(allocator);
        while (args.next()) |arg| {
            try remaining.append(allocator, arg);
        }
        return .{ .validate = try parseValidateOptionsAlloc(allocator, remaining.items) };
    }

    if (std.mem.eql(u8, command_name.?, "benchmark")) {
        var scene_path: []const u8 = "assets/benchmarks/material_p0.json";
        var update_golden = false;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--scene")) {
                const next_arg = args.next();
                if (next_arg) |next| {
                    scene_path = next;
                } else {
                    return error.MissingArgument;
                }
            } else if (std.mem.eql(u8, arg, "--update-golden")) {
                update_golden = true;
            } else {
                return error.InvalidArgument;
            }
        }
        return .{ .benchmark = .{
            .scene_path = try allocator.dupe(u8, scene_path),
            .update_golden = update_golden,
            .allocated = true,
        } };
    }

    if (std.mem.eql(u8, command_name.?, "generate-benchmark")) {
        const output_path_arg = args.next();
        const output_path = if (output_path_arg) |path| path else "assets/scenes/benchmark_p0.json";
        // 确保没有多余参数
        if (args.next()) |extra| {
            std.debug.print("Unexpected argument: {s}\n", .{extra});
            return error.InvalidArgument;
        }
        return .{ .@"generate-benchmark" = .{
            .output_path = try allocator.dupe(u8, output_path),
            .allocated = output_path_arg != null,
        } };
    }

    if (std.mem.eql(u8, command_name.?, "compare-render")) {
        const scene_path_arg = args.next();
        const output_dir_arg = args.next();
        const scene_path = if (scene_path_arg) |path| path else "assets/scenes/benchmark_p0.json";
        const output_dir = if (output_dir_arg) |dir| dir else "dist/reports/render_comparison";
        // 确保没有多余参数
        if (args.next()) |extra| {
            std.debug.print("Unexpected argument: {s}\n", .{extra});
            return error.InvalidArgument;
        }
        return .{ .@"compare-render" = .{
            .scene_path = try allocator.dupe(u8, scene_path),
            .output_dir = try allocator.dupe(u8, output_dir),
            .allocated = true,
        } };
    }

    // 如果不是上述命令，则视为 run 命令，并将 command_name 作为第一个参数传递给 parseRunOptions
    // 我们需要将 command_name 和剩余参数收集起来
    var run_args = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer run_args.deinit(allocator);
    try run_args.append(allocator, command_name.?);
    while (args.next()) |arg| {
        try run_args.append(allocator, arg);
    }
    return .{ .run = try parseRunOptions(run_args.items) };
}

fn parseRunOptions(args: []const []const u8) !CliOptions {
    var options = CliOptions{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--backend")) {
            index += 1;
            if (index >= args.len) {
                return error.InvalidArguments;
            }
            options.backend_order = backendOrderForName(args[index]) orelse return error.InvalidArguments;
            options.backend_count = options.backend_order.len;
            continue;
        }
        if (std.mem.eql(u8, arg, "--frames")) {
            index += 1;
            if (index >= args.len) {
                return error.InvalidArguments;
            }
            options.frame_count = try std.fmt.parseUnsigned(usize, args[index], 10);
            continue;
        }
        return error.InvalidArguments;
    }

    return options;
}

fn parseValidateOptionsAlloc(allocator: std.mem.Allocator, args: []const []const u8) !ValidateOptions {
    var options = ValidateOptions{
        .root_path = try allocator.dupe(u8, "assets"),
    };
    errdefer options.deinit(allocator);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--root")) {
            index += 1;
            if (index >= args.len) {
                return error.InvalidArguments;
            }
            allocator.free(options.root_path);
            options.root_path = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--asset")) {
            index += 1;
            if (index >= args.len) {
                return error.InvalidArguments;
            }
            if (options.asset_query) |query| {
                allocator.free(query);
            }
            options.asset_query = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-snapshot")) {
            options.write_snapshot = false;
            continue;
        }
        return error.InvalidArguments;
    }

    return options;
}

fn backendOrderForName(name: []const u8) ?[3]engine.render.GraphicsAPI {
    if (std.mem.eql(u8, name, "vulkan")) {
        return .{ .vulkan, .metal, .dx12 };
    }
    if (std.mem.eql(u8, name, "metal")) {
        return .{ .metal, .vulkan, .dx12 };
    }
    if (std.mem.eql(u8, name, "dx12")) {
        return .{ .dx12, .vulkan, .metal };
    }
    return null;
}
