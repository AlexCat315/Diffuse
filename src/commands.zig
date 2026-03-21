//! 基准测试与渲染比较命令
//!
//! 实现 benchmark、generate-benchmark、compare-render、validate 子命令。

const std = @import("std");
const engine = @import("guava");
const cli = @import("cli.zig");

pub fn runBenchmark(allocator: std.mem.Allocator, scene_path: []const u8, update_golden: bool) !void {
    const width = 1280;
    const height = 720;
    const benchmark_frames = 100;

    var app = try engine.core.Application.init(allocator, .{
        .name = "Benchmark Mode",
        .window_width = width,
        .window_height = height,
        .window_borderless = true,
        .frame_delay_ms = 0,
    });
    defer app.deinit();

    var handle = try app.world.importGltfAsync("assets/models/guava_showcase/guava_showcase.gltf", .{
        .translation = .{ 0.0, 0.0, 0.0 },
    }, null);
    defer handle.deinit();
    handle.wait();

    try engine.scene.loadWorldFromPath(allocator, &app.world, scene_path);
    try app.renderer.setSceneViewportSize(width, height);

    std.log.info("Starting benchmark for scene: {s} (frames={d})", .{ scene_path, benchmark_frames });

    const report = try app.run(benchmark_frames);

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

pub fn runCompareRender(allocator: std.mem.Allocator, scene_path: []const u8, output_dir: []const u8) !void {
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

    _ = try app.renderer.drawFrame(&app.world, &app.physics_state);
    const gpu_ppm = try app.renderer.downloadFinalFrameAlloc(allocator);
    defer allocator.free(gpu_ppm);

    const software_ppm = try engine.render.BasePassGolden.renderScenePpmAlloc(allocator, &app.world, width, height);
    defer allocator.free(software_ppm);

    try std.fs.cwd().makePath(output_dir);
    const gpu_path = try std.fmt.allocPrint(allocator, "{s}/gpu.ppm", .{output_dir});
    defer allocator.free(gpu_path);
    const software_path = try std.fmt.allocPrint(allocator, "{s}/software.ppm", .{output_dir});
    defer allocator.free(software_path);

    try std.fs.cwd().writeFile(.{ .sub_path = gpu_path, .data = gpu_ppm });
    try std.fs.cwd().writeFile(.{ .sub_path = software_path, .data = software_ppm });

    std.log.info("Comparison completed. GPU and Software images saved to {s}", .{output_dir});
}

pub fn runGenerateBenchmark(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var world = engine.scene.World.init(allocator, null);
    defer world.deinit();
    try world.bootstrap3D();

    const cube_mesh = try world.assets().ensurePrimitiveMesh(.cube);
    const default_material = try world.assets().ensureDefaultMaterial();

    _ = try world.createEntity(.{
        .name = "BenchmarkCube",
        .mesh = .{ .handle = cube_mesh, .primitive = .cube },
        .material = .{ .handle = default_material },
        .local_transform = .{ .translation = .{ 0.0, 1.0, 0.0 } },
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

pub fn runValidate(allocator: std.mem.Allocator, options: cli.ValidateOptions) !void {
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
